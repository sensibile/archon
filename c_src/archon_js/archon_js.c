/*
 * Copyright Conductor Authors.
 * Copyright 2026 sensibile
 *
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 * The result conversion follows getObject in conductor-oss
 * core/src/main/java/com/netflix/conductor/core/events/ScriptEvaluator.java
 * at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
 * Modified by sensibile: rewritten in C over QuickJS-ng values, with typed JSON output
 * (ADR 0015).
 *
 * archon_js: the script evaluator process of Archon (ADR 0015).
 *
 * Reads length-prefixed JSON requests from stdin and writes length-prefixed JSON responses to
 * stdout, the framing of an Erlang port opened with {:packet, 4}. Each request runs in a new
 * QuickJS-ng runtime and context: no module loader, no host functions (no std, os, console or
 * timers), a memory limit, a stack limit and an interrupt deadline. Only this C code touches
 * stdin and stdout.
 *
 * Request:  {"op": "eval" | "parse", "script": "...", "input": <JSON>}
 * Response: {"ok": <typed value>} or {"error": kind, "message": "...", "line": N | null}
 *
 * Typed values (ADR 0015, decision 2): ["null"], ["bool", b], ["int", "<decimal>"],
 * ["float", <number>], ["nonfinite", "NaN" | "Infinity" | "-Infinity"], ["str", s],
 * ["list", [...]], ["map", [[key, value], ...]] where key is itself a typed value.
 *
 * Error kinds: "syntax" (parse op only), "runtime" (exception while evaluating), "timeout"
 * (interrupt deadline reached), "conversion" (exception while reading the result, for example
 * from a getter), "limit" (result too deep or too large), "request" (malformed request).
 */

#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "quickjs.h"

#define DEFAULT_MEMORY_LIMIT (64u * 1024 * 1024)
#define DEFAULT_STACK_LIMIT (1024u * 1024)
#define DEFAULT_TIMEOUT_MS 4000
#define DEFAULT_MAX_OUTPUT (16u * 1024 * 1024)
#define MAX_REQUEST (256u * 1024 * 1024)
#define MAX_DEPTH 1000
#define SCRIPT_NAME "inline"

typedef struct {
    size_t memory_limit;
    size_t stack_limit;
    long timeout_ms;
    size_t max_output;
} Config;

typedef struct {
    struct timespec deadline;
    int fired;
} Deadline;

typedef struct {
    char *data;
    size_t len;
    size_t cap;
    size_t max;
    int overflow;
} Buf;

typedef enum { ENC_OK, ENC_EXCEPTION, ENC_LIMIT } EncStatus;

/*
 * Built-ins captured before the script runs, so that a script replacing Map.prototype.entries
 * or Number.prototype.valueOf cannot change how its result is read.
 */
typedef struct {
    JSValue helpers; /* the array HELPERS_SOURCE evaluates to; owns the values below */
    JSValue map_entries;
    JSValue number_value_of;
    JSValue string_value_of;
    JSValue boolean_value_of;
    JSClassID number_class;
    JSClassID string_class;
    JSClassID boolean_class;
    JSClassID arguments_class;
    JSClassID mapped_arguments_class;
} Intrinsics;

typedef struct {
    JSContext *ctx;
    Buf *out;
    const Intrinsics *intrinsics;
} Encoder;

/* ---------- buffer ---------- */

static void buf_reserve(Buf *b, size_t extra)
{
    if (b->overflow)
        return;
    if (extra > b->max || b->len > b->max - extra) {
        b->overflow = 1;
        return;
    }
    if (b->len + extra <= b->cap)
        return;
    size_t cap = b->cap ? b->cap : 256;
    while (cap < b->len + extra)
        cap *= 2;
    char *data = realloc(b->data, cap);
    if (!data) {
        b->overflow = 1;
        return;
    }
    b->data = data;
    b->cap = cap;
}

static void buf_put(Buf *b, const char *s, size_t n)
{
    buf_reserve(b, n);
    if (b->overflow)
        return;
    memcpy(b->data + b->len, s, n);
    b->len += n;
}

