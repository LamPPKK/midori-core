/* SPDX-License-Identifier: LGPL-2.1-or-later */
namespace Xanh {
    [CCode (cname = "XanhCredentialBridge",
        type_id = "xanh_credential_bridge_get_type ()",
        cheader_filename = "credential-bridge.h")]
    public class CredentialBridge : GLib.Object {
        [CCode (cname = "xanh_credential_bridge_new")]
        public CredentialBridge (
            WebKit.UserContentManager manager,
            WebKit.WebView web_view) throws GLib.Error;
        public signal void request (
            string request_id,
            string navigation_nonce,
            string document_url,
            string origin);
        public bool request_is_current (
            string request_id,
            string navigation_nonce,
            string document_url,
            string origin);
        public void cancel_request (string request_id);
        public async bool fill_async (
            string request_id,
            string navigation_nonce,
            string document_url,
            string origin,
            string username,
            string password,
            GLib.Cancellable? cancellable = null) throws GLib.Error;
    }
}
