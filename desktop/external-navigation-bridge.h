/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef XANH_EXTERNAL_NAVIGATION_BRIDGE_H
#define XANH_EXTERNAL_NAVIGATION_BRIDGE_H

#include <webkit/webkit.h>

G_BEGIN_DECLS

#define XANH_TYPE_EXTERNAL_NAVIGATION_BRIDGE (xanh_external_navigation_bridge_get_type ())
G_DECLARE_FINAL_TYPE (
    XanhExternalNavigationBridge,
    xanh_external_navigation_bridge,
    XANH,
    EXTERNAL_NAVIGATION_BRIDGE,
    GObject)

XanhExternalNavigationBridge *xanh_external_navigation_bridge_new (
    WebKitUserContentManager *manager,
    GError **error);

G_END_DECLS

#endif
