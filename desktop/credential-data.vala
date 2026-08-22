/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    class SyncCredentialRecord : Object {
        public string id;
        public string origin;
        public string username;
        public string password;

        public SyncCredentialRecord (
                string id, string origin, string username, string password) {
            this.id = id;
            this.origin = origin;
            this.username = username;
            this.password = password;
        }
    }

    class CredentialDataPolicy : Object {
        public static List<SyncCredentialRecord> parse (
                string value, string expected_origin) throws Error {
            if (value.length > 4 * 1024 * 1024) {
                throw new IOError.INVALID_DATA (
                    "Firefox Sync returned too much credential data");
            }
            var parser = new Json.Parser ();
            parser.load_from_data (value);
            Json.Node? root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.ARRAY) {
                throw new IOError.INVALID_DATA (
                    "Firefox Sync returned an invalid credential list");
            }
            Json.Array array = root.get_array ();
            if (array.get_length () > 100) {
                throw new IOError.INVALID_DATA (
                    "Firefox Sync returned too many credentials");
            }
            var records = new List<SyncCredentialRecord> ();
            for (uint index = 0; index < array.get_length (); index++) {
                Json.Node node = array.get_element (index);
                if (node.get_node_type () != Json.NodeType.OBJECT) {
                    throw new IOError.INVALID_DATA (
                        "Firefox Sync returned an invalid credential record");
                }
                Json.Object object = node.get_object ();
                if (object.get_size () != 11) {
                    throw new IOError.INVALID_DATA (
                        "Firefox Sync returned an unexpected credential record");
                }
                string id = required_string (object, "id");
                string origin = required_string (object, "origin");
                string action = required_string (object, "form_action_origin");
                string username = required_string (object, "username");
                string password = required_string (object, "password");
                string username_field = required_string (object, "username_field");
                string password_field = required_string (object, "password_field");
                if (!valid_id (id) || origin != expected_origin ||
                        action != expected_origin || username.length > 1024 ||
                        password.length == 0 || password.length > 4096 ||
                        username_field.length > 256 || password_field.length > 256 ||
                        object.get_int_member_with_default (
                            "time_created_epoch_millis", -1) < 0 ||
                        object.get_int_member_with_default (
                            "time_password_changed_epoch_millis", -1) < 0 ||
                        object.get_int_member_with_default (
                            "time_last_used_epoch_millis", -1) < 0 ||
                        object.get_int_member_with_default ("times_used", -1) < 0) {
                    throw new IOError.INVALID_DATA (
                        "Firefox Sync returned an unsafe credential record");
                }
                records.append (new SyncCredentialRecord (
                    id, origin, username, password));
            }
            return (owned) records;
        }

        static string required_string (
                Json.Object object, string member) throws IOError {
            if (!object.has_member (member)) {
                throw new IOError.INVALID_DATA (
                    "Firefox Sync credential record is incomplete");
            }
            Json.Node? node = object.get_member (member);
            if (node == null || node.get_value_type () != typeof (string)) {
                throw new IOError.INVALID_DATA (
                    "Firefox Sync credential record contains an invalid string");
            }
            return node.get_string ();
        }

        static bool valid_id (string value) {
            if (value.length == 0 || value.length > 128) return false;
            for (int index = 0; index < value.length; index++) {
                char current = value[index];
                if (!((current >= 'a' && current <= 'z') ||
                        (current >= 'A' && current <= 'Z') ||
                        (current >= '0' && current <= '9') ||
                        current == '-' || current == '_')) return false;
            }
            return true;
        }
    }
}
