/*
 * Copyright 2026 sensibile
 *
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 * The config.h that oniguruma's configure script would generate, for the vendored oniguruma
 * sources in c_src/jq/oniguruma/ (ADR 0026, decision 6). Both supported hosts (Linux, macOS)
 * are LP64.
 */

#ifndef ARCHON_JQ_ONIG_CONFIG_H
#define ARCHON_JQ_ONIG_CONFIG_H

#define HAVE_ALLOCA 1
#define HAVE_ALLOCA_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIMES_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define STDC_HEADERS 1

#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_LONG_LONG 8
#define SIZEOF_VOIDP 8

#endif