static void buf_puts(Buf *b, const char *s) { buf_put(b, s, strlen(s)); }

/* A JSON string literal for UTF-8 text produced by this program (never user text). */
static void buf_put_ascii_literal(Buf *b, const char *s)
{
    buf_puts(b, "\"");
    buf_puts(b, s);
    buf_puts(b, "\"");
}

/* ---------- framing ---------- */

static int read_full(int fd, void *dst, size_t n)
{
    char *p = dst;
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r == 0)
            return 0;
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        p += r;
        n -= (size_t)r;
    }
    return 1;
}

static int write_full(int fd, const void *src, size_t n)
{
    const char *p = src;
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

static int write_frame(const char *data, size_t len)
{
    unsigned char header[4] = {(unsigned char)(len >> 24), (unsigned char)(len >> 16),
                               (unsigned char)(len >> 8), (unsigned char)len};
    if (write_full(STDOUT_FILENO, header, 4) < 0 || write_full(STDOUT_FILENO, data, len) < 0)
        return -1;
    return 0;
}

/* ---------- deadline ---------- */

static int deadline_passed(const Deadline *d)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec > d->deadline.tv_sec ||
           (now.tv_sec == d->deadline.tv_sec && now.tv_nsec >= d->deadline.tv_nsec);
}

static int interrupt_handler(JSRuntime *rt, void *opaque)
{
    (void)rt;
    Deadline *d = opaque;
    if (!d->fired && deadline_passed(d))
        d->fired = 1;
    return d->fired;
}

static void deadline_start(Deadline *d, long timeout_ms)
{
    clock_gettime(CLOCK_MONOTONIC, &d->deadline);
    d->deadline.tv_sec += timeout_ms / 1000;
    d->deadline.tv_nsec += (timeout_ms % 1000) * 1000000L;
    if (d->deadline.tv_nsec >= 1000000000L) {
        d->deadline.tv_sec += 1;
        d->deadline.tv_nsec -= 1000000000L;
    }
    d->fired = 0;
}

/* ---------- context ---------- */

/*
 * ECMAScript built-ins only. JS_NewContext would also add `performance` (a clock); nothing
 * here adds std, os, console, timers or a module loader.
 */
static JSContext *new_context(JSRuntime *rt)
{
    JSContext *ctx = JS_NewContextRaw(rt);
    if (!ctx)
        return NULL;
    if (JS_AddIntrinsicBaseObjects(ctx) || JS_AddIntrinsicDate(ctx) || JS_AddIntrinsicEval(ctx) ||
        JS_AddIntrinsicRegExp(ctx) || JS_AddIntrinsicJSON(ctx) || JS_AddIntrinsicProxy(ctx) ||
        JS_AddIntrinsicMapSet(ctx) || JS_AddIntrinsicTypedArrays(ctx) ||
        JS_AddIntrinsicPromise(ctx) || JS_AddIntrinsicWeakRef(ctx)) {
        JS_FreeContext(ctx);
        return NULL;
    }
    return ctx;
}

/*
 * [map entry reader, Number/String/Boolean.prototype.valueOf, then sample objects whose class
 * IDs identify primitive wrappers and arguments objects].
 */
static const char HELPERS_SOURCE[] =
    "(() => {"
    "  const apply = Reflect.apply, entries = Map.prototype.entries, push = Array.prototype.push;"
    "  const next = Object.getPrototypeOf(new Map().entries()).next;"
    "  const mapEntries = (m) => {"
    "    const it = apply(entries, m, []), out = [];"
    "    for (let r = apply(next, it, []); !r.done; r = apply(next, it, []))"
    "      apply(push, out, [r.value[0], r.value[1]]);"
    "    return out;"
    "  };"
    "  return [mapEntries, Number.prototype.valueOf, String.prototype.valueOf,"
    "          Boolean.prototype.valueOf, new Number(0), new String(''), new Boolean(false),"
    "          (function () { 'use strict'; return arguments; })(),"
    "          (function (a) { return arguments; })(0)];"
    "})()";

