/* SPDX-License-Identifier: LGPL-2.1-or-later */

[CCode (cname = "xanh_sync_link_check")]
extern bool xanh_sync_link_check ();

int main (string[] args) {
    Environment.set_prgname (Xanh.Config.APP_ID);
    Environment.set_application_name (Xanh.Config.APP_NAME);
    if (!xanh_sync_link_check ()) {
        critical ("Cannot start Xanh Browser: incompatible Firefox Sync native core");
        return 78;
    }
    return new Xanh.BrowserApplication ().run (args);
}
