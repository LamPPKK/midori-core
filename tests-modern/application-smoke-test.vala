/* SPDX-License-Identifier: LGPL-2.1-or-later */

int main (string[] args) {
    try {
        string root = DirUtils.make_tmp ("xanh-application-test-XXXXXX");
        Environment.set_variable ("XDG_DATA_HOME", Path.build_filename (root, "data"), true);
        Environment.set_variable ("XDG_CACHE_HOME", Path.build_filename (root, "cache"), true);
        Environment.set_variable ("XDG_CONFIG_HOME", Path.build_filename (root, "config"), true);
        var application = new Xanh.BrowserApplication ();
        Timeout.add_seconds (3, () => {
            application.quit ();
            return Source.REMOVE;
        });
        return application.run (args);
    } catch (Error error) {
        critical ("Application smoke test failed: %s", error.message);
        return 1;
    }
}