static int load_intrinsics(JSContext *ctx, Intrinsics *in)
{
    memset(in, 0, sizeof *in);
    in->helpers = JS_Eval(ctx, HELPERS_SOURCE, sizeof HELPERS_SOURCE - 1, "<archon>",
                          JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(in->helpers))
        return -1;
    JSValue items[9];
    for (uint32_t i = 0; i < 9; i++) {
        items[i] = JS_GetPropertyUint32(ctx, in->helpers, i);
        /* The array keeps every item alive; hold borrowed copies. */
        JS_FreeValue(ctx, items[i]);
    }
    in->map_entries = items[0];
    in->number_value_of = items[1];
    in->string_value_of = items[2];
    in->boolean_value_of = items[3];
    in->number_class = JS_GetClassID(items[4]);
    in->string_class = JS_GetClassID(items[5]);
    in->boolean_class = JS_GetClassID(items[6]);
    in->arguments_class = JS_GetClassID(items[7]);
    in->mapped_arguments_class = JS_GetClassID(items[8]);
    return 0;
}

/* ---------- typed value encoding ---------- */

static int is_hex(char c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

/*
 * A JSON string literal for a JS string. JSON.stringify of a primitive string never calls user
 * code; it writes paired surrogates as UTF-8 and escapes only lone ones as \udXXX, which this
 * replaces with U+FFFD so the response is valid UTF-8 JSON.
 */
static int put_quoted(JSContext *ctx, Buf *out, JSValueConst str)
{
    JSValue json = JS_JSONStringify(ctx, str, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(json))
        return -1;
    size_t len;
    const char *s = JS_ToCStringLen(ctx, &len, json);
    JS_FreeValue(ctx, json);
    if (!s)
        return -1;
    size_t start = 0;
    for (size_t i = 0; i + 1 < len; i++) {
        if (s[i] != '\\')
            continue;
        if (s[i + 1] == 'u' && i + 5 < len && (s[i + 2] == 'd' || s[i + 2] == 'D') &&
            s[i + 3] != 0 && strchr("89abcdefABCDEF", s[i + 3]) && is_hex(s[i + 4]) && is_hex(s[i + 5])) {
            buf_put(out, s + start, i - start);
            buf_puts(out, "\\ufffd");
            start = i + 6;
            i += 5;
        } else {
            i++; /* skip the escaped character */
        }
    }
    buf_put(out, s + start, len - start);
    JS_FreeCString(ctx, s);
    return 0;
}

static void put_json_string(Encoder *e, JSValueConst str, EncStatus *status)
{
    if (put_quoted(e->ctx, e->out, str) < 0)
        *status = ENC_EXCEPTION;
}

/* Upstream getObject: fitsInInt / fitsInLong first, then double. -0 does not fit a long. */
static void put_number(Encoder *e, double d)
{
    char tmp[64];
    if (isnan(d)) {
        buf_puts(e->out, "[\"nonfinite\",\"NaN\"]");
    } else if (isinf(d)) {
        buf_puts(e->out, d > 0 ? "[\"nonfinite\",\"Infinity\"]" : "[\"nonfinite\",\"-Infinity\"]");
    } else if (d == 0 && signbit(d)) {
        buf_puts(e->out, "[\"float\",-0.0]");
    } else if (d == trunc(d) && d >= -9223372036854775808.0 && d < 9223372036854775808.0) {
        snprintf(tmp, sizeof tmp, "[\"int\",\"%lld\"]", (long long)d);
        buf_puts(e->out, tmp);
    } else {
        /* The shortest round-trip digits; always with a fraction or exponent so the reader
         * decodes a float. */
        JSValue num = JS_NewFloat64(e->ctx, d);
        const char *s = JS_ToCString(e->ctx, num);
        buf_puts(e->out, "[\"float\",");
        if (s) {
            buf_puts(e->out, s);
            if (!strpbrk(s, ".e"))
                buf_puts(e->out, ".0");
            JS_FreeCString(e->ctx, s);
        } else {
            buf_puts(e->out, "0.0");
        }
        buf_puts(e->out, "]");
    }
}

static void put_bigint(Encoder *e, JSValueConst v, EncStatus *status)
{
    const char *s = JS_ToCString(e->ctx, v);
    if (!s) {
        *status = ENC_EXCEPTION;
        return;
    }
    char *end;
    errno = 0;
    long long n = strtoll(s, &end, 10);
    if (errno == 0 && *end == '\0') {
        char tmp[64];
        snprintf(tmp, sizeof tmp, "[\"int\",\"%lld\"]", n);
        buf_puts(e->out, tmp);
    } else {
        /* Outside the long range: a double only when it holds the value exactly
         * (Value#fitsInDouble); otherwise GraalJS falls through to an empty member map. */
        double d = strtod(s, NULL);
        char exact[400];
        if (isfinite(d) && snprintf(exact, sizeof exact, "%.0f", d) < (int)sizeof exact &&
            strcmp(exact, s) == 0)
            put_number(e, d);
        else
            buf_puts(e->out, "[\"map\",[]]");
    }
    JS_FreeCString(e->ctx, s);
}

static void encode(Encoder *e, JSValueConst v, int depth, EncStatus *status);

static void encode_list(Encoder *e, JSValueConst v, int depth, EncStatus *status)
{
    int64_t len;
    if (JS_GetLength(e->ctx, v, &len) < 0) {
        *status = ENC_EXCEPTION;
        return;
    }
    buf_puts(e->out, "[\"list\",[");
    for (int64_t i = 0; i < len && *status == ENC_OK && !e->out->overflow; i++) {
        if (i > 0)
            buf_puts(e->out, ",");
        JSValue item = JS_GetPropertyInt64(e->ctx, v, i);
        if (JS_IsException(item)) {
            *status = ENC_EXCEPTION;
            return;
        }
        encode(e, item, depth + 1, status);
        JS_FreeValue(e->ctx, item);
    }
    buf_puts(e->out, "]]");
}

static void encode_map_entries(Encoder *e, JSValueConst v, int depth, EncStatus *status)
{
    JSValue flat = JS_Call(e->ctx, e->intrinsics->map_entries, JS_UNDEFINED, 1, &v);
    if (JS_IsException(flat)) {
        *status = ENC_EXCEPTION;
        return;
    }
    int64_t len;
    if (JS_GetLength(e->ctx, flat, &len) < 0) {
        JS_FreeValue(e->ctx, flat);
        *status = ENC_EXCEPTION;
        return;
    }
    buf_puts(e->out, "[\"map\",[");
    for (int64_t i = 0; i + 1 < len && *status == ENC_OK && !e->out->overflow; i += 2) {
        if (i > 0)
            buf_puts(e->out, ",");
        JSValue key = JS_GetPropertyInt64(e->ctx, flat, i);
        JSValue val = JS_GetPropertyInt64(e->ctx, flat, i + 1);
        buf_puts(e->out, "[");
        encode(e, key, depth + 1, status);
        buf_puts(e->out, ",");
        if (*status == ENC_OK)
            encode(e, val, depth + 1, status);
        buf_puts(e->out, "]");
        JS_FreeValue(e->ctx, key);
        JS_FreeValue(e->ctx, val);
    }
    buf_puts(e->out, "]]");
    JS_FreeValue(e->ctx, flat);
}

/* Own enumerable string-keyed properties, read through [[Get]] (getters run). */
static void encode_members(Encoder *e, JSValueConst v, int depth, EncStatus *status)
{
    JSPropertyEnum *props;
    uint32_t count;
    if (JS_GetOwnPropertyNames(e->ctx, &props, &count, v, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) <
        0) {
        *status = ENC_EXCEPTION;
        return;
    }
    buf_puts(e->out, "[\"map\",[");
    for (uint32_t i = 0; i < count && *status == ENC_OK && !e->out->overflow; i++) {
        if (i > 0)
            buf_puts(e->out, ",");
        JSValue key = JS_AtomToString(e->ctx, props[i].atom);
        JSValue val = JS_GetProperty(e->ctx, v, props[i].atom);
        if (JS_IsException(key) || JS_IsException(val)) {
            JS_FreeValue(e->ctx, key);
            JS_FreeValue(e->ctx, val);
            *status = ENC_EXCEPTION;
            break;
        }
        buf_puts(e->out, "[[\"str\",");
        put_json_string(e, key, status);
        buf_puts(e->out, "],");
        if (*status == ENC_OK)
            encode(e, val, depth + 1, status);
        buf_puts(e->out, "]");
        JS_FreeValue(e->ctx, key);
        JS_FreeValue(e->ctx, val);
    }
    buf_puts(e->out, "]]");
    JS_FreePropertyEnum(e->ctx, props, count);
}

static void encode(Encoder *e, JSValueConst v, int depth, EncStatus *status)
{
    if (*status != ENC_OK || e->out->overflow)
        return;
    if (depth > MAX_DEPTH) {
        *status = ENC_LIMIT;
        return;
    }
    if (JS_IsNull(v) || JS_IsUndefined(v)) {
        buf_puts(e->out, "[\"null\"]");
    } else if (JS_IsBool(v)) {
        buf_puts(e->out, JS_ToBool(e->ctx, v) ? "[\"bool\",true]" : "[\"bool\",false]");
    } else if (JS_IsNumber(v)) {
        double d;
        JS_ToFloat64(e->ctx, &d, v);
        put_number(e, d);
    } else if (JS_IsBigInt(v)) {
        put_bigint(e, v, status);
    } else if (JS_IsString(v)) {
        buf_puts(e->out, "[\"str\",");
        put_json_string(e, v, status);
        buf_puts(e->out, "]");
    } else if (!JS_IsObject(v)) {
        /* Symbols and other primitives have no members. */
        buf_puts(e->out, "[\"map\",[]]");
    } else if (JS_IsProxy(v)) {
        /* GraalJS reads a proxy through its members, even a proxy of an array. */
        encode_members(e, v, depth, status);
    } else {
        const Intrinsics *in = e->intrinsics;
        JSClassID cid = JS_GetClassID(v);
        if (JS_IsArray(v) || JS_GetTypedArrayType(v) >= 0 || cid == in->arguments_class ||
            cid == in->mapped_arguments_class) {
            encode_list(e, v, depth, status);
        } else if (cid == in->number_class || cid == in->string_class ||
                   cid == in->boolean_class) {
            /* Primitive wrappers read as their primitive value. */
            JSValue fn = cid == in->number_class   ? in->number_value_of
                         : cid == in->string_class ? in->string_value_of
                                                   : in->boolean_value_of;
            JSValue prim = JS_Call(e->ctx, fn, v, 0, NULL);
            if (JS_IsException(prim)) {
                *status = ENC_EXCEPTION;
                return;
            }
            encode(e, prim, depth + 1, status);
            JS_FreeValue(e->ctx, prim);
        } else if (JS_IsMap(v)) {
            encode_map_entries(e, v, depth, status);
        } else {
            encode_members(e, v, depth, status);
        }
    }
}

/* ---------- errors ---------- */

/* The line of the innermost frame in the script, from the `stack` of an Error. */
static int error_line(JSContext *ctx, JSValueConst exc)
{
    if (!JS_IsError(exc))
        return -1;
    JSValue stack = JS_GetPropertyStr(ctx, exc, "stack");
    int line = -1;
    if (JS_IsString(stack)) {
        const char *s = JS_ToCString(ctx, stack);
        if (s) {
            const char *p = strstr(s, SCRIPT_NAME ":");
            if (p)
                line = atoi(p + strlen(SCRIPT_NAME ":"));
            JS_FreeCString(ctx, s);
        }
    }
    JS_FreeValue(ctx, stack);
    return line > 0 ? line : -1;
}

/* An error response. `message` is a JS string, or JS_UNDEFINED to use `fallback`. */
static void put_error(Buf *out, JSContext *ctx, const char *kind, JSValueConst message,
                      const char *fallback, int line)
{
    out->len = 0;
    out->overflow = 0;
    buf_puts(out, "{\"error\":");
    buf_put_ascii_literal(out, kind);
    buf_puts(out, ",\"message\":");
    size_t mark = out->len;
    if (JS_IsUndefined(message) || put_quoted(ctx, out, message) < 0) {
        out->len = mark;
        buf_put_ascii_literal(out, fallback);
    }
    char tmp[48];
    if (line > 0)
        snprintf(tmp, sizeof tmp, ",\"line\":%d}", line);
    else
        snprintf(tmp, sizeof tmp, ",\"line\":null}");
    buf_puts(out, tmp);
}

static void put_fixed_error(Buf *out, const char *kind, const char *message)
{
    put_error(out, NULL, kind, JS_UNDEFINED, message, -1);
}

static void put_exception(Buf *out, JSContext *ctx, const char *kind, const Deadline *d)
{
    JSValue exc = JS_GetException(ctx);
    if (d->fired || JS_IsUncatchableError(exc)) {
        JS_FreeValue(ctx, exc);
        put_fixed_error(out, "timeout", "interrupted");
        return;
    }
    int line = error_line(ctx, exc);
    JSValue message = JS_ToString(ctx, exc);
    if (JS_IsException(message)) {
        /* toString itself threw; drop that second exception. */
        JS_FreeValue(ctx, JS_GetException(ctx));
        message = JS_UNDEFINED;
    }
    put_error(out, ctx, kind, message, "exception", line);
    JS_FreeValue(ctx, message);
    JS_FreeValue(ctx, exc);
    if (d->fired) /* the deadline passed while converting the exception */
        put_fixed_error(out, "timeout", "interrupted");
}

/* ---------- requests ---------- */

static char *get_string(JSContext *ctx, JSValueConst obj, const char *name, size_t *len)
{
    JSValue v = JS_GetPropertyStr(ctx, obj, name);
    char *copy = NULL;
    if (JS_IsString(v)) {
        const char *s = JS_ToCStringLen(ctx, len, v);
        if (s) {
            copy = malloc(*len + 1);
            if (copy) {
                memcpy(copy, s, *len);
                copy[*len] = '\0';
            }
            JS_FreeCString(ctx, s);
        }
    }
    JS_FreeValue(ctx, v);
    return copy;
}

static void run_script(JSContext *ctx, Buf *out, const Deadline *d, int parse_only,
                       const char *script, size_t script_len, const Intrinsics *intrinsics)
{
    int flags = JS_EVAL_TYPE_GLOBAL | (parse_only ? JS_EVAL_FLAG_COMPILE_ONLY : 0);
    JSValue result = JS_Eval(ctx, script, script_len, SCRIPT_NAME, flags);
    if (JS_IsException(result)) {
        put_exception(out, ctx, parse_only ? "syntax" : "runtime", d);
        return;
    }
    if (parse_only) {
        JS_FreeValue(ctx, result);
        buf_puts(out, "{\"ok\":[\"null\"]}");
        return;
    }
    Encoder e = {ctx, out, intrinsics};
    EncStatus status = ENC_OK;
    buf_puts(out, "{\"ok\":");
    encode(&e, result, 0, &status);
    buf_puts(out, "}");
    JS_FreeValue(ctx, result);
    if (status == ENC_EXCEPTION)
        put_exception(out, ctx, "conversion", d);
    else if (status == ENC_LIMIT)
        put_fixed_error(out, "limit", "result is nested too deeply");
    else if (out->overflow)
        put_fixed_error(out, "limit", "result is too large");
    else if (d->fired)
        put_fixed_error(out, "timeout", "interrupted");
}

static void handle(const Config *cfg, const char *request, size_t request_len, Buf *out)
{
    Deadline d;
    deadline_start(&d, cfg->timeout_ms);

    JSRuntime *rt = JS_NewRuntime();
    if (!rt) {
        put_fixed_error(out, "runtime", "cannot create runtime");
        return;
    }
    JS_SetMemoryLimit(rt, cfg->memory_limit);
    JS_SetMaxStackSize(rt, cfg->stack_limit);
    JS_SetInterruptHandler(rt, interrupt_handler, &d);

    JSContext *ctx = new_context(rt);
    if (!ctx) {
        JS_FreeRuntime(rt);
        put_fixed_error(out, "runtime", "cannot create context");
        return;
    }

    Intrinsics intrinsics;
    int loaded = load_intrinsics(ctx, &intrinsics);
    JSValue req = JS_ParseJSON(ctx, request, request_len, "<request>");
    char *op = NULL, *script = NULL;
    size_t op_len = 0, script_len = 0;

    if (loaded < 0 || JS_IsException(req)) {
        put_exception(out, ctx, "request", &d);
    } else if (!(op = get_string(ctx, req, "op", &op_len)) ||
               !(script = get_string(ctx, req, "script", &script_len))) {
        put_fixed_error(out, "request", "op and script must be strings");
    } else if (strcmp(op, "parse") == 0) {
        run_script(ctx, out, &d, 1, script, script_len, &intrinsics);
    } else if (strcmp(op, "eval") == 0) {
        JSValue global = JS_GetGlobalObject(ctx);
        JSValue input = JS_GetPropertyStr(ctx, req, "input");
        if (JS_SetPropertyStr(ctx, global, "$", input) < 0)
            put_exception(out, ctx, "request", &d);
        else
            run_script(ctx, out, &d, 0, script, script_len, &intrinsics);
        JS_FreeValue(ctx, global);
    } else {
        put_fixed_error(out, "request", "unknown op");
    }

    free(op);
    free(script);
    JS_FreeValue(ctx, req);
    JS_FreeValue(ctx, intrinsics.helpers);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
}

/* ---------- main ---------- */

static int parse_size(const char *s, size_t *out)
{
    char *end;
    errno = 0;
    unsigned long long v = strtoull(s, &end, 10);
    if (errno || *end || v == 0 || v > SIZE_MAX)
        return -1;
    *out = (size_t)v;
    return 0;
}

static int parse_args(int argc, char **argv, Config *cfg)
{
    for (int i = 1; i < argc; i++) {
        if (i + 1 >= argc)
            return -1;
        const char *flag = argv[i], *value = argv[++i];
        size_t n;
        if (parse_size(value, &n) < 0)
            return -1;
        if (strcmp(flag, "--memory-limit") == 0)
            cfg->memory_limit = n;
        else if (strcmp(flag, "--stack-limit") == 0)
            cfg->stack_limit = n;
        else if (strcmp(flag, "--timeout-ms") == 0 && n <= LONG_MAX / 1000000L)
            cfg->timeout_ms = (long)n;
        else if (strcmp(flag, "--max-output") == 0)
            cfg->max_output = n;
        else
            return -1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    Config cfg = {DEFAULT_MEMORY_LIMIT, DEFAULT_STACK_LIMIT, DEFAULT_TIMEOUT_MS,
                  DEFAULT_MAX_OUTPUT};
    if (parse_args(argc, argv, &cfg) < 0) {
        fprintf(stderr,
                "usage: archon_js [--memory-limit BYTES] [--stack-limit BYTES] "
                "[--timeout-ms MS] [--max-output BYTES]\n");
        return 2;
    }

    for (;;) {
        unsigned char header[4];
        int r = read_full(STDIN_FILENO, header, 4);
        if (r == 0)
            return 0;
        if (r < 0)
            return 1;
        size_t len = ((size_t)header[0] << 24) | ((size_t)header[1] << 16) |
                     ((size_t)header[2] << 8) | header[3];
        if (len > MAX_REQUEST)
            return 1;
        char *request = malloc(len + 1);
        if (!request || read_full(STDIN_FILENO, request, len) != 1)
            return 1;
        request[len] = '\0';

        Buf out = {NULL, 0, 0, cfg.max_output, 0};
        handle(&cfg, request, len, &out);
        free(request);
        if (out.overflow) {
            /* Only an error response can be left here; keep it small. */
            out.len = 0;
            out.overflow = 0;
            out.max = SIZE_MAX;
            put_fixed_error(&out, "limit", "result is too large");
        }
        int w = write_frame(out.data, out.len);
        free(out.data);
        if (w < 0)
            return 1;
    }
}
