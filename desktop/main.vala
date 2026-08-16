/* SPDX-License-Identifier: LGPL-2.1-or-later */

int main (string[] args) {
    Environment.set_prgname (Xanh.Config.APP_ID);
    Environment.set_application_name (Xanh.Config.APP_NAME);
    return new Xanh.BrowserApplication ().run (args);
}
