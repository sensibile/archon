/*
 * Copyright Conductor Authors.
 * Copyright 2026 sensibile
 *
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 * The result conversion follows extractBody in conductor-oss
 * json-jq-task/src/main/java/com/netflix/conductor/tasks/json/JsonJqTransform.java
 * at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
 * Modified by sensibile: rewritten in C over jqlang values instead of jackson-jq nodes
 * (ADR 0026, decision 6).
 *
 * archon_jq: the jq evaluator process of Archon (ADR 0026, decision 6).
 *
 * Reads length-prefixed JSON requests from stdin and writes length-prefixed JSON responses to
 * stdout, the framing of an Erlang port opened with {:packet, 4}. Each request compiles its
 * query in a new jq state. Isolation:
 *
 *   - the environment is emptied at start ($ENV and env see only TZ=UTC);
 *   - a query that imports or includes a module is rejected before it is compiled, the
 *     library search path is empty (so modulemeta finds nothing) and there is no input beyond
 *     the request's (input and inputs have nothing to read);
 *   - debug and stderr messages are dropped, and so is anything jq writes to stderr itself;
 *     halt and halt_error are errors;
 *   - memory: the vendored jq and oniguruma sources allocate through the counting functions
 *     below (include/archon_jq_alloc.h). Going over --memory-limit answers a "limit" error and
 *     ends the process; the worker starts a new one. On Linux an address space limit
 *     (setrlimit) backs this up;
 *   - time: an interval timer answers a "timeout" error after --timeout-ms and ends the
 *     process. The worker kills the process if no answer comes a little later;
 *   - the answer is at most --max-output bytes and 1000 levels deep.
 *
 * Request:  {"op": "eval", "query": "...", "input": <JSON>}
 * Response: {"ok": [<JSON>...]} or {"error": kind, "message": "..."}; an error answered on the
 * way out (memory or time limit) has "exit": true, and the process ends right after it.
 *
 * Results are plain JSON. As upstream's extractBody turns a jackson-jq number into a long when
 * it is integral and a double otherwise, a number is written as an integer when it is integral
 * and within the long range, and with a fraction or exponent otherwise; a number jq kept as
 * written in the input or the query (its literal) is an integer only when that literal is.
 * NaN and the infinities are the strings "NaN", "Infinity" and "-Infinity", as upstream stores
 * a non-finite double.
 *
 * Error kinds: "syntax" (the query does not compile), "runtime" (the query raised an error or
 * halted), "limit" (memory, result size or depth), "timeout", "request" (malformed request or
 * a module import).
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <malloc/malloc.h>
#define usable_size(p) malloc_size(p)
#else
#include <malloc.h>
#define usable_size(p) malloc_usable_size(p)
#endif

#if defined(__linux__)
#include <sys/resource.h>
#endif

#if defined(__SANITIZE_ADDRESS__)
#define ARCHON_SANITIZED 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define ARCHON_SANITIZED 1
#endif
#endif

#include "compile.h"
#include "jq.h"
#include "jq_parser.h"
#include "jv.h"
#include "locfile.h"

#define DEFAULT_MEMORY_LIMIT (64u * 1024 * 1024)
#define DEFAULT_TIMEOUT_MS 4000
#define DEFAULT_MAX_OUTPUT (16u * 1024 * 1024)
#define MAX_REQUEST (256u * 1024 * 1024)
#define MAX_DEPTH 1000
/* Address space on top of the memory limit for the program, libc and the allocator's slack. */
#define ADDRESS_SPACE_MARGIN (512u * 1024 * 1024)

typedef struct {
    size_t memory_limit;
    long timeout_ms;
    size_t max_output;
} Config;

typedef struct {
    char *data;
    size_t len;
    size_t cap;
    size_t max;
    int overflow;
} Buf;

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

/* Async-signal-safe: also used from the timer handler and the allocator. */
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

/*
 * Answers that end the process from inside an evaluation: built before it starts, written
 * with write(2) only, then _exit. No allocation, so they are safe in a signal handler and in
 * the allocator.
 */
static const char TIMEOUT_ANSWER[] =
    "{\"error\":\"timeout\",\"message\":\"interrupted\",\"exit\":true}";
static const char MEMORY_ANSWER[] =
    "{\"error\":\"limit\",\"message\":\"memory limit exceeded\",\"exit\":true}";

