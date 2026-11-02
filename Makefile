# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Builds priv/archon_js, the script evaluator process (ADR 0015), and priv/archon_jq, the jq
# evaluator process (ADR 0026, decision 6). Run by elixir_make during `mix compile`; it can also
# be run directly.
#
#   make                      release build, priv/archon_js and priv/archon_jq
#   make ARCHON_JS_SANITIZE=1 AddressSanitizer + UndefinedBehaviorSanitizer build,
#                             priv/archon_js-sanitize (run the tests against it with
#                             ARCHON_JS_EXECUTABLE=priv/archon_js-sanitize mix test)
#   make ARCHON_JQ_SANITIZE=1 the same for priv/archon_jq-sanitize (ARCHON_JQ_EXECUTABLE)
#
# The vendored QuickJS-ng, jq and oniguruma sources are compiled as they are, without warning
# flags. Archon's own C code is compiled with warnings as errors.

MIX_APP_PATH ?= $(CURDIR)
PRIV_DIR := $(MIX_APP_PATH)/priv

CC ?= cc
SANITIZE_CFLAGS := -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined \
	-fno-sanitize-recover=undefined
SANITIZE_LDFLAGS := -fsanitize=address,undefined
WARNING_CFLAGS := -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Werror

.PHONY: all clean

ifdef ARCHON_JS_SANITIZE
all: $(PRIV_DIR)/archon_js-sanitize
else ifdef ARCHON_JQ_SANITIZE
all: $(PRIV_DIR)/archon_jq-sanitize
else
all: $(PRIV_DIR)/archon_js $(PRIV_DIR)/archon_jq
endif

# ---------- archon_js (QuickJS-ng) ----------

JS_BUILD_DIR := $(MIX_APP_PATH)/obj/archon_js$(if $(ARCHON_JS_SANITIZE),-sanitize)
JS_TARGET := $(PRIV_DIR)/archon_js$(if $(ARCHON_JS_SANITIZE),-sanitize)

QJS_DIR := c_src/quickjs-ng
JS_HOST_DIR := c_src/archon_js
QJS_SOURCES := quickjs.c libregexp.c libunicode.c dtoa.c
QJS_OBJECTS := $(addprefix $(JS_BUILD_DIR)/,$(QJS_SOURCES:.c=.o))
JS_HOST_OBJECT := $(JS_BUILD_DIR)/archon_js.o

JS_OPT_CFLAGS := $(if $(ARCHON_JS_SANITIZE),$(SANITIZE_CFLAGS),-O2)
JS_LDFLAGS := $(LDFLAGS) $(if $(ARCHON_JS_SANITIZE),$(SANITIZE_LDFLAGS))
JS_COMMON_CFLAGS := -std=gnu11 -D_GNU_SOURCE $(JS_OPT_CFLAGS)
QJS_CFLAGS := $(JS_COMMON_CFLAGS) -w
JS_HOST_CFLAGS := $(JS_COMMON_CFLAGS) $(WARNING_CFLAGS) -I$(QJS_DIR)
JS_LDLIBS := $(LDLIBS) -lm
ifeq ($(shell uname -s),Linux)
JS_LDLIBS += -lpthread
endif

$(JS_TARGET): $(QJS_OBJECTS) $(JS_HOST_OBJECT) | $(PRIV_DIR)
	$(CC) $(JS_LDFLAGS) -o $@ $^ $(JS_LDLIBS)

