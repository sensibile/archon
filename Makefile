# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Builds priv/archon_js, the script evaluator process (ADR 0015). Run by elixir_make during
# `mix compile`; it can also be run directly.
#
#   make                      release build, priv/archon_js
#   make ARCHON_JS_SANITIZE=1 AddressSanitizer + UndefinedBehaviorSanitizer build,
#                             priv/archon_js-sanitize (run the tests against it with
#                             ARCHON_JS_EXECUTABLE=priv/archon_js-sanitize mix test)
#
# The vendored QuickJS-ng sources are compiled as they are, without warning flags. Archon's own
# C code is compiled with warnings as errors.

MIX_APP_PATH ?= $(CURDIR)
PRIV_DIR := $(MIX_APP_PATH)/priv
BUILD_DIR := $(MIX_APP_PATH)/obj/archon_js$(if $(ARCHON_JS_SANITIZE),-sanitize)
TARGET := $(PRIV_DIR)/archon_js$(if $(ARCHON_JS_SANITIZE),-sanitize)

QJS_DIR := c_src/quickjs-ng
HOST_DIR := c_src/archon_js
QJS_SOURCES := quickjs.c libregexp.c libunicode.c dtoa.c
QJS_OBJECTS := $(addprefix $(BUILD_DIR)/,$(QJS_SOURCES:.c=.o))
HOST_OBJECT := $(BUILD_DIR)/archon_js.o

CC ?= cc
OPT_CFLAGS := -O2
ifdef ARCHON_JS_SANITIZE
OPT_CFLAGS := -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=undefined
LDFLAGS += -fsanitize=address,undefined
endif

COMMON_CFLAGS := -std=gnu11 -D_GNU_SOURCE $(OPT_CFLAGS)
QJS_CFLAGS := $(COMMON_CFLAGS) -w
HOST_CFLAGS := $(COMMON_CFLAGS) -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Werror -I$(QJS_DIR)
LDLIBS += -lm
ifeq ($(shell uname -s),Linux)
LDLIBS += -lpthread
endif

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(QJS_OBJECTS) $(HOST_OBJECT) | $(PRIV_DIR)
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

$(BUILD_DIR)/%.o: $(QJS_DIR)/%.c $(wildcard $(QJS_DIR)/*.h) | $(BUILD_DIR)
	$(CC) $(QJS_CFLAGS) -c -o $@ $<

$(HOST_OBJECT): $(HOST_DIR)/archon_js.c $(QJS_DIR)/quickjs.h | $(BUILD_DIR)
	$(CC) $(HOST_CFLAGS) -c -o $@ $<

$(PRIV_DIR) $(BUILD_DIR):
	mkdir -p $@

clean:
	rm -rf $(PRIV_DIR)/archon_js $(PRIV_DIR)/archon_js-sanitize $(MIX_APP_PATH)/obj/archon_js \
		$(MIX_APP_PATH)/obj/archon_js-sanitize
