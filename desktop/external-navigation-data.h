/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef XANH_EXTERNAL_NAVIGATION_DATA_H
#define XANH_EXTERNAL_NAVIGATION_DATA_H

#include <glib.h>

G_BEGIN_DECLS

/* Verification boundary shared with the isolated bridge and unit test. */
gboolean xanh_external_navigation_parse_message (
    const gchar *message,
    gchar **external_uri,
    gchar **document_uri);

G_END_DECLS

#endif
