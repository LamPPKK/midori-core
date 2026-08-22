/* SPDX-License-Identifier: LGPL-2.1-or-later */

const int64 NOW = 5000000;

class PopupInput : Object {
    public string? source = "https://source.example/page";
    public string? target = "https://target.example/page";
    public bool user_gesture = true;
    public bool redirect;
    public bool link_clicked = true;
    public uint mouse_button = 1;
    public bool window_active = true;
    public bool source_selected = true;
    public bool source_process_stopped;
    public bool clearing_data;
    public uint tab_count = 1;
    public int64 last_accepted;
    public int64 now = NOW;

    public bool allowed () {
        return Xanh.PopupPolicy.can_create (
            source, target, user_gesture, redirect, link_clicked, mouse_button,
            window_active, source_selected, source_process_stopped, clearing_data,
            tab_count, last_accepted, now);
    }
}

void test_direct_pointer_link () {
    assert (new PopupInput ().allowed ());
    var input = new PopupInput ();
    input.source = "http://source.example/page";
    assert (input.allowed ());
    input = new PopupInput ();
    input.target = "about:blank";
    input.mouse_button = 2;
    assert (input.allowed ());
    input = new PopupInput ();
    input.user_gesture = false;
    assert (!input.allowed ());
    input = new PopupInput ();
    input.redirect = true;
    assert (!input.allowed ());
    input = new PopupInput ();
    input.link_clicked = false;
    assert (!input.allowed ());
    input = new PopupInput ();
    input.mouse_button = 0;
    assert (!input.allowed ());
    input.mouse_button = 3;
    assert (!input.allowed ());
}

void test_uri_and_context () {
    var input = new PopupInput ();
    input.source = "http://user:secret@source.example/";
    assert (!input.allowed ());
    input = new PopupInput ();
    input.source = "about:blank";
    assert (!input.allowed ());
    input = new PopupInput ();
    input.target = "javascript:alert(1)";
    assert (!input.allowed ());
    input = new PopupInput ();
    input.target = "https://user:secret@target.example/";
    assert (!input.allowed ());
    input = new PopupInput ();
    input.target = "https://target.example/%0d%0aheader";
    assert (!input.allowed ());
    input = new PopupInput ();
    input.window_active = false;
    assert (!input.allowed ());
    input = new PopupInput ();
    input.source_selected = false;
    assert (!input.allowed ());
    input = new PopupInput ();
    input.source_process_stopped = true;
    assert (!input.allowed ());
    input = new PopupInput ();
    input.clearing_data = true;
    assert (!input.allowed ());
}

void test_budget () {
    var input = new PopupInput ();
    input.tab_count = Xanh.PopupPolicy.MAX_TABS;
    assert (!input.allowed ());
    input.tab_count--;
    assert (input.allowed ());
    input = new PopupInput ();
    input.last_accepted = NOW - Xanh.PopupPolicy.COOLDOWN_MICROSECONDS + 1;
    assert (!input.allowed ());
    input.last_accepted--;
    assert (input.allowed ());
    input.last_accepted = NOW;
    assert (!input.allowed ());
    input.last_accepted = NOW + 1;
    assert (!input.allowed ());
    input = new PopupInput ();
    input.now = 0;
    assert (!input.allowed ());
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/popup-policy/direct-pointer-link", test_direct_pointer_link);
    Test.add_func ("/popup-policy/uri-and-context", test_uri_and_context);
    Test.add_func ("/popup-policy/budget", test_budget);
    return Test.run ();
}