_Static_assert(sizeof(TIMEOUT_ANSWER) <= 128 && sizeof(MEMORY_ANSWER) <= 128,
               "the exit answers fit answer_and_exit's frame");

/* Set while a request is being answered: an abort then answers it before exiting. */
static volatile sig_atomic_t answering;

static void answer_and_exit(const char *answer, size_t len)
{
    /* One answer only: the timer cannot interrupt this one with its own. */
    sigset_t alarm;
    sigemptyset(&alarm);
    sigaddset(&alarm, SIGALRM);
    sigprocmask(SIG_BLOCK, &alarm, NULL);
    if (answering) {
        /* Header and body in one write, so nothing can come between them. */
        char frame[4 + 128];
        frame[0] = (char)(len >> 24);
        frame[1] = (char)(len >> 16);
        frame[2] = (char)(len >> 8);
        frame[3] = (char)len;
        memcpy(frame + 4, answer, len);
        write_full(STDOUT_FILENO, frame, 4 + len);
    }
    _exit(0);
}

/* ---------- counted allocation (include/archon_jq_alloc.h) ---------- */

static size_t memory_limit = DEFAULT_MEMORY_LIMIT;
static size_t counted;

static void over_limit(void) { answer_and_exit(MEMORY_ANSWER, sizeof(MEMORY_ANSWER) - 1); }

static void uncount(size_t n) { counted = n > counted ? 0 : counted - n; }

/* What may still be allocated (usable sizes can take the count past the limit). */
static size_t room(void) { return counted >= memory_limit ? 0 : memory_limit - counted; }

void *archon_jq_malloc(size_t size)
{
    if (size > room())
        over_limit();
    void *p = malloc(size);
    if (p)
        counted += usable_size(p);
    return p;
}

void *archon_jq_calloc(size_t count, size_t size)
{
    if (size != 0 && count > room() / size)
        over_limit();
    void *p = calloc(count, size);
    if (p)
        counted += usable_size(p);
    return p;
}

void *archon_jq_realloc(void *ptr, size_t size)
{
    size_t old = ptr ? usable_size(ptr) : 0;
    if (size > old && size - old > room())
        over_limit();
    void *p = realloc(ptr, size);
    if (p) {
        uncount(old);
        counted += usable_size(p);
    } else if (size == 0) {
        uncount(old);
    }
    return p;
}

void archon_jq_free(void *ptr)
{
    if (ptr) {
        uncount(usable_size(ptr));
        free(ptr);
    }
}

char *archon_jq_strdup(const char *s)
{
    size_t n = strlen(s) + 1;
    char *p = archon_jq_malloc(n);
    if (p)
        memcpy(p, s, n);
    return p;
}

/* ---------- time limit ---------- */

static void on_alarm(int sig)
{
    (void)sig;
    answer_and_exit(TIMEOUT_ANSWER, sizeof(TIMEOUT_ANSWER) - 1);
}

static void set_timer(long ms)
{
    struct itimerval t = {{0, 0}, {ms / 1000, (ms % 1000) * 1000}};
    setitimer(ITIMER_REAL, &t, NULL);
}

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

/* A JSON string of UTF-8 text (jq strings are always valid UTF-8). */
static void put_json_string(Buf *b, const char *s, size_t n)
{
    static const char hex[] = "0123456789abcdef";
    buf_puts(b, "\"");
    size_t start = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c >= 0x20 && c != '"' && c != '\\')
            continue;
        buf_put(b, s + start, i - start);
        start = i + 1;
        switch (c) {
        case '"':
            buf_puts(b, "\\\"");
            break;
        case '\\':
            buf_puts(b, "\\\\");
            break;
        case '\n':
            buf_puts(b, "\\n");
            break;
        case '\r':
            buf_puts(b, "\\r");
            break;
        case '\t':
            buf_puts(b, "\\t");
            break;
        default: {
            char esc[6] = {'\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xf]};
            buf_put(b, esc, sizeof esc);
        }
        }
    }
    buf_put(b, s + start, n - start);
    buf_puts(b, "\"");
}

static void put_error(Buf *b, const char *kind, const char *message, size_t len)
{
    buf_puts(b, "{\"error\":\"");
    buf_puts(b, kind);
    buf_puts(b, "\",\"message\":");
    put_json_string(b, message, len);
    buf_puts(b, "}");
}

