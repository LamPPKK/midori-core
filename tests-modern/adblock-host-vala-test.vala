/* SPDX-License-Identifier: LGPL-2.1-or-later */

MainLoop? loop;
bool completed;

async void compile_filter_list () {
    bool available = Xanh.adblock_host_is_available ();
    try {
        Bytes rules = yield Xanh.adblock_host_compile_async ("||ads.example^\n");
        assert (available);
        assert (rules.get_size () > 2);
    } catch (Error error) {
        assert (!available);
        assert (error.domain == Xanh.AdblockHostError.quark ());
        assert (error.code == Xanh.AdblockHostError.UNAVAILABLE);
    }
    completed = true;
    loop.quit ();
}

void test_async_binding () {
    loop = new MainLoop ();
    compile_filter_list.begin ();
    loop.run ();
    assert (completed);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/adblock-host-vala/async-binding", test_async_binding);
    return Test.run ();
}
