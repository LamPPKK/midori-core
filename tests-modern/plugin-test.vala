/* SPDX-License-Identifier: LGPL-2.1-or-later */

void test_native_plugin_lifecycle () {
    try {
        string root = DirUtils.make_tmp ("xanh-plugin-test-XXXXXX");
        var database = new Xanh.BrowserDatabase (Path.build_filename (root, "browser.db"));
        database.set_setting ("adblock-filter-list", "||configured.example^\n");
        var host = new Xanh.PluginHost (database);
        string? plugin_dir = Environment.get_variable ("XANH_TEST_PLUGIN_DIR");
        assert_nonnull (plugin_dir);
        var manager = new Xanh.PluginManager (host, plugin_dir);

        assert (host.adblock_enabled);
        assert (host.adblock_filter_list == "||configured.example^\n");
        assert (host.adblock_blocked_domains.contains ("doubleclick.net"));
        assert (host.bookmarks_enabled);
        assert (host.session_enabled);
        assert (host.colorful_tabs_enabled);
        assert (host.status_clock_enabled);
        assert (host.status_features_enabled);

        var tab = new Xanh.TabState ();
        tab.id = 1;
        tab.uri = "https://example.com/page";
        tab.title = "Example";
        host.bookmark_requested (tab);
        assert (database.list_bookmarks ().length () == 1);

        host.page_loaded (tab);
        assert_nonnull (tab.tint);
        assert (tab.tint.has_prefix ("#"));
        host.progress_changed (tab);

        manager.shutdown ();
        assert (!host.adblock_enabled);
        assert (!host.bookmarks_enabled);
        assert (!host.session_enabled);
        assert (!host.colorful_tabs_enabled);
        assert (!host.status_clock_enabled);
        assert (!host.status_features_enabled);
    } catch (Error error) {
        Test.fail_printf ("Plugin error: %s", error.message);
    }
}

void test_adblock_plugin_honors_persisted_disabled_state () {
    try {
        string root = DirUtils.make_tmp ("xanh-plugin-adblock-disabled-XXXXXX");
        var database = new Xanh.BrowserDatabase (Path.build_filename (root, "browser.db"));
        database.set_setting ("adblock-enabled", "false");
        var host = new Xanh.PluginHost (database);
        string? plugin_dir = Environment.get_variable ("XANH_TEST_PLUGIN_DIR");
        assert_nonnull (plugin_dir);
        var manager = new Xanh.PluginManager (host, plugin_dir);

        assert (!host.adblock_enabled);
        assert (host.adblock_filter_list.contains ("||connect.facebook.net^$third-party"));
        assert (!host.adblock_blocked_domains.contains ("facebook.net"));
        assert (host.adblock_blocked_domains.contains ("scorecardresearch.com"));

        manager.shutdown ();
    } catch (Error error) {
        Test.fail_printf ("Adblock plugin error: %s", error.message);
    }
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/plugins/native-lifecycle", test_native_plugin_lifecycle);
    Test.add_func (
        "/plugins/adblock-persisted-disabled",
        test_adblock_plugin_honors_persisted_disabled_state);
    return Test.run ();
}
