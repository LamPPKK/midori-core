/* SPDX-License-Identifier: LGPL-2.1-or-later */
[CCode (cheader_filename = "external-navigation-bridge.h")]
namespace Xanh {
    [CCode (cname = "XanhExternalNavigationBridge",
        type_id = "xanh_external_navigation_bridge_get_type ()")]
    public class ExternalNavigationBridge : GLib.Object {
        [CCode (cname = "xanh_external_navigation_bridge_new")]
        public ExternalNavigationBridge (
            WebKit.UserContentManager manager) throws GLib.Error;
        public signal void request (string external_uri, string document_uri);
    }
}
