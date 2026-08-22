/* SPDX-License-Identifier: LGPL-2.1-or-later */

void test_foreground_one_shot () {
    var policy = new Xanh.WebProcessRecoveryPolicy ();
    policy.record_committed_uri ("https://example.com/page");
    policy.record_termination ();
    assert (policy.process_stopped);
    assert (policy.take_automatic_recovery (false) == null);
    assert (policy.take_automatic_recovery (true) == "https://example.com/page");
    assert (policy.automatic_recovery_running);
    assert (!policy.finish_automatic_recovery (true));
    assert (policy.automatic_recovery_running);
    policy.record_committed_uri ("https://example.com/redirected");
    assert (policy.finish_automatic_recovery (true));
    assert (!policy.process_stopped);
    assert (policy.recovery_uri == null);

    policy.record_termination ();
    assert (policy.process_stopped);
    assert (policy.recovery_uri == "https://example.com/redirected");
    assert (policy.take_automatic_recovery (true) == null);
}

void test_explicit_navigation_resets_budget () {
    var policy = new Xanh.WebProcessRecoveryPolicy ();
    policy.record_committed_uri ("https://example.com/one");
    policy.record_termination ();
    assert (policy.take_automatic_recovery (true) != null);
    assert (policy.finish_automatic_recovery (false));

    policy.reset_for_explicit_navigation ();
    policy.record_committed_uri ("https://example.com/two");
    policy.record_termination ();
    assert (policy.take_automatic_recovery (true) == "https://example.com/two");
}

void test_unsafe_or_cancelled_recovery_fails_closed () {
    var policy = new Xanh.WebProcessRecoveryPolicy ();
    policy.record_termination ();
    assert (policy.take_automatic_recovery (true) == null);

    policy.record_committed_uri ("https://user:secret@example.com/");
    policy.record_termination ();
    assert (policy.take_automatic_recovery (true) == null);

    policy.reset_for_explicit_navigation ();
    policy.record_committed_uri ("https://example.com/");
    policy.record_termination ();
    assert (policy.take_automatic_recovery (true) != null);
    assert (policy.cancel_automatic_recovery ());
    assert (!policy.automatic_recovery_running);
    assert (policy.process_stopped);
    assert (policy.recovery_uri == "https://example.com/");
    assert (policy.take_automatic_recovery (true) == null);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/web-process-recovery/foreground-one-shot", test_foreground_one_shot);
    Test.add_func ("/web-process-recovery/explicit-reset", test_explicit_navigation_resets_budget);
    Test.add_func ("/web-process-recovery/fail-closed", test_unsafe_or_cancelled_recovery_fails_closed);
    return Test.run ();
}
