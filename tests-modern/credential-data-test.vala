/* SPDX-License-Identifier: LGPL-2.1-or-later */

const string ORIGIN = "https://example.org";

string credential_json () {
    return "[{" +
        "\"id\":\"credential_1\"," +
        "\"origin\":\"https://example.org\"," +
        "\"form_action_origin\":\"https://example.org\"," +
        "\"username_field\":\"email\"," +
        "\"password_field\":\"password\"," +
        "\"username\":\"person@example.org\"," +
        "\"password\":\"secret\"," +
        "\"time_created_epoch_millis\":1," +
        "\"time_password_changed_epoch_millis\":2," +
        "\"time_last_used_epoch_millis\":3," +
        "\"times_used\":4}]";
}

void valid_record_is_accepted () {
    try {
        var records = Xanh.CredentialDataPolicy.parse (credential_json (), ORIGIN);
        assert (records.length () == 1);
        var record = records.nth_data (0);
        assert (record.id == "credential_1");
        assert (record.origin == ORIGIN);
        assert (record.username == "person@example.org");
        assert (record.password == "secret");
    } catch (Error error) {
        critical ("Valid credential was rejected: %s", error.message);
        assert_not_reached ();
    }
}

void unsafe_records_fail_closed () {
    string valid = credential_json ();
    string[] rejected = {
        valid.replace ("credential_1", "credential/1"),
        valid.replace ("https://example.org", "https://other.example"),
        valid.replace ("\"times_used\":4", "\"times_used\":-1"),
        valid.replace ("\"times_used\":4", "\"times_used\":4,\"unexpected\":true"),
        "{}"
    };
    foreach (string value in rejected) {
        try {
            Xanh.CredentialDataPolicy.parse (value, ORIGIN);
            critical ("Unsafe credential payload was accepted");
            assert_not_reached ();
        } catch (Error expected) {
            assert (expected is IOError.INVALID_DATA || expected is Json.ParserError);
        }
    }
}

void result_count_is_bounded () {
    var builder = new StringBuilder ("[");
    string record = credential_json ().substring (1, credential_json ().length - 2);
    for (int index = 0; index < 101; index++) {
        if (index > 0) builder.append_c (',');
        builder.append (record);
    }
    builder.append_c (']');
    try {
        Xanh.CredentialDataPolicy.parse (builder.str, ORIGIN);
        assert_not_reached ();
    } catch (Error error) {
        assert (error is IOError.INVALID_DATA);
    }
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/credential-data/valid", valid_record_is_accepted);
    Test.add_func ("/credential-data/fail-closed", unsafe_records_fail_closed);
    Test.add_func ("/credential-data/result-bound", result_count_is_bounded);
    return Test.run ();
}
