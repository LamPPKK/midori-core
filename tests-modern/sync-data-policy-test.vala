/* SPDX-License-Identifier: LGPL-2.1-or-later */

void test_sync_uri_policy () {
    assert (Xanh.SyncDataCoordinator.is_sync_web_uri ("https://example.com/path"));
    assert (!Xanh.SyncDataCoordinator.is_sync_web_uri ("http://user@example.com/path"));
    assert (!Xanh.SyncDataCoordinator.is_sync_web_uri ("https://foo_bar.example/"));
    assert (!Xanh.SyncDataCoordinator.is_sync_web_uri ("https://example.com:70000/"));
    assert (!Xanh.SyncDataCoordinator.is_sync_web_uri (
        "https://example.com/%0d%0aheader"));
    assert (!Xanh.SyncDataCoordinator.is_sync_web_uri (
        "https://example.com/%5cevil"));
    assert (!Xanh.SyncDataCoordinator.is_sync_web_uri ("https://example.com/line\nfeed"));
    assert (!Xanh.SyncDataCoordinator.is_sync_web_uri (
        "https://example.com/" + string.nfill (8200, 'a')));
}

void test_sync_title_policy () {
    string title = Xanh.SyncDataCoordinator.sanitized_sync_title (
        "before\nafter" + string.nfill (5000, 'a'));
    assert (!title.contains ("\n"));
    assert (title.length == 4096);
    string unicode = Xanh.SyncDataCoordinator.sanitized_sync_title (
        string.nfill (2000, 'a') + "🙂" + string.nfill (3000, 'b'));
    assert (unicode.validate ());
    assert (unicode.length <= 4096);
}

void test_sync_guid_policy () {
    assert (Xanh.SyncDataCoordinator.is_sync_guid ("AbCdEf123_-x"));
    assert (!Xanh.SyncDataCoordinator.is_sync_guid ("short"));
    assert (!Xanh.SyncDataCoordinator.is_sync_guid ("AbCdEf123+/x"));
    assert (!Xanh.SyncDataCoordinator.is_sync_guid ("AbCdEf123_\nx"));
}

void test_bookmark_title_update_contract () {
    try {
        string json = Xanh.SyncDataCoordinator.bookmark_title_update_json (
            "AbCdEf123_-x", "before\nafter");
        var parser = new Json.Parser ();
        parser.load_from_data (json);
        Json.Object update = parser.get_root ().get_object ();
        assert (update.get_string_member ("guid") == "AbCdEf123_-x");
        assert (update.get_string_member ("title") == "before after");
        assert (update.get_member ("url").get_node_type () == Json.NodeType.NULL);
        assert (update.get_member ("parent_guid").get_node_type () == Json.NodeType.NULL);
        assert (update.get_member ("position").get_node_type () == Json.NodeType.NULL);
        assert (!update.get_boolean_member ("is_private"));
    } catch (Error error) {
        Test.fail_printf ("Bookmark update JSON error: %s", error.message);
    }

    bool invalid_rejected = false;
    try {
        Xanh.SyncDataCoordinator.bookmark_title_update_json ("invalid", "Title");
    } catch (Xanh.SyncDataError error) {
        invalid_rejected = true;
    }
    assert (invalid_rejected);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/sync-data/uri-policy", test_sync_uri_policy);
    Test.add_func ("/sync-data/title-policy", test_sync_title_policy);
    Test.add_func ("/sync-data/guid-policy", test_sync_guid_policy);
    Test.add_func ("/sync-data/bookmark-title-update",
        test_bookmark_title_update_contract);
    return Test.run ();
}
