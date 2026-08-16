/* SPDX-License-Identifier: LGPL-2.1-or-later */

#include "xanh-config.h"

#ifndef XANH_PLUGIN_DIR
#error "XANH_PLUGIN_DIR must be defined by the build system"
#endif

const char *
xanh_config_plugin_dir(void)
{
    return XANH_PLUGIN_DIR;
}
