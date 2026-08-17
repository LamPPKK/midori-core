/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include <glib.h>

#ifdef XANH_ENABLE_FIREFOX_SYNC
#include "xanh_sync.h"
#endif

gboolean
xanh_sync_link_check (void)
{
#ifdef XANH_ENABLE_FIREFOX_SYNC
    char *version = xanh_sync_core_version ();
    gboolean compatible = version != NULL && g_str_has_prefix (version, "1.0.");
    xanh_sync_string_free (version);
    if (!compatible)
        g_warning ("Firefox Sync native core has an incompatible ABI");
    return compatible;
#else
    return TRUE;
#endif
}