$(JS_BUILD_DIR)/%.o: $(QJS_DIR)/%.c $(wildcard $(QJS_DIR)/*.h) | $(JS_BUILD_DIR)
	$(CC) $(QJS_CFLAGS) -c -o $@ $<

$(JS_HOST_OBJECT): $(JS_HOST_DIR)/archon_js.c $(QJS_DIR)/quickjs.h | $(JS_BUILD_DIR)
	$(CC) $(JS_HOST_CFLAGS) -c -o $@ $<

# ---------- archon_jq (jqlang + oniguruma) ----------

JQ_BUILD_DIR := $(MIX_APP_PATH)/obj/archon_jq$(if $(ARCHON_JQ_SANITIZE),-sanitize)
JQ_TARGET := $(PRIV_DIR)/archon_jq$(if $(ARCHON_JQ_SANITIZE),-sanitize)

JQ_DIR := c_src/jq
JQ_HOST_DIR := c_src/archon_jq
JQ_SOURCES := src/builtin.c src/bytecode.c src/compile.c src/execute.c src/jv.c src/jv_alloc.c \
	src/jv_aux.c src/jv_dtoa.c src/jv_dtoa_tsd.c src/jv_file.c src/jv_parse.c src/jv_print.c \
	src/jv_unicode.c src/lexer.c src/linker.c src/locfile.c src/parser.c src/util.c \
	vendor/decNumber/decContext.c vendor/decNumber/decNumber.c
ONIG_SOURCES := regparse.c regcomp.c regexec.c regenc.c regerror.c regext.c regsyntax.c \
	regtrav.c regversion.c st.c unicode.c unicode_unfold_key.c unicode_fold1_key.c \
	unicode_fold2_key.c unicode_fold3_key.c ascii.c utf8.c
JQ_OBJECTS := $(addprefix $(JQ_BUILD_DIR)/jq/,$(JQ_SOURCES:.c=.o))
ONIG_OBJECTS := $(addprefix $(JQ_BUILD_DIR)/onig/,$(ONIG_SOURCES:.c=.o))
JQ_HOST_OBJECT := $(JQ_BUILD_DIR)/archon_jq.o
# jq's own build generates src/builtin.inc from src/builtin.jq with od and sed; so does this one.
JQ_BUILTIN_INC := $(JQ_BUILD_DIR)/gen/src/builtin.inc

JQ_OPT_CFLAGS := $(if $(ARCHON_JQ_SANITIZE),$(SANITIZE_CFLAGS),-O2)
JQ_LDFLAGS := $(LDFLAGS) $(if $(ARCHON_JQ_SANITIZE),$(SANITIZE_LDFLAGS))
JQ_COMMON_CFLAGS := -std=gnu11 -D_GNU_SOURCE $(JQ_OPT_CFLAGS)
# The vendored sources take jq_config.h (what configure would define) and archon_jq_alloc.h
# (their allocations go to archon_jq's counting functions) before anything else.
JQ_VENDOR_CFLAGS := $(JQ_COMMON_CFLAGS) -w -include $(JQ_HOST_DIR)/include/jq_config.h \
	-include $(JQ_HOST_DIR)/include/archon_jq_alloc.h -I$(JQ_HOST_DIR)/include \
	-I$(JQ_DIR)/oniguruma/src -I$(JQ_DIR)/vendor -I$(JQ_BUILD_DIR)/gen
JQ_HOST_CFLAGS := $(JQ_COMMON_CFLAGS) $(WARNING_CFLAGS) -include $(JQ_HOST_DIR)/include/jq_config.h \
	-isystem $(JQ_DIR)/src
JQ_LDLIBS := $(LDLIBS) -lm
ifeq ($(shell uname -s),Linux)
JQ_LDLIBS += -lpthread
endif
JQ_HEADERS := $(wildcard $(JQ_DIR)/src/*.h $(JQ_DIR)/vendor/decNumber/*.h $(JQ_HOST_DIR)/include/*.h)
ONIG_HEADERS := $(wildcard $(JQ_DIR)/oniguruma/src/*.h $(JQ_HOST_DIR)/include/*.h)

$(JQ_TARGET): $(JQ_OBJECTS) $(ONIG_OBJECTS) $(JQ_HOST_OBJECT) | $(PRIV_DIR)
	$(CC) $(JQ_LDFLAGS) -o $@ $^ $(JQ_LDLIBS)

$(JQ_BUILD_DIR)/jq/src/builtin.o: $(JQ_BUILTIN_INC)

$(JQ_BUILD_DIR)/jq/%.o: $(JQ_DIR)/%.c $(JQ_HEADERS)
	@mkdir -p $(@D)
	$(CC) $(JQ_VENDOR_CFLAGS) -c -o $@ $<

$(JQ_BUILD_DIR)/onig/%.o: $(JQ_DIR)/oniguruma/src/%.c $(ONIG_HEADERS)
	@mkdir -p $(@D)
	$(CC) $(JQ_VENDOR_CFLAGS) -c -o $@ $<

$(JQ_BUILTIN_INC): $(JQ_DIR)/src/builtin.jq
	@mkdir -p $(@D)
	od -v -A n -t o1 -- $< | \
	sed -e 's/$$/ /' \
	    -e 's/\([0123456789]\) /\1, /g' \
	    -e 's/ $$//' \
	    -e 's/ 0/  0/g' \
	    -e 's/ \([123456789]\)/ 0\1/g' > $@

$(JQ_HOST_OBJECT): $(JQ_HOST_DIR)/archon_jq.c $(JQ_HEADERS)
	@mkdir -p $(@D)
	$(CC) $(JQ_HOST_CFLAGS) -c -o $@ $<

# ---------- common ----------

$(PRIV_DIR) $(JS_BUILD_DIR):
	mkdir -p $@

clean:
	rm -rf $(PRIV_DIR)/archon_js $(PRIV_DIR)/archon_js-sanitize $(MIX_APP_PATH)/obj/archon_js \
		$(MIX_APP_PATH)/obj/archon_js-sanitize $(PRIV_DIR)/archon_jq \
		$(PRIV_DIR)/archon_jq-sanitize $(MIX_APP_PATH)/obj/archon_jq \
		$(MIX_APP_PATH)/obj/archon_jq-sanitize
