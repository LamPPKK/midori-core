/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    public class DownloadPolicy : Object {
        public const int MAX_SUGGESTED_NAME_BYTES = 240;
        public const int MAX_SUGGESTED_NAME_CHARACTERS = 180;
        public const int MAX_DESTINATION_BYTES = 4096;
        const string FALLBACK_NAME = "download";

        public static string sanitize_suggested_filename (string? value) {
            if (value == null || value == "" || !value.validate ()) return FALLBACK_NAME;
            var builder = new StringBuilder.sized (
                int.min (value.length, MAX_SUGGESTED_NAME_BYTES));
            int index = 0;
            int characters = 0;
            bool pending_space = false;
            unichar character;
            while (value.get_next_char (ref index, out character)) {
                if (!character.isprint () || character.isspace ()) {
                    pending_space = builder.len > 0;
                    continue;
                }
                if (pending_space) {
                    if (!append_character (builder, ' ', ref characters)) break;
                    pending_space = false;
                }
                if (character == '/' || character == '\\') character = '_';
                if (!append_character (builder, character, ref characters)) break;
            }
            string result = builder.str.strip ();
            while (result.has_prefix (".")) result = result.substring (1).strip ();
            while (result.has_suffix ("."))
                result = result.substring (0, result.length - 1).strip ();
            return result == "" ? FALLBACK_NAME : result;
        }

        public static string? local_destination_path (File? file) {
            if (file == null) return null;
            string? path = file.get_path ();
            if (path == null || path.length == 0 ||
                    path.length > MAX_DESTINATION_BYTES || !path.validate () ||
                    !Path.is_absolute (path)) {
                return null;
            }
            int index = 0;
            unichar character;
            while (path.get_next_char (ref index, out character)) {
                if (!character.isprint ()) return null;
            }
            return path;
        }

        public static bool should_record_finished (bool failure_was_seen) {
            return !failure_was_seen;
        }

        static bool append_character (StringBuilder builder,
                unichar character,
                ref int characters) {
            string encoded = character.to_string ();
            if (characters >= MAX_SUGGESTED_NAME_CHARACTERS ||
                    builder.len + encoded.length > MAX_SUGGESTED_NAME_BYTES) {
                return false;
            }
            builder.append (encoded);
            characters++;
            return true;
        }
    }
}
