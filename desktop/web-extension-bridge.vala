/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    [CCode (cname = "webkit_user_content_manager_register_script_message_handler")]
    static extern bool register_default_script_message_handler (
        WebKit.UserContentManager manager, string name, string? world_name);

    public interface ExtensionHost : Object {
        public abstract void create_extension_tab (string uri);
        public abstract string? get_active_extension_uri ();
        public abstract uint64 get_active_extension_tab_id ();
        public abstract bool is_active_extension_tab_private ();
        public abstract async string execute_extension_script (string world, string code) throws Error;
        public abstract void show_extension_notification (string id, string title, string message);
    }

    public class ContentScriptDefinition : Object {
        public string[] matches { get; set; default = {}; }
        public string[] scripts { get; set; default = {}; }
        public string[] styles { get; set; default = {}; }
    }

    public class ExtensionDefinition : Object {
        public string id { get; construct; }
        public string token { get; construct; }
        public string name { get; set; }
        public string version { get; set; default = ""; }
        public string description { get; set; default = ""; }
        public string root { get; construct; }
        public string[] host_permissions { get; set; default = {}; }
        public string[] permissions { get; set; default = {}; }
        public List<ContentScriptDefinition> content_blocks = new List<ContentScriptDefinition> ();
        public string[] background_scripts { get; set; default = {}; }
        public string? background_page { get; set; }
        public string? action_title { get; set; }
        public string? action_popup { get; set; }
        public string? action_icon { get; set; }
        public string? sidebar_title { get; set; }
        public string? sidebar_panel { get; set; }
        public string? sidebar_icon { get; set; }

        public ExtensionDefinition (string id, string root) {
            Object (id: id, token: Uuid.string_random (), name: id, root: root);
        }
    }

    public class WebExtensionBridge : Object {
        const string CHANNEL = "xanh";
        const string WORLD_PREFIX = "io.github.lamppkk.xanhbrowser.extension.";
        const int MAX_MESSAGE_BYTES = 65536;

        ExtensionHost host;
        WebKit.WebView web_view;
        WebKit.UserContentManager content;
        HashTable<string, ExtensionDefinition> extensions =
            new HashTable<string, ExtensionDefinition> (str_hash, str_equal);
        HashTable<string, WebKit.WebView> background_views =
            new HashTable<string, WebKit.WebView> (str_hash, str_equal);
        HashTable<string, string> active_tab_grants =
            new HashTable<string, string> (str_hash, str_equal);

        public signal void action_available (WebExtensionBridge bridge, string extension_id,
            string? action_title, string? action_popup,
            string? sidebar_title, string? sidebar_panel);

        public WebExtensionBridge (ExtensionHost host, WebKit.WebView web_view) {
            this.host = host;
            this.web_view = web_view;
            content = web_view.get_user_content_manager ();
            content.script_message_received.connect ((value) => handle_message (web_view, value));
        }

        public void load_default_locations (bool run_backgrounds = true) {
            load_folder (Path.build_filename (Config.plugin_dir (), "web-extensions"), run_backgrounds);
            load_folder (Path.build_filename (
                Environment.get_user_data_dir (), "xanh-browser", "extensions"), run_backgrounds);
        }

        public void load_folder (string path, bool run_backgrounds = true) {
            var folder = File.new_for_path (path);
            if (!folder.query_exists ()) {
                return;
            }
            try {
                var enumerator = folder.enumerate_children (
                    FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? info;
                while ((info = enumerator.next_file ()) != null) {
                    if (info.get_file_type () != FileType.DIRECTORY) {
                        continue;
                    }
                    load_unpacked (folder.get_child (info.get_name ()).get_path (), run_backgrounds);
                }
            } catch (Error error) {
                warning ("Cannot scan WebExtensions in %s: %s", path, error.message);
            }
        }

        public bool load_unpacked (string root, bool run_backgrounds = true) {
            string manifest_path = Path.build_filename (root, "manifest.json");
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (manifest_path);
                var manifest = parser.get_root ().get_object ();
                if (!manifest.has_member ("manifest_version") ||
                        manifest.get_int_member ("manifest_version") != 2) {
                    warning ("Only Manifest V2 is supported: %s", manifest_path);
                    return false;
                }
                string id = File.new_for_path (root).get_basename ();
                var extension = new ExtensionDefinition (id, root);
                if (manifest.has_member ("name")) {
                    extension.name = manifest.get_string_member ("name");
                }
                if (manifest.has_member ("version")) {
                    extension.version = manifest.get_string_member ("version");
                }
                if (manifest.has_member ("description")) {
                    extension.description = manifest.get_string_member ("description");
                }
                if (manifest.has_member ("permissions")) {
                    var permissions = manifest.get_array_member ("permissions");
                    extension.host_permissions = read_host_patterns (permissions);
                    extension.permissions = read_named_permissions (permissions);
                }
                read_content_scripts (manifest, extension);
                read_background (manifest, extension);
                read_action (manifest, "browser_action", extension, false);
                read_action (manifest, "sidebar_action", extension, true);
                install (extension);
                extensions.insert (id, extension);
                if (run_backgrounds) install_background (extension);
                action_available (this, extension.id, extension.action_title,
                    extension.action_popup, extension.sidebar_title, extension.sidebar_panel);
                return true;
            } catch (Error error) {
                warning ("Cannot load Manifest V2 extension %s: %s", root, error.message);
                return false;
            }
        }

        string[] read_host_patterns (Json.Array permissions) {
            string[] patterns = {};
            foreach (var node in permissions.get_elements ()) {
                if (node.get_node_type () == Json.NodeType.VALUE) {
                    string value = node.get_string ();
                    if (value.contains ("://") || value == "<all_urls>") {
                        patterns += value;
                    }
                }
            }
            return patterns;
        }

        string[] read_named_permissions (Json.Array permissions) {
            string[] names = {};
            foreach (var node in permissions.get_elements ()) {
                if (node.get_node_type () != Json.NodeType.VALUE) continue;
                string value = node.get_string ();
                if (!value.contains ("://") && value != "<all_urls>") names += value;
            }
            return names;
        }

        void read_content_scripts (Json.Object manifest, ExtensionDefinition extension) {
            if (!manifest.has_member ("content_scripts")) {
                return;
            }
            foreach (var node in manifest.get_array_member ("content_scripts").get_elements ()) {
                var block = node.get_object ();
                var definition = new ContentScriptDefinition ();
                string[] matches = {};
                string[] scripts = {};
                string[] styles = {};
                if (block.has_member ("matches")) {
                    foreach (var value in block.get_array_member ("matches").get_elements ()) {
                        matches += value.get_string ();
                    }
                }
                if (block.has_member ("js")) {
                    foreach (var value in block.get_array_member ("js").get_elements ()) {
                        scripts += value.get_string ();
                    }
                }
                if (block.has_member ("css")) {
                    foreach (var value in block.get_array_member ("css").get_elements ()) {
                        styles += value.get_string ();
                    }
                }
                definition.matches = matches;
                definition.scripts = scripts;
                definition.styles = styles;
                extension.content_blocks.append (definition);
            }
        }

        void read_background (Json.Object manifest, ExtensionDefinition extension) {
            if (!manifest.has_member ("background")) {
                return;
            }
            var background = manifest.get_object_member ("background");
            if (background.has_member ("page")) {
                extension.background_page = background.get_string_member ("page");
            }
            if (background.has_member ("scripts")) {
                string[] scripts = extension.background_scripts;
                foreach (var value in background.get_array_member ("scripts").get_elements ()) {
                    scripts += value.get_string ();
                }
                extension.background_scripts = scripts;
            }
        }

        void read_action (Json.Object manifest, string member, ExtensionDefinition extension, bool sidebar) {
            if (!manifest.has_member (member)) {
                return;
            }
            var action = manifest.get_object_member (member);
            if (sidebar) {
                extension.sidebar_title = action.has_member ("default_title") ?
                    action.get_string_member ("default_title") : extension.name;
                extension.sidebar_panel = action.has_member ("default_panel") ?
                    action.get_string_member ("default_panel") : null;
                extension.sidebar_icon = read_icon (action);
            } else {
                extension.action_title = action.has_member ("default_title") ?
                    action.get_string_member ("default_title") : extension.name;
                extension.action_popup = action.has_member ("default_popup") ?
                    action.get_string_member ("default_popup") : null;
                extension.action_icon = read_icon (action);
            }
        }

        string? read_icon (Json.Object action) {
            if (!action.has_member ("default_icon")) return null;
            var node = action.get_member ("default_icon");
            return node.get_node_type () == Json.NodeType.VALUE ? node.get_string () : null;
        }

        void install (ExtensionDefinition extension) throws Error {
            string world = WORLD_PREFIX + extension.id;
            if (!content.register_script_message_handler (CHANNEL, world)) {
                throw new IOError.EXISTS ("Message handler already registered for %s", extension.id);
            }
            string[] api_allow_list = extension.host_permissions;
            foreach (var block in extension.content_blocks) {
                foreach (string pattern in block.matches) api_allow_list += pattern;
            }
            string api = api_source (extension.id, extension.token);
            content.add_script (new WebKit.UserScript.for_world (
                api, WebKit.UserContentInjectedFrames.ALL_FRAMES,
                WebKit.UserScriptInjectionTime.START, world, api_allow_list, null));
            foreach (var block in extension.content_blocks) {
                foreach (string relative in block.scripts) {
                    content.add_script (new WebKit.UserScript.for_world (
                        read_text (extension.root, relative), WebKit.UserContentInjectedFrames.ALL_FRAMES,
                        WebKit.UserScriptInjectionTime.END, world, block.matches, null));
                }
                foreach (string relative in block.styles) {
                    content.add_style_sheet (new WebKit.UserStyleSheet (
                        read_text (extension.root, relative), WebKit.UserContentInjectedFrames.ALL_FRAMES,
                        WebKit.UserStyleLevel.USER, block.matches, null));
                }
            }
        }

        void install_background (ExtensionDefinition extension) throws Error {
            if (extension.background_page == null && extension.background_scripts.length == 0) return;

            var manager = new WebKit.UserContentManager ();
            if (!register_default_script_message_handler (manager, CHANNEL, null)) {
                throw new IOError.EXISTS ("Background message handler already registered for %s", extension.id);
            }
            manager.add_script (new WebKit.UserScript (
                api_source (extension.id, extension.token), WebKit.UserContentInjectedFrames.TOP_FRAME,
                WebKit.UserScriptInjectionTime.START, { "file://*/*" }, null));
            foreach (string relative in extension.background_scripts) {
                manager.add_script (new WebKit.UserScript (
                    read_text (extension.root, relative), WebKit.UserContentInjectedFrames.TOP_FRAME,
                    WebKit.UserScriptInjectionTime.END, { "file://*/*" }, null));
            }
            var background = create_auxiliary_view (manager, extension);
            manager.script_message_received.connect ((value) => handle_message (background, value, true));
            background_views.insert (extension.id, background);
            if (extension.background_page != null) {
                background.load_uri (extension_uri (extension, extension.background_page));
            } else {
                background.load_html ("<html><body></body></html>",
                    File.new_for_path (extension.root).get_uri () + "/");
            }
        }

        public WebKit.WebView create_extension_view (string extension_id, string relative) throws Error {
            var extension = extensions.lookup (extension_id);
            if (extension == null) throw new IOError.NOT_FOUND ("Unknown extension");
            var manager = new WebKit.UserContentManager ();
            if (!register_default_script_message_handler (manager, CHANNEL, null)) {
                throw new IOError.EXISTS ("Extension message handler already registered for %s", extension.id);
            }
            manager.add_script (new WebKit.UserScript (
                api_source (extension.id, extension.token), WebKit.UserContentInjectedFrames.ALL_FRAMES,
                WebKit.UserScriptInjectionTime.START, { "file://*/*" }, null));
            var view = create_auxiliary_view (manager, extension);
            manager.script_message_received.connect ((value) => handle_message (view, value, true));
            view.load_uri (extension_uri (extension, relative));
            return view;
        }

        WebKit.WebView create_auxiliary_view (WebKit.UserContentManager manager,
                ExtensionDefinition extension) {
            var settings = new WebKit.Settings ();
            settings.enable_developer_extras = false;
            settings.user_agent = "%s %s".printf (settings.user_agent, Config.USER_AGENT_TOKEN);
            return Object.new (
                typeof (WebKit.WebView),
                "network-session", web_view.get_network_session (),
                "user-content-manager", manager,
                "settings", settings,
                "default-content-security-policy",
                    "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; " +
                    "script-src 'self'; connect-src " + extension_connect_sources (extension)
            ) as WebKit.WebView;
        }

        string extension_connect_sources (ExtensionDefinition extension) {
            string[] sources = { "'self'" };
            foreach (string pattern in extension.host_permissions) {
                if (pattern == "<all_urls>") {
                    sources += "https:";
                    sources += "http:";
                    continue;
                }
                int separator = pattern.index_of ("://");
                if (separator <= 0) continue;
                string scheme = pattern.substring (0, separator).down ();
                if (scheme != "http" && scheme != "https" && scheme != "*") continue;
                string remainder = pattern.substring (separator + 3);
                int path_start = remainder.index_of ("/");
                string host_pattern = path_start >= 0 ? remainder.substring (0, path_start) : remainder;
                if (!valid_host_pattern (host_pattern)) continue;
                string[] schemes;
                if (scheme == "*") schemes = { "http", "https" };
                else schemes = { scheme };
                foreach (string current_scheme in schemes) {
                    if (host_pattern == "*") sources += current_scheme + ":";
                    else sources += "%s://%s".printf (current_scheme, host_pattern);
                    if (host_pattern.has_prefix ("*.")) {
                        sources += "%s://%s".printf (current_scheme, host_pattern.substring (2));
                    }
                }
            }
            return string.joinv (" ", sources);
        }

        bool valid_host_pattern (string value) {
            if (value == "*") return true;
            string host = value.has_prefix ("*.") ? value.substring (2) : value;
            if (host == "") return false;
            for (int index = 0; index < host.length; index++) {
                char current = host[index];
                if (!(current.isalnum () || current == '.' || current == '-')) return false;
            }
            return true;
        }

        string extension_uri (ExtensionDefinition extension, string relative) throws Error {
            var child = File.new_for_path (extension_resource_path (extension, relative));
            if (!child.query_exists ()) throw new IOError.NOT_FOUND ("Missing extension resource: %s", relative);
            return child.get_uri ();
        }

        string extension_resource_path (ExtensionDefinition extension, string relative) throws Error {
            return checked_resource_path (extension.root, relative);
        }

        string checked_resource_path (string root, string relative) throws Error {
            string canonical_root = Filename.canonicalize (root);
            string canonical_child = Filename.canonicalize (relative, canonical_root);
            if (!is_path_within_root (canonical_root, canonical_child)) {
                throw new IOError.PERMISSION_DENIED ("Extension path escapes its root");
            }
            var current = File.new_for_path (canonical_root);
            string child_relative = canonical_child.substring (canonical_root.length + 1);
            foreach (string component in child_relative.split (Path.DIR_SEPARATOR_S)) {
                if (component == "") continue;
                current = current.get_child (component);
                var info = current.query_info (FileAttribute.STANDARD_TYPE,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                if (info.get_file_type () == FileType.SYMBOLIC_LINK) {
                    throw new IOError.PERMISSION_DENIED ("Extension resources cannot use symbolic links");
                }
            }
            return canonical_child;
        }

        public string? get_extension_icon (string extension_id, bool sidebar) throws Error {
            var extension = extensions.lookup (extension_id);
            if (extension == null) throw new IOError.NOT_FOUND ("Unknown extension");
            string? relative = sidebar ? extension.sidebar_icon : extension.action_icon;
            if (relative == null) return null;
            string path = extension_resource_path (extension, relative);
            if (!File.new_for_path (path).query_exists ()) return null;
            return path;
        }

        public void grant_active_tab (string extension_id, uint64 tab_id, string? uri) {
            var extension = extensions.lookup (extension_id);
            if (extension == null || !has_permission (extension, "activeTab") ||
                    tab_id == 0 || !BrowserDatabase.is_web_uri (uri)) return;
            string? origin = uri_origin (uri);
            if (origin != null) active_tab_grants.insert (
                extension_id, "%s:%s".printf (tab_id.to_string (), origin));
        }

        string read_text (string root, string relative) throws Error {
            var child = File.new_for_path (checked_resource_path (root, relative));
            uint8[] bytes;
            string? etag;
            child.load_contents (null, out bytes, out etag);
            return (string) bytes;
        }

        void handle_message (WebKit.WebView source, JSC.Value value, bool default_world = false) {
            string json = value.to_json (0);
            if (json.length > MAX_MESSAGE_BYTES) {
                warning ("Rejected oversized WebExtension message");
                return;
            }
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (json);
                var message = parser.get_root ().get_object ();
                if (!message.has_member ("extensionId") || !message.has_member ("token") ||
                        !message.has_member ("fn") ||
                        !message.has_member ("promise")) {
                    throw new IOError.INVALID_ARGUMENT ("Missing required message fields");
                }
                string id = message.get_string_member ("extensionId");
                string function = message.get_string_member ("fn");
                int64 promise = message.get_int_member ("promise");
                var extension = extensions.lookup (id);
                if (extension == null || message.get_string_member ("token") != extension.token) {
                    throw new IOError.PERMISSION_DENIED ("Unknown extension");
                }
                var args = message.has_member ("args") ? message.get_object_member ("args") : new Json.Object ();
                try {
                    dispatch (source, extension, function, args, promise,
                        default_world ? null : WORLD_PREFIX + extension.id);
                } catch (Error error) {
                    reject (source, default_world ? null : WORLD_PREFIX + extension.id,
                        promise, error.message);
                }
            } catch (Error error) {
                warning ("Rejected WebExtension message: %s", error.message);
            }
        }

        void dispatch (WebKit.WebView source, ExtensionDefinition extension, string function,
                Json.Object args, int64 promise, string? response_world)
                throws Error {
            string script_world = WORLD_PREFIX + extension.id;
            switch (function) {
            case "tabs.create":
                string uri = args.has_member ("url") ? args.get_string_member ("url") : "about:blank";
                if (uri != "about:blank" && !BrowserDatabase.is_web_uri (uri)) {
                    throw new IOError.PERMISSION_DENIED ("tabs.create only accepts HTTP(S)");
                }
                host.create_extension_tab (uri);
                resolve (source, response_world, promise, "true");
                break;
            case "tabs.executeScript":
                if (host.is_active_extension_tab_private ()) {
                    throw new IOError.PERMISSION_DENIED ("Extensions are disabled in private tabs");
                }
                string? active_uri = host.get_active_extension_uri ();
                uint64 active_tab_id = host.get_active_extension_tab_id ();
                bool used_active_grant = has_active_tab_grant (extension, active_tab_id, active_uri);
                if (!is_host_allowed (active_uri, extension.host_permissions) && !used_active_grant) {
                    throw new IOError.PERMISSION_DENIED ("Host permission denied");
                }
                if (used_active_grant) active_tab_grants.remove (extension.id);
                string code = args.has_member ("code") ? args.get_string_member ("code") : "";
                host.execute_extension_script.begin (script_world, code, (object, result) => {
                    try { resolve (source, response_world, promise, host.execute_extension_script.end (result)); }
                    catch (Error error) { reject (source, response_world, promise, error.message); }
                });
                break;
            case "notifications.create":
                if (!has_permission (extension, "notifications")) {
                    throw new IOError.PERMISSION_DENIED ("notifications permission denied");
                }
                host.show_extension_notification (
                    extension.id,
                    args.has_member ("title") ? args.get_string_member ("title") : extension.name,
                    args.has_member ("message") ? args.get_string_member ("message") : "");
                resolve (source, response_world, promise, "true");
                break;
            default:
                throw new IOError.NOT_SUPPORTED ("Unsupported Manifest V2 API: %s", function);
            }
        }

        void resolve (WebKit.WebView source, string? world, int64 promise, string json) {
            string script = "globalThis.__xanhResolve(%s, %s);".printf (
                promise.to_string (), json);
            source.evaluate_javascript.begin (script, -1, world, null, null);
        }

        void reject (WebKit.WebView source, string? world, int64 promise, string message) {
            var generator = new Json.Generator ();
            var node = new Json.Node (Json.NodeType.VALUE);
            node.set_string (message);
            generator.set_root (node);
            string script = "globalThis.__xanhReject(%s, %s);".printf (
                promise.to_string (), generator.to_data (null));
            source.evaluate_javascript.begin (script, -1, world, null, null);
        }

        string api_source (string id, string token) {
            return """
                (() => {
                  const pending = new Map(); let next = 1;
                  globalThis.__xanhResolve = (id, value) => { const p=pending.get(id); if(p){p.resolve(value);pending.delete(id);} };
                  globalThis.__xanhReject = (id, value) => { const p=pending.get(id); if(p){p.reject(new Error(value));pending.delete(id);} };
                  const call = (fn, args={}) => new Promise((resolve,reject) => {
                    const promise=next++; pending.set(promise,{resolve,reject});
                    window.webkit.messageHandlers.xanh.postMessage({extensionId:%s,token:%s,fn,args,promise});
                  });
                  globalThis.browser = Object.freeze({
                    tabs: Object.freeze({create: args => call('tabs.create',args), executeScript: args => call('tabs.executeScript',args)}),
                    notifications: Object.freeze({create: args => call('notifications.create',args)})
                  });
                  globalThis.chrome = globalThis.browser;
                })();
            """.printf (json_string (id), json_string (token));
        }

        string json_string (string value) {
            var generator = new Json.Generator ();
            var node = new Json.Node (Json.NodeType.VALUE);
            node.set_string (value);
            generator.set_root (node);
            return generator.to_data (null);
        }

        public static bool is_host_allowed (string? uri, string[] patterns) {
            if (!BrowserDatabase.is_web_uri (uri)) {
                return false;
            }
            Uri parsed;
            try {
                parsed = Uri.parse (uri, UriFlags.NONE);
            } catch (UriError error) {
                return false;
            }
            foreach (string pattern in patterns) {
                if (pattern == "<all_urls>") {
                    return true;
                }
                int separator = pattern.index_of ("://");
                if (separator <= 0) continue;
                string scheme = pattern.substring (0, separator);
                string remainder = pattern.substring (separator + 3);
                int path_start = remainder.index_of ("/");
                if (path_start < 0) continue;
                string host_pattern = remainder.substring (0, path_start).down ();
                string path_pattern = remainder.substring (path_start);
                string actual_scheme = parsed.get_scheme ().down ();
                string actual_host = parsed.get_host ().down ();
                string actual_path = parsed.get_path () ?? "/";
                bool scheme_allowed = scheme == actual_scheme ||
                    (scheme == "*" && (actual_scheme == "http" || actual_scheme == "https"));
                bool host_allowed = host_pattern == "*" || host_pattern == actual_host;
                if (host_pattern.has_prefix ("*.")) {
                    string base_host = host_pattern.substring (2);
                    host_allowed = actual_host == base_host || actual_host.has_suffix ("." + base_host);
                }
                if (scheme_allowed && host_allowed && new PatternSpec (path_pattern).match_string (actual_path)) {
                    return true;
                }
            }
            return false;
        }

        public static bool is_path_within_root (string root, string candidate) {
            string canonical_root = Filename.canonicalize (root);
            string canonical_candidate = Filename.canonicalize (candidate);
            return canonical_candidate.has_prefix (canonical_root + Path.DIR_SEPARATOR_S);
        }

        bool has_active_tab_grant (ExtensionDefinition extension, uint64 tab_id, string? uri) {
            string? granted = active_tab_grants.lookup (extension.id);
            string? current = uri_origin (uri);
            return granted != null && current != null &&
                granted == "%s:%s".printf (tab_id.to_string (), current);
        }

        static bool has_permission (ExtensionDefinition extension, string permission) {
            foreach (string current in extension.permissions) {
                if (current == permission) return true;
            }
            return false;
        }

        static string? uri_origin (string? uri) {
            if (!BrowserDatabase.is_web_uri (uri)) return null;
            try {
                var parsed = Uri.parse (uri, UriFlags.NONE);
                int port = parsed.get_port ();
                if ((parsed.get_scheme () == "https" && port == 443) ||
                        (parsed.get_scheme () == "http" && port == 80)) port = -1;
                return "%s://%s%s".printf (parsed.get_scheme ().down (), parsed.get_host ().down (),
                    port >= 0 ? ":" + port.to_string () : "");
            } catch (UriError error) {
                return null;
            }
        }
    }
}
