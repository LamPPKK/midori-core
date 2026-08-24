/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#include "xanh_adblock.h"

#include <assert.h>
#include <stddef.h>
#include <string.h>

int main(void)
{
    assert(strcmp(xanh_adblock_core_version(), "1.0.0-alpha.1") == 0);

    XanhAdblockEngine *engine = xanh_adblock_engine_create_default();
    assert(engine != NULL);
    assert(xanh_adblock_engine_should_block(
               engine,
               "https://ads.doubleclick.net/banner.js",
               "https://news.example/article",
               "script",
               "GET") == 1);
    assert(xanh_adblock_engine_should_block(
               engine,
               "https://news.example/app.js",
               "https://news.example/article",
               "script",
               "GET") == 0);
    xanh_adblock_engine_free(engine);

    char *json = xanh_adblock_compile_webkit_default_json();
    assert(json != NULL);
    assert(json[0] == '[');
    xanh_adblock_string_free(json);

    assert(xanh_adblock_engine_should_block(NULL, NULL, NULL, NULL, NULL) == -1);
    char *error = xanh_adblock_last_error();
    assert(error != NULL);
    assert(strstr(error, "engine is required") != NULL);
    xanh_adblock_string_free(error);
    return 0;
}