static void put_fixed_error(Buf *b, const char *kind, const char *message)
{
    put_error(b, kind, message, strlen(message));
}

/* ---------- results ---------- */

/* A literal of the form -?[0-9]+ whose value fits a Java long. */
static int long_literal(const char *s)
{
    const char *digits = s[0] == '-' ? s + 1 : s;
    size_t n = strlen(digits);
    if (n == 0 || n > 19)
        return 0;
    for (size_t i = 0; i < n; i++)
        if (digits[i] < '0' || digits[i] > '9')
            return 0;
    if (n < 19)
        return 1;
    return strcmp(digits, s[0] == '-' ? "9223372036854775808" : "9223372036854775807") <= 0;
}

/* The shortest decimal that reads back as d, with a fraction or exponent. */
static void put_double(Buf *b, double d)
{
    char text[40];
    for (int precision = 1; precision <= 17; precision++) {
        snprintf(text, sizeof text, "%.*g", precision, d);
        if (strtod(text, NULL) == d)
            break;
    }
    buf_puts(b, text);
    if (!strpbrk(text, ".eE"))
        buf_puts(b, ".0");
}

static void put_number(Buf *b, jv v)
{
    double d = jv_number_value(v);
    if (isnan(d)) {
        buf_puts(b, "\"NaN\"");
        return;
    }
    if (isinf(d)) {
        buf_puts(b, d > 0 ? "\"Infinity\"" : "\"-Infinity\"");
        return;
    }
    const char *literal = jv_number_has_literal(v) ? jv_number_get_literal(v) : NULL;
    if (literal) {
        if (long_literal(literal))
            buf_puts(b, strcmp(literal, "-0") == 0 ? "0" : literal);
        else
            put_double(b, d);
        return;
    }
    if (d == trunc(d) && d >= -9223372036854775808.0 && d < 9223372036854775808.0) {
        char text[24];
        snprintf(text, sizeof text, "%lld", (long long)d);
        buf_puts(b, text);
        return;
    }
    put_double(b, d);
}

/* Writes v (consumed). Returns 0, or -1 when it is nested too deeply. */
static int put_value(Buf *b, jv v, int depth)
{
    if (depth > MAX_DEPTH) {
        jv_free(v);
        return -1;
    }
    int status = 0;
    switch (jv_get_kind(v)) {
    case JV_KIND_NULL:
        buf_puts(b, "null");
        break;
    case JV_KIND_TRUE:
        buf_puts(b, "true");
        break;
    case JV_KIND_FALSE:
        buf_puts(b, "false");
        break;
    case JV_KIND_NUMBER:
        put_number(b, v);
        break;
    case JV_KIND_STRING:
        put_json_string(b, jv_string_value(v), (size_t)jv_string_length_bytes(jv_copy(v)));
        break;
    case JV_KIND_ARRAY: {
        buf_puts(b, "[");
        int n = jv_array_length(jv_copy(v));
        for (int i = 0; i < n && status == 0 && !b->overflow; i++) {
            if (i > 0)
                buf_puts(b, ",");
            status = put_value(b, jv_array_get(jv_copy(v), i), depth + 1);
        }
        buf_puts(b, "]");
        break;
    }
    case JV_KIND_OBJECT: {
        buf_puts(b, "{");
        int first = 1;
        for (int i = jv_object_iter(v); jv_object_iter_valid(v, i) && status == 0 && !b->overflow;
             i = jv_object_iter_next(v, i)) {
            if (!first)
                buf_puts(b, ",");
            first = 0;
            jv key = jv_object_iter_key(v, i);
            put_json_string(b, jv_string_value(key), (size_t)jv_string_length_bytes(jv_copy(key)));
            jv_free(key);
            buf_puts(b, ":");
            status = put_value(b, jv_object_iter_value(v, i), depth + 1);
        }
        buf_puts(b, "}");
        break;
    }
    default:
        break;
    }
    jv_free(v);
    return status;
}

/* ---------- evaluation ---------- */

typedef struct {
    jv messages; /* the compile errors jq reported, in order */
} Errors;

static void collect_error(void *data, jv message)
{
    Errors *errors = data;
    if (jv_get_kind(message) == JV_KIND_STRING)
        errors->messages = jv_array_append(errors->messages, message);
    else
        jv_free(message);
}

