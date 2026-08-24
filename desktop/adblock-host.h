/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef XANH_ADBLOCK_HOST_H
#define XANH_ADBLOCK_HOST_H

#include <gio/gio.h>

G_BEGIN_DECLS

#define XANH_ADBLOCK_HOST_MAX_FILTER_LIST_BYTES ((gsize) 16 * 1024 * 1024)
#define XANH_ADBLOCK_HOST_MAX_CONTENT_BLOCKER_BYTES ((gsize) 64 * 1024 * 1024)
#define XANH_ADBLOCK_HOST_MAX_PENDING_COMPILATIONS 2

typedef enum {
    XANH_ADBLOCK_HOST_ERROR_UNAVAILABLE,
    XANH_ADBLOCK_HOST_ERROR_INVALID_INPUT,
    XANH_ADBLOCK_HOST_ERROR_BUSY,
    XANH_ADBLOCK_HOST_ERROR_CORE,
    XANH_ADBLOCK_HOST_ERROR_INVALID_OUTPUT
} XanhAdblockHostError;

#define XANH_ADBLOCK_HOST_ERROR (xanh_adblock_host_error_quark ())
GQuark xanh_adblock_host_error_quark (void);

gboolean xanh_adblock_host_is_available (void);

/* Compilation can be expensive for production filter lists, so it always runs
 * outside the main context. Input, output and pending work are bounded before
 * ownership crosses the native ABI. */
void xanh_adblock_host_compile_async (
    const gchar *filter_list,
    GCancellable *cancellable,
    GAsyncReadyCallback callback,
    gpointer user_data);
GBytes *xanh_adblock_host_compile_finish (
    GAsyncResult *result,
    GError **error);

G_END_DECLS

#endif
