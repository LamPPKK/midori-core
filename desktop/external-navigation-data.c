/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "external-navigation-data.h"

#include <json-glib/json-glib.h>
#include <string.h>

#define XANH_EXTERNAL_MESSAGE_LIMIT 16384
#define XANH_EXTERNAL_URI_LIMIT 2048
#define XANH_EXTERNAL_DOCUMENT_LIMIT 8192

static const gchar *
required_string (JsonObject  *object,
                 const gchar *name)
{
    JsonNode *node;

    if (!json_object_has_member (object, name))
        return NULL;
    node = json_object_get_member (object, name);
    if (node == NULL || !JSON_NODE_HOLDS_VALUE (node) ||
        json_node_get_value_type (node) != G_TYPE_STRING)
        return NULL;
    return json_node_get_string (node);
}

gboolean
xanh_external_navigation_parse_message (const gchar *message,
                                        gchar      **external_uri,
                                        gchar      **document_uri)
{
    g_autoptr (JsonParser) parser = NULL;
    JsonNode *root;
    JsonObject *object;
    const gchar *external;
    const gchar *document;

    g_return_val_if_fail (external_uri != NULL, FALSE);
    g_return_val_if_fail (document_uri != NULL, FALSE);
    *external_uri = NULL;
    *document_uri = NULL;
    if (message == NULL || !g_utf8_validate (message, -1, NULL) ||
        strlen (message) > XANH_EXTERNAL_MESSAGE_LIMIT ||
        strstr (message, "\\u0000") != NULL)
        return FALSE;
    parser = json_parser_new ();
    if (!json_parser_load_from_data (parser, message, -1, NULL))
        return FALSE;
    root = json_parser_get_root (parser);
    if (root == NULL || !JSON_NODE_HOLDS_OBJECT (root))
        return FALSE;
    object = json_node_get_object (root);
    if (json_object_get_size (object) != 2)
        return FALSE;
    external = required_string (object, "externalUrl");
    document = required_string (object, "documentUrl");
    if (external == NULL || *external == '\0' ||
        strlen (external) > XANH_EXTERNAL_URI_LIMIT ||
        document == NULL || *document == '\0' ||
        strlen (document) > XANH_EXTERNAL_DOCUMENT_LIMIT)
        return FALSE;
    *external_uri = g_strdup (external);
    *document_uri = g_strdup (document);
    return TRUE;
}
