/*
 * Copyright 2026 sensibile
 *
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 * Counted allocation for the vendored jq and oniguruma sources (ADR 0026, decision 6). The
 * Makefile force-includes this header into every vendored source file, so their malloc, calloc,
 * realloc, free and strdup calls go to archon_jq's counting functions; archon_jq's own code and
 * libc are not affected.
 *
 * The counting functions add no header to the blocks they hand out: they call the C library's
 * allocator and count the block's usable size (malloc_usable_size, malloc_size). A block that
 * libc allocated and jq frees through the counting free, or the other way round, is therefore
 * still a valid block of the same allocator; at worst the count is off by that block.
 */

#ifndef ARCHON_JQ_ALLOC_H
#define ARCHON_JQ_ALLOC_H

/* The C library's declarations first, under their own names. */
#include <stdlib.h>
#include <string.h>

void *archon_jq_malloc(size_t size);
void *archon_jq_calloc(size_t count, size_t size);
void *archon_jq_realloc(void *ptr, size_t size);
void archon_jq_free(void *ptr);
char *archon_jq_strdup(const char *s);

#define malloc archon_jq_malloc
#define calloc archon_jq_calloc
#define realloc archon_jq_realloc
#define free archon_jq_free
#define strdup archon_jq_strdup

#endif
