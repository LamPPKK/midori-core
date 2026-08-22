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

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/sync-data/uri-policy", test_sync_uri_policy);
    Test.add_func ("/sync-data/title-policy", test_sync_title_policy);
    Test.add_func ("/sync-data/guid-policy", test_sync_guid_policy);
    return Test.run ();
}