static void drop_message(void *data, jv message)
{
    (void)data;
    jv_free(message);
}

static jv no_input(jq_state *jq, void *data)
{
    (void)jq;
    (void)data;
    return jv_invalid();
}

/* Whether the query has an import or include directive (jq would read a file for it). */
static int imports_module(jq_state *jq, const char *query)
{
    struct locfile *source = locfile_init(jq, "<top-level>", query, (int)strlen(query));
    block program;
    int imports = 0;
    if (jq_parse(source, &program) == 0) {
        jv deps = block_take_imports(&program);
        imports = jv_array_length(deps) > 0;
        block_free(program);
    }
    locfile_free(source);
    return imports;
}

/*
 * The compile errors, one per line, without their "jq: error: " prefix and jq's closing
 * "jq: N compile error(s)" line.
 */
static void put_compile_error(Buf *out, jv messages)
{
    Buf text = {NULL, 0, 0, SIZE_MAX, 0};
    int n = jv_array_length(jv_copy(messages));
    for (int i = 0; i < n; i++) {
        jv m = jv_array_get(jv_copy(messages), i);
        const char *s = jv_string_value(m);
        if (i == n - 1 && n > 1 && strncmp(s, "jq: ", 4) == 0 && strstr(s, " compile error")) {
            jv_free(m);
            break;
        }
        if (strncmp(s, "jq: error: ", 11) == 0)
            s += 11;
        size_t len = strlen(s);
        while (len > 0 && s[len - 1] == '\n')
            len--;
        if (text.len > 0)
            buf_puts(&text, "\n");
        buf_put(&text, s, len);
        jv_free(m);
    }
    jv_free(messages);
    if (text.len == 0)
        put_fixed_error(out, "syntax", "the query does not compile");
    else
        put_error(out, "syntax", text.data, text.len);
    free(text.data);
}

static void put_runtime_error(Buf *out, jv message)
{
    if (jv_get_kind(message) == JV_KIND_STRING) {
        put_error(out, "runtime", jv_string_value(message),
                  (size_t)jv_string_length_bytes(jv_copy(message)));
        jv_free(message);
        return;
    }
    jv text = jv_dump_string(message, 0);
    text = jv_string_append_str(text, " (not a string)");
    put_error(out, "runtime", jv_string_value(text), (size_t)jv_string_length_bytes(jv_copy(text)));
    jv_free(text);
}

static void run_query(const char *query, jv input, Buf *out)
{
    jq_state *jq = jq_init();
    if (!jq) {
        jv_free(input);
        put_fixed_error(out, "limit", "memory limit exceeded");
        return;
    }
    Errors errors = {jv_array()};
    jq_set_error_cb(jq, collect_error, &errors);
    jq_set_debug_cb(jq, drop_message, NULL);
    jq_set_stderr_cb(jq, drop_message, NULL);
    jq_set_input_cb(jq, no_input, NULL);
    jq_set_attr(jq, jv_string("JQ_LIBRARY_PATH"), jv_array());

    if (imports_module(jq, query)) {
        jv_free(input);
        jv_free(errors.messages);
        jq_teardown(&jq);
        put_fixed_error(out, "request", "import and include are not supported");
        return;
    }
    /* imports_module reported any syntax error already; jq_compile reports it again. */
    jv_free(errors.messages);
    errors.messages = jv_array();

    if (!jq_compile(jq, query)) {
        jv_free(input);
        jq_teardown(&jq);
        put_compile_error(out, errors.messages);
        return;
    }
    jv_free(errors.messages);

    jq_start(jq, input, 0);
    jv results = jv_array();
    jv value;
    while (jv_is_valid(value = jq_next(jq)))
        results = jv_array_append(results, value);

    if (jq_halted(jq)) {
        jv_free(value);
        jv_free(results);
        put_fixed_error(out, "runtime", "halt and halt_error are not supported");
    } else if (jv_invalid_has_msg(jv_copy(value))) {
        jv_free(results);
        put_runtime_error(out, jv_invalid_get_msg(value));
    } else {
        jv_free(value);
        buf_puts(out, "{\"ok\":");
        /* The list of results does not count: each result may nest MAX_DEPTH levels. */
        if (put_value(out, results, -1) < 0) {
            out->len = 0;
            put_fixed_error(out, "limit", "result is nested too deeply");
        } else {
            buf_puts(out, "}");
        }
    }
    jq_teardown(&jq);
}

