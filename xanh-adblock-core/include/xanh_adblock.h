/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#ifndef XANH_ADBLOCK_H
#define XANH_ADBLOCK_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct XanhAdblockEngine XanhAdblockEngine;

#define XANH_ADBLOCK_CORE_ABI_VERSION "1.0.0-alpha.1"

/* The caller must not free the engine while another thread is checking it. */
XanhAdblockEngine *xanh_adblock_engine_create(const char *filter_list_utf8);
XanhAdblockEngine *xanh_adblock_engine_create_default(void);
void xanh_adblock_engine_free(XanhAdblockEngine *engine);

/* Returns 1 to block, 0 to allow, and -1 on invalid input or engine failure. */
int32_t xanh_adblock_engine_should_block(
    const XanhAdblockEngine *engine,
    const char *url_utf8,
    const char *source_url_utf8,
    const char *request_type_utf8,
    const char *method_utf8);

/* Returns newly allocated UTF-8 JSON or NULL on failure. */
char *xanh_adblock_compile_webkit_json(const char *filter_list_utf8);
char *xanh_adblock_compile_webkit_default_json(void);

const char *xanh_adblock_core_version(void);
char *xanh_adblock_last_error(void);
void xanh_adblock_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