static void handle(const Config *cfg, const char *request, size_t request_len, Buf *out)
{
    jv req = jv_parse_sized(request, (int)request_len);
    if (jv_get_kind(req) != JV_KIND_OBJECT) {
        jv_free(req);
        put_fixed_error(out, "request", "the request is not a JSON object");
        return;
    }
    jv op = jv_object_get(jv_copy(req), jv_string("op"));
    jv query = jv_object_get(jv_copy(req), jv_string("query"));
    jv input = jv_object_get(jv_copy(req), jv_string("input"));
    jv_free(req);

    if (jv_get_kind(op) != JV_KIND_STRING || strcmp(jv_string_value(op), "eval") != 0) {
        put_fixed_error(out, "request", "op must be \"eval\"");
    } else if (jv_get_kind(query) != JV_KIND_STRING) {
        put_fixed_error(out, "request", "query must be a string");
    } else if (!jv_is_valid(input)) {
        put_fixed_error(out, "request", "input is missing");
    } else {
        set_timer(cfg->timeout_ms);
        run_query(jv_string_value(query), jv_copy(input), out);
        set_timer(0);
    }
    jv_free(op);
    jv_free(query);
    jv_free(input);
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
        else if (strcmp(flag, "--timeout-ms") == 0 && n <= LONG_MAX / 1000)
            cfg->timeout_ms = (long)n;
        else if (strcmp(flag, "--max-output") == 0)
            cfg->max_output = n;
        else
            return -1;
    }
    return 0;
}

#if !defined(__linux__)
extern char **environ;
#endif

/* clearenv(3), which macOS lacks. */
static void clear_environment(void)
{
#if defined(__linux__)
    clearenv();
#else
    static char *empty[] = {NULL};
    environ = empty;
#endif
}

static void isolate(const Config *cfg)
{
    /* No server environment for $ENV and env; times are UTC. */
    clear_environment();
    setenv("TZ", "UTC", 1);
    tzset();

#if !defined(ARCHON_SANITIZED)
    /* Whatever jq itself writes to stderr goes nowhere (the sanitizers report there). */
    int null_fd = open("/dev/null", O_WRONLY);
    if (null_fd >= 0) {
        dup2(null_fd, STDERR_FILENO);
        close(null_fd);
    }
#endif

#if defined(__linux__) && !defined(ARCHON_SANITIZED)
    /* A second limit under the counted one: the whole address space. */
    if (cfg->memory_limit <= SIZE_MAX - ADDRESS_SPACE_MARGIN) {
        struct rlimit limit;
        limit.rlim_cur = limit.rlim_max = (rlim_t)(cfg->memory_limit + ADDRESS_SPACE_MARGIN);
        setrlimit(RLIMIT_AS, &limit);
    }
#else
    (void)cfg;
#endif

    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = on_alarm;
    sigemptyset(&action.sa_mask);
    sigaction(SIGALRM, &action, NULL);
    signal(SIGPIPE, SIG_IGN);
}

int main(int argc, char **argv)
{
    Config cfg = {DEFAULT_MEMORY_LIMIT, DEFAULT_TIMEOUT_MS, DEFAULT_MAX_OUTPUT};
    if (parse_args(argc, argv, &cfg) < 0) {
        fprintf(stderr, "usage: archon_jq [--memory-limit BYTES] [--timeout-ms MS] "
                        "[--max-output BYTES]\n");
        return 2;
    }
    memory_limit = cfg.memory_limit;
    isolate(&cfg);

    for (;;) {
        unsigned char header[4];
        int r = read_full(STDIN_FILENO, header, 4);
        if (r == 0)
            return 0;
        if (r < 0)
            return 1;
        size_t len = ((size_t)header[0] << 24) | ((size_t)header[1] << 16) |
                     ((size_t)header[2] << 8) | header[3];
        if (len > MAX_REQUEST || len > INT_MAX)
            return 1;
        char *request = malloc(len + 1);
        if (!request || read_full(STDIN_FILENO, request, len) != 1)
            return 1;
        request[len] = '\0';

        Buf out = {NULL, 0, 0, cfg.max_output, 0};
        answering = 1;
        handle(&cfg, request, len, &out);
        answering = 0;
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
