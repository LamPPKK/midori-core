/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    class TabRecord : Object {
        public TabState state { get; construct; }
        public WebKit.WebView view { get; construct; }
        public Gtk.Label label { get; construct; }
        public WebExtensionBridge bridge { get; construct; }

        public TabRecord (TabState state, WebKit.WebView view, Gtk.Label label,
                WebExtensionBridge bridge) {
            Object (state: state, view: view, label: label, bridge: bridge);
        }
    }

    public class BrowserWindow : Gtk.ApplicationWindow, ExtensionHost {
        const string HOME = "https://duckduckgo.com/";
        BrowserDatabase database;
        PluginHost plugin_host;
        PluginManager plugins;
        WebKit.NetworkSession network_session;
        Gtk.Notebook notebook;
        Gtk.Entry address;
        Gtk.ProgressBar progress;
        Gtk.Label status;
        Gtk.Button back;
        Gtk.Button forward;
        Gtk.Button reload;
        Gtk.Box browser_area;
        Gtk.Box extension_buttons;
        Gtk.Box sidebar;
        Gtk.Label sidebar_title;
        Gtk.Box sidebar_content;
        HashTable<uint64?, TabRecord> tabs = new HashTable<uint64?, TabRecord> (direct_hash, direct_equal);
        HashTable<string, bool> registered_extension_actions =
            new HashTable<string, bool> (str_hash, str_equal);
        bool extension_services_started;
        uint64 next_tab_id = 1;
        uint session_save_source;

        public BrowserWindow (Gtk.Application application, BrowserDatabase database) {
            Object (application: application, title: Config.APP_NAME, default_width: 1100, default_height: 760);
            this.database = database;
            plugin_host = new PluginHost (database);

            string data_dir = Path.build_filename (Environment.get_user_data_dir (), "xanh-browser", "webkit");
            string cache_dir = Path.build_filename (Environment.get_user_cache_dir (), "xanh-browser", "webkit");
            network_session = new WebKit.NetworkSession (data_dir, cache_dir);
            network_session.set_itp_enabled (true);
            network_session.set_persistent_credential_storage_enabled (true);
            network_session.get_cookie_manager ().set_accept_policy (
                setting_enabled ("first-party-cookies-only", true) ?
                    WebKit.CookieAcceptPolicy.NO_THIRD_PARTY : WebKit.CookieAcceptPolicy.ALWAYS);
            WebKit.WebContext.get_default ().set_spell_checking_enabled (
                setting_enabled ("enable-spell-checking", true));
            network_session.download_started.connect ((download) => handle_download (download, false));

            build_interface ();
            install_actions ();
            string? development_plugins = Environment.get_variable ("XANH_PLUGIN_DIR");
            plugins = new PluginManager (plugin_host, development_plugins);
            plugin_host.notify["adblock-enabled"].connect (refresh_adblock_filters);
            plugin_host.notify["status-text"].connect (() => status.label = plugin_host.status_text);
            plugin_host.notify["colorful-tabs-enabled"].connect (refresh_tab_colors);
            plugin_host.page_loaded.connect ((state) => {
                var tab = tabs.lookup (state.id);
                if (tab != null) update_tab_label (tab);
            });
            close_request.connect (on_close_request);
        }

        void build_interface () {
            var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            var header = new Gtk.HeaderBar ();
            header.show_title_buttons = true;

            back = new Gtk.Button.from_icon_name ("go-previous-symbolic");
            back.tooltip_text = "Back";
            back.clicked.connect (() => {
                var tab = active_tab ();
                if (tab != null) {
                    tab.state.recovery_uri = null;
                    tab.view.go_back ();
                }
            });
            header.pack_start (back);
            forward = new Gtk.Button.from_icon_name ("go-next-symbolic");
            forward.tooltip_text = "Forward";
            forward.clicked.connect (() => {
                var tab = active_tab ();
                if (tab != null) {
                    tab.state.recovery_uri = null;
                    tab.view.go_forward ();
                }
            });
            header.pack_start (forward);
            reload = new Gtk.Button.from_icon_name ("view-refresh-symbolic");
            reload.tooltip_text = "Reload";
            reload.clicked.connect (() => {
                var tab = active_tab ();
                if (tab == null) return;
                if (tab.state.recovery_uri != null) {
                    string recovery_uri = tab.state.recovery_uri;
                    tab.state.recovery_uri = null;
                    tab.view.load_uri (recovery_uri);
                } else {
                    tab.view.reload ();
                }
            });
            header.pack_start (reload);

            address = new Gtk.Entry ();
            address.hexpand = true;
            address.placeholder_text = "Search or enter address";
            address.activate.connect (() => {
                var tab = active_tab ();
                if (tab != null) {
                    tab.state.recovery_uri = null;
                    tab.view.load_uri (resolve_address (address.text));
                }
            });
            header.set_title_widget (address);

            var bookmark = new Gtk.Button.from_icon_name ("starred-symbolic");
            bookmark.tooltip_text = "Bookmark this page";
            bookmark.clicked.connect (() => {
                var tab = active_tab ();
                if (tab != null && plugin_host.bookmarks_enabled) plugin_host.bookmark_requested (tab.state);
            });
            header.pack_end (bookmark);

            extension_buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 2);
            header.pack_end (extension_buttons);

            var menu_button = new Gtk.MenuButton ();
            menu_button.icon_name = "open-menu-symbolic";
            menu_button.menu_model = create_menu ();
            header.pack_end (menu_button);
            set_titlebar (header);

            progress = new Gtk.ProgressBar ();
            progress.visible = false;
            root.append (progress);
            notebook = new Gtk.Notebook ();
            notebook.hexpand = true;
            notebook.vexpand = true;
            notebook.scrollable = true;
            notebook.enable_popup = true;
            notebook.switch_page.connect ((page, index) => {
                update_chrome ();
                schedule_session_save ();
            });
            notebook.page_reordered.connect ((child, index) => schedule_session_save ());
            browser_area = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            browser_area.append (notebook);
            sidebar = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            sidebar.width_request = 340;
            sidebar.visible = false;
            var sidebar_header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            sidebar_header.margin_start = 8;
            sidebar_header.margin_end = 4;
            sidebar_header.margin_top = 6;
            sidebar_header.margin_bottom = 6;
            sidebar_title = new Gtk.Label ("Extension");
            sidebar_title.hexpand = true;
            sidebar_title.halign = Gtk.Align.START;
            sidebar_header.append (sidebar_title);
            var close_sidebar = new Gtk.Button.from_icon_name ("window-close-symbolic");
            close_sidebar.tooltip_text = "Close sidebar";
            close_sidebar.clicked.connect (() => sidebar.visible = false);
            sidebar_header.append (close_sidebar);
            sidebar.append (sidebar_header);
            sidebar_content = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            sidebar_content.vexpand = true;
            sidebar.append (sidebar_content);
            browser_area.append (sidebar);
            root.append (browser_area);
            status = new Gtk.Label ("");
            status.halign = Gtk.Align.END;
            status.margin_end = 8;
            status.margin_top = 3;
            status.margin_bottom = 3;
            root.append (status);
            set_child (root);
        }

        MenuModel create_menu () {
            var menu = new Menu ();
            menu.append ("New Tab", "win.new-tab");
            menu.append ("New Private Tab", "win.new-private-tab");
            menu.append ("Close Tab", "win.close-tab");
            menu.append ("Bookmarks", "win.bookmarks");
            menu.append ("History", "win.history");
            menu.append ("Downloads", "win.downloads");
            menu.append ("Zoom In", "win.zoom-in");
            menu.append ("Zoom Out", "win.zoom-out");
            menu.append ("Reset Zoom", "win.zoom-reset");
            menu.append ("Toggle JavaScript", "win.toggle-javascript");
            menu.append ("Toggle Images", "win.toggle-images");
            menu.append ("Clear Private Data", "win.clear-data");
            menu.append ("Import Legacy Profile", "win.import-profile");
            menu.append ("About Xanh Browser", "win.about");
            return menu;
        }

        void install_actions () {
            add_action (action ("new-tab", () => add_tab ("about:blank", false)));
            add_action (action ("new-private-tab", () => add_tab ("about:blank", true)));
            add_action (action ("close-tab", close_active_tab));
            add_action (action ("bookmarks", () => show_pages ("Bookmarks", true)));
            add_action (action ("history", () => show_pages ("History", false)));
            add_action (action ("downloads", show_downloads));
            add_action (action ("zoom-in", () => adjust_zoom (0.1)));
            add_action (action ("zoom-out", () => adjust_zoom (-0.1)));
            add_action (action ("zoom-reset", () => set_zoom (1.0)));
            add_action (action ("toggle-javascript", toggle_javascript));
            add_action (action ("toggle-images", toggle_images));
            add_action (action ("clear-data", confirm_clear_data));
            add_action (action ("import-profile", confirm_profile_import));
            add_action (action ("about", show_about));
        }

        delegate void ActionCallback ();

        SimpleAction action (string name, owned ActionCallback callback) {
            var result = new SimpleAction (name, null);
            result.activate.connect (() => callback ());
            return result;
        }

        void adjust_zoom (double difference) {
            var tab = active_tab ();
            if (tab == null || !plugin_host.status_features_enabled) return;
            set_zoom ((tab.view.zoom_level + difference).clamp (0.5, 3.0));
        }

        void set_zoom (double value) {
            var tab = active_tab ();
            if (tab == null || !plugin_host.status_features_enabled) return;
            tab.view.zoom_level = value;
            status.label = "Zoom %.0f%%".printf (value * 100.0);
        }

        void toggle_javascript () {
            var tab = active_tab ();
            if (tab == null || !plugin_host.status_features_enabled) return;
            var settings = tab.view.get_settings ();
            bool enabled = !settings.enable_javascript;
            settings.enable_javascript = enabled;
            try { database.set_setting ("enable-javascript", enabled.to_string ()); }
            catch (Error error) { warning ("Cannot save JavaScript setting: %s", error.message); }
            tab.view.reload ();
        }

        void toggle_images () {
            var tab = active_tab ();
            if (tab == null || !plugin_host.status_features_enabled) return;
            var settings = tab.view.get_settings ();
            bool enabled = !settings.auto_load_images;
            settings.auto_load_images = enabled;
            try { database.set_setting ("auto-load-images", enabled.to_string ()); }
            catch (Error error) { warning ("Cannot save image setting: %s", error.message); }
            tab.view.reload ();
        }

        public void restore_session_or_open (string? initial_uri = null) {
            if (initial_uri != null) {
                add_tab (initial_uri, false);
                return;
            }
            try {
                int selected;
                var stored = database.load_session (out selected);
                foreach (var page in stored) add_tab (page.uri, false);
                if (stored.length () > 0) notebook.set_current_page (selected);
                else add_tab (homepage (), false);
            } catch (Error error) {
                warning ("Cannot restore Xanh Browser session: %s", error.message);
                add_tab (homepage (), false);
            }
        }

        public void offer_profile_import () {
            var importer = new ProfileImporter (database);
            try {
                if (!importer.is_available () || importer.has_imported ()) return;
            } catch (Error error) {
                warning ("Cannot inspect legacy profile: %s", error.message);
                return;
            }
            confirm_profile_import ();
        }

        public void add_tab (string uri, bool private_mode) {
            var manager = new WebKit.UserContentManager ();
            var settings = new WebKit.Settings ();
            settings.enable_javascript = setting_enabled ("enable-javascript", true);
            settings.auto_load_images = setting_enabled ("auto-load-images", true);
            settings.enable_developer_extras = false;
            settings.enable_html5_database = true;
            settings.user_agent = "%s %s".printf (settings.user_agent, Config.USER_AGENT_TOKEN);
            WebKit.NetworkSession session = private_mode ? new WebKit.NetworkSession.ephemeral () : network_session;
            session.set_itp_enabled (true);
            if (private_mode) {
                session.download_started.connect ((download) => handle_download (download, true));
            }
            var view = Object.new (
                typeof (WebKit.WebView),
                "network-session", session,
                "user-content-manager", manager,
                "settings", settings,
                "default-content-security-policy", "upgrade-insecure-requests; block-all-mixed-content"
            ) as WebKit.WebView;
            var state = new TabState ();
            state.id = next_tab_id++;
            state.private_mode = private_mode;
            var label = new Gtk.Label (private_mode ? "Private Tab" : "New Tab");
            label.ellipsize = Pango.EllipsizeMode.END;
            label.max_width_chars = 24;
            var bridge = new WebExtensionBridge (this, view);
            if (!private_mode) {
                bridge.action_available.connect (register_extension_action);
                bridge.load_default_locations (!extension_services_started);
                extension_services_started = true;
            }
            var record = new TabRecord (state, view, label, bridge);
            tabs.insert (state.id, record);
            connect_view (record);
            var tab_header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
            tab_header.append (label);
            var close = new Gtk.Button.from_icon_name ("window-close-symbolic");
            close.add_css_class ("flat");
            close.tooltip_text = "Close tab";
            close.clicked.connect (() => close_tab (state.id));
            tab_header.append (close);
            int page = notebook.append_page (view, tab_header);
            notebook.set_tab_reorderable (view, true);
            notebook.set_current_page (page);
            string target = uri == "" || uri == "about:blank" ? "about:blank" : resolve_address (uri);
            if (plugin_host.adblock_enabled) {
                install_adblock.begin (manager, (object, result) => {
                    try { install_adblock.end (result); }
                    catch (Error error) { warning ("Adblock filter unavailable: %s", error.message); }
                    view.load_uri (target);
                });
            } else {
                view.load_uri (target);
            }
            schedule_session_save ();
        }

        async void install_adblock (WebKit.UserContentManager manager) throws Error {
            string filter_dir = Path.build_filename (
                Environment.get_user_cache_dir (), "xanh-browser", "filters");
            DirUtils.create_with_parents (filter_dir, 0700);
            var store = new WebKit.UserContentFilterStore (filter_dir);
            string[] blocked = normalized_domains (plugin_host.adblock_blocked_domains);
            if (blocked.length == 0) return;
            string[] allowed = normalized_domains (plugin_host.adblock_whitelist_domains);
            string whitelist = allowed.length > 0 ?
                ",\"unless-domain\":" + domain_json (allowed) : "";
            string rules = ("[{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":%s%s}," +
                "\"action\":{\"type\":\"block\"}}]").printf (domain_json (blocked), whitelist);
            var filter = yield store.save ("xanh-builtin-adblock-v1", new Bytes (rules.data));
            manager.add_filter (filter);
        }

        string[] normalized_domains (string configured) {
            string[] domains = {};
            foreach (string raw in configured.split (",")) {
                string domain = raw.strip ().down ();
                if (domain.has_prefix ("*.")) domain = domain.substring (2);
                if (domain == "" || domain.has_prefix (".") || domain.has_suffix (".")) continue;
                bool valid = true;
                for (int index = 0; index < domain.length; index++) {
                    char current = domain[index];
                    if (!(current.isalnum () || current == '.' || current == '-')) {
                        valid = false;
                        break;
                    }
                }
                if (valid) domains += domain;
            }
            return domains;
        }

        string domain_json (string[] domains) {
            string json = "[";
            for (int index = 0; index < domains.length; index++) {
                if (index > 0) json += ",";
                json += "\"*" + domains[index] + "\"";
            }
            return json + "]";
        }

        void refresh_adblock_filters () {
            tabs.foreach ((id, tab) => {
                var manager = tab.view.get_user_content_manager ();
                manager.remove_filter_by_id ("xanh-builtin-adblock-v1");
                if (plugin_host.adblock_enabled) {
                    install_adblock.begin (manager, (object, result) => {
                        try { install_adblock.end (result); }
                        catch (Error error) {
                            warning ("Cannot refresh adblock filter: %s", error.message);
                        }
                    });
                }
            });
        }

        void connect_view (TabRecord tab) {
            tab.view.notify["title"].connect (() => {
                if (tab.state.recovery_uri == null) {
                    tab.state.title = tab.view.title ?? "New Tab";
                }
                update_tab_label (tab);
                update_chrome ();
                schedule_session_save ();
            });
            tab.view.notify["uri"].connect (() => {
                if (tab.state.recovery_uri == null) {
                    tab.state.uri = tab.view.uri ?? "about:blank";
                }
                update_chrome ();
                schedule_session_save ();
            });
            tab.view.notify["estimated-load-progress"].connect (() => {
                tab.state.progress = tab.view.estimated_load_progress;
                plugin_host.progress_changed (tab.state);
                update_chrome ();
            });
            tab.view.load_changed.connect ((event) => {
                if (event == WebKit.LoadEvent.STARTED && tab.state.recovery_uri != null &&
                        tab.view.uri != "xanh:error") {
                    tab.state.recovery_uri = null;
                }
                if (event == WebKit.LoadEvent.FINISHED) {
                    if (tab.state.recovery_uri == null) {
                        tab.state.uri = tab.view.uri ?? "about:blank";
                        tab.state.title = tab.view.title ?? tab.state.uri;
                    }
                    try { database.record_history (tab.state.uri, tab.state.title, tab.state.private_mode); }
                    catch (Error error) { warning ("Cannot record history: %s", error.message); }
                    plugin_host.page_loaded (tab.state);
                    update_chrome ();
                    schedule_session_save ();
                }
            });
            tab.view.load_failed_with_tls_errors.connect ((uri, certificate, errors) => {
                show_tls_error.begin (tab, uri, certificate, errors);
                return true;
            });
            tab.view.permission_request.connect ((request) => {
                ask_permission.begin (tab, request);
                return true;
            });
            tab.view.web_process_terminated.connect ((reason) => {
                string? failed_uri = tab.view.uri;
                if (BrowserDatabase.is_web_uri (failed_uri)) tab.state.recovery_uri = failed_uri;
                tab.view.load_alternate_html (
                    "<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'\">" +
                    "<h1>Page process stopped</h1><p>Reload this tab to continue.</p>",
                    "xanh:error", null);
            });
            tab.view.create.connect ((navigation) => {
                add_tab ("about:blank", tab.state.private_mode);
                var created = active_tab ();
                return created != null ? created.view : null;
            });
        }

        async void ask_permission (TabRecord tab, WebKit.PermissionRequest request) {
            var dialog = new Gtk.AlertDialog ("Allow website permission?");
            dialog.detail = "%s is requesting access to a protected browser capability."
                .printf (tab.state.uri);
            dialog.buttons = { "Deny", "Allow once" };
            dialog.cancel_button = 0;
            dialog.default_button = 0;
            try {
                if ((yield dialog.choose (this, null)) == 1) request.allow ();
                else request.deny ();
            } catch (Error error) {
                request.deny ();
            }
        }

        async void show_tls_error (TabRecord tab, string uri, TlsCertificate tls,
                TlsCertificateFlags errors) {
            var parsed = new Gcr.SimpleCertificate (tls.certificate.data);
            var dialog = new Gtk.AlertDialog ("TLS certificate error");
            dialog.detail = "Site: %s\nSubject: %s\nIssuer: %s\nSHA-256: %s\nErrors: %s".printf (
                uri, parsed.get_subject_name () ?? "Unknown", parsed.get_issuer_name () ?? "Unknown",
                parsed.get_fingerprint_hex (ChecksumType.SHA256) ?? "Unavailable", errors.to_string ());
            dialog.buttons = { "Go Back", "Continue for This Session" };
            dialog.cancel_button = 0;
            dialog.default_button = 0;
            try {
                if ((yield dialog.choose (this, null)) == 1) {
                    var parsed_uri = Uri.parse (uri, UriFlags.NONE);
                    if (parsed_uri.get_host () != null) {
                        tab.view.get_network_session ().allow_tls_certificate_for_host (
                            tls, parsed_uri.get_host ());
                        tab.view.load_uri (uri);
                    }
                } else if (tab.view.can_go_back ()) tab.view.go_back ();
            } catch (Error error) {
                warning ("TLS dialog failed: %s", error.message);
            }
        }

        void handle_download (WebKit.Download download, bool private_mode) {
            download.decide_destination.connect ((suggested) => {
                var dialog = new Gtk.FileDialog ();
                dialog.title = "Save Download";
                dialog.initial_name = suggested;
                dialog.save.begin (this, null, (object, result) => {
                    try {
                        var file = dialog.save.end (result);
                        string? path = file.get_path ();
                        if (path == null) throw new IOError.INVALID_ARGUMENT ("Downloads require a local file");
                        download.set_destination (path);
                    } catch (Error error) {
                        download.cancel ();
                    }
                });
                return true;
            });
            download.finished.connect (() => {
                if (private_mode) return;
                try {
                    database.record_download (download.get_request ().get_uri (),
                        download.get_destination () ?? "", "finished");
                } catch (Error error) {
                    warning ("Cannot record download: %s", error.message);
                }
            });
            download.failed.connect ((error) => {
                if (private_mode) return;
                try {
                    database.record_download (download.get_request ().get_uri (),
                        download.get_destination () ?? "", "failed");
                } catch (Error database_error) {
                    warning ("Cannot record failed download: %s", database_error.message);
                }
            });
        }

        TabRecord? active_tab () {
            int index = notebook.get_current_page ();
            if (index < 0) return null;
            var view = notebook.get_nth_page (index) as WebKit.WebView;
            if (view == null) return null;
            TabRecord? result = null;
            tabs.foreach ((id, tab) => { if (tab.view == view) result = tab; });
            return result;
        }

        void close_active_tab () {
            var tab = active_tab ();
            if (tab != null) close_tab (tab.state.id);
        }

        void close_tab (uint64 id) {
            var tab = tabs.lookup (id);
            if (tab == null) return;
            int page = notebook.page_num (tab.view);
            if (page >= 0) notebook.remove_page (page);
            tabs.remove (id);
            if (notebook.get_n_pages () == 0) add_tab (homepage (), false);
            update_chrome ();
            schedule_session_save ();
        }

        void update_chrome () {
            var tab = active_tab ();
            if (tab == null) return;
            if (!address.has_focus) address.text = tab.state.uri;
            back.sensitive = tab.view.can_go_back ();
            forward.sensitive = tab.view.can_go_forward ();
            progress.fraction = tab.state.progress;
            progress.visible = tab.state.progress > 0.0 && tab.state.progress < 1.0;
            title = "%s — %s".printf (tab.state.title, Config.APP_NAME);
        }

        void refresh_tab_colors () {
            tabs.foreach ((id, tab) => {
                if (!plugin_host.colorful_tabs_enabled) {
                    tab.state.tint = null;
                    tab.label.tooltip_text = null;
                } else if (tab.state.tint != null) {
                    tab.label.tooltip_text = "Tab color " + tab.state.tint;
                }
                update_tab_label (tab);
            });
        }

        void update_tab_label (TabRecord tab) {
            if (plugin_host.colorful_tabs_enabled && tab.state.tint != null) {
                tab.label.use_markup = true;
                tab.label.label = "<span foreground=\"%s\">%s</span>".printf (
                    tab.state.tint, Markup.escape_text (tab.state.title));
            } else {
                tab.label.use_markup = false;
                tab.label.label = tab.state.title;
            }
        }

        bool on_close_request () {
            if (session_save_source != 0) {
                Source.remove (session_save_source);
                session_save_source = 0;
            }
            plugin_host.shutting_down ();
            if (plugin_host.session_enabled) persist_session ();
            plugins.shutdown ();
            return false;
        }

        void schedule_session_save () {
            if (!plugin_host.session_enabled) return;
            if (session_save_source != 0) Source.remove (session_save_source);
            session_save_source = Timeout.add_seconds (1, () => {
                session_save_source = 0;
                persist_session ();
                return Source.REMOVE;
            });
        }

        void persist_session () {
            var stored = new List<StoredPage> ();
            int active_page = notebook.get_current_page ();
            int selected = 0;
            int persistent_position = 0;
            for (int index = 0; index < notebook.get_n_pages (); index++) {
                var view = notebook.get_nth_page (index) as WebKit.WebView;
                if (view == null) continue;
                var record = find_tab (view);
                if (record != null && !record.state.private_mode) {
                    if (index == active_page) selected = persistent_position;
                    stored.append (new StoredPage (record.state.uri, record.state.title));
                    persistent_position++;
                }
            }
            try { database.save_session (stored, selected); }
            catch (Error error) { warning ("Cannot save session: %s", error.message); }
        }

        TabRecord? find_tab (WebKit.WebView view) {
            TabRecord? result = null;
            tabs.foreach ((id, tab) => { if (tab.view == view) result = tab; });
            return result;
        }

        bool setting_enabled (string key, bool fallback) {
            try {
                string? value = database.get_setting (key);
                if (value == null) return fallback;
                return value.down () == "true" || value == "1" || value.down () == "yes";
            } catch (Error error) {
                return fallback;
            }
        }

        string homepage () {
            try {
                string? configured = database.get_setting ("homepage");
                if (BrowserDatabase.is_web_uri (configured)) return configured;
            } catch (Error error) {
                warning ("Cannot load homepage setting: %s", error.message);
            }
            return HOME;
        }

        string resolve_address (string input) {
            try {
                string? configured = database.get_setting ("location-entry-search");
                if (configured != null && configured.has_prefix ("https://") && configured.contains ("%s")) {
                    return AddressResolver.resolve (input, configured);
                }
            } catch (Error error) {
                warning ("Cannot load search setting: %s", error.message);
            }
            return AddressResolver.resolve (input);
        }

        void show_pages (string heading, bool bookmarks) {
            try {
                var pages = bookmarks ? database.list_bookmarks () : database.list_history ();
                var window = new Gtk.Window ();
                window.title = heading;
                window.transient_for = this;
                window.default_width = 640;
                window.default_height = 480;
                var list = new Gtk.ListBox ();
                foreach (var page in pages) {
                    var row = new Gtk.ListBoxRow ();
                    var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
                    var title_label = new Gtk.Label (page.title);
                    title_label.halign = Gtk.Align.START;
                    var uri_label = new Gtk.Label (page.uri);
                    uri_label.halign = Gtk.Align.START;
                    uri_label.add_css_class ("dim-label");
                    box.append (title_label);
                    box.append (uri_label);
                    row.set_child (box);
                    row.set_data<string> ("uri", page.uri);
                    list.append (row);
                }
                list.row_activated.connect ((row) => {
                    string? uri = row.get_data<string> ("uri");
                    if (uri != null) add_tab (uri, false);
                    window.close ();
                });
                var scroll = new Gtk.ScrolledWindow ();
                scroll.set_child (list);
                window.set_child (scroll);
                window.present ();
            } catch (Error error) {
                show_message (heading, error.message);
            }
        }

        void show_downloads () {
            try {
                var downloads = database.list_downloads ();
                var window = new Gtk.Window ();
                window.title = "Downloads";
                window.transient_for = this;
                window.default_width = 700;
                window.default_height = 480;
                var list = new Gtk.ListBox ();
                foreach (var download in downloads) {
                    var row = new Gtk.ListBoxRow ();
                    var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
                    box.margin_start = 8;
                    box.margin_end = 8;
                    box.margin_top = 6;
                    box.margin_bottom = 6;
                    var destination = new Gtk.Label (download.destination);
                    destination.halign = Gtk.Align.START;
                    destination.ellipsize = Pango.EllipsizeMode.MIDDLE;
                    var details = new Gtk.Label ("%s — %s".printf (download.status, download.uri));
                    details.halign = Gtk.Align.START;
                    details.ellipsize = Pango.EllipsizeMode.END;
                    details.add_css_class ("dim-label");
                    box.append (destination);
                    box.append (details);
                    row.set_child (box);
                    row.set_data<string> ("destination", download.destination);
                    list.append (row);
                }
                list.row_activated.connect ((row) => {
                    string? destination = row.get_data<string> ("destination");
                    if (destination != null) {
                        try {
                            var file = File.new_for_path (destination);
                            AppInfo.launch_default_for_uri (file.get_uri (), null);
                        } catch (Error error) {
                            show_message ("Unable to Open Download", error.message);
                        }
                    }
                });
                var scroll = new Gtk.ScrolledWindow ();
                scroll.set_child (list);
                window.set_child (scroll);
                window.present ();
            } catch (Error error) {
                show_message ("Downloads", error.message);
            }
        }

        void register_extension_action (WebExtensionBridge bridge, string extension_id,
                string? action_title, string? action_popup,
                string? panel_title, string? panel_path) {
            if (action_title != null && action_popup != null) {
                string key = extension_id + ":action";
                if (!registered_extension_actions.contains (key)) {
                    registered_extension_actions.insert (key, true);
                    var button = extension_action_button (bridge, extension_id, action_title, false);
                    button.tooltip_text = action_title;
                    button.add_css_class ("flat");
                    button.clicked.connect (() => show_extension_popup (
                        bridge, extension_id, action_title, action_popup));
                    extension_buttons.append (button);
                }
            }
            if (panel_title != null && panel_path != null) {
                string key = extension_id + ":sidebar";
                if (!registered_extension_actions.contains (key)) {
                    registered_extension_actions.insert (key, true);
                    var button = extension_action_button (bridge, extension_id, panel_title, true);
                    button.tooltip_text = "Open %s sidebar".printf (panel_title);
                    button.add_css_class ("flat");
                    button.clicked.connect (() => show_extension_sidebar (
                        bridge, extension_id, panel_title, panel_path));
                    extension_buttons.append (button);
                }
            }
        }

        Gtk.Button extension_action_button (WebExtensionBridge bridge, string extension_id,
                string title, bool for_sidebar) {
            var button = new Gtk.Button ();
            try {
                string? icon = bridge.get_extension_icon (extension_id, for_sidebar);
                if (icon != null) {
                    var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
                    var image = new Gtk.Image.from_file (icon);
                    image.pixel_size = 18;
                    box.append (image);
                    box.append (new Gtk.Label (title));
                    button.set_child (box);
                } else {
                    button.label = title;
                }
            } catch (Error error) {
                button.label = title;
            }
            return button;
        }

        void show_extension_popup (WebExtensionBridge bridge, string extension_id,
                string heading, string relative) {
            try {
                var tab = active_tab ();
                if (tab == null || tab.state.private_mode) {
                    throw new IOError.PERMISSION_DENIED ("Extensions are disabled in private tabs");
                }
                bridge.grant_active_tab (extension_id, tab.state.id, tab.state.uri);
                var window = new Gtk.Window ();
                window.title = heading;
                window.transient_for = this;
                window.default_width = 420;
                window.default_height = 520;
                window.set_child (bridge.create_extension_view (extension_id, relative));
                window.present ();
            } catch (Error error) {
                show_message (heading, error.message);
            }
        }

        void show_extension_sidebar (WebExtensionBridge bridge, string extension_id,
                string heading, string relative) {
            try {
                var tab = active_tab ();
                if (tab == null || tab.state.private_mode) {
                    throw new IOError.PERMISSION_DENIED ("Extensions are disabled in private tabs");
                }
                bridge.grant_active_tab (extension_id, tab.state.id, tab.state.uri);
                Gtk.Widget? child;
                while ((child = sidebar_content.get_first_child ()) != null) {
                    sidebar_content.remove (child);
                }
                sidebar_title.label = heading;
                var view = bridge.create_extension_view (extension_id, relative);
                view.hexpand = true;
                view.vexpand = true;
                sidebar_content.append (view);
                sidebar.visible = true;
            } catch (Error error) {
                show_message (heading, error.message);
            }
        }

        void confirm_clear_data () {
            clear_data.begin ();
        }

        async void clear_data () {
            var dialog = new Gtk.AlertDialog ("Clear browsing data?");
            dialog.detail = "History, session data, cookies, caches and local website storage will be deleted.";
            dialog.buttons = { "Cancel", "Clear Data" };
            dialog.cancel_button = 0;
            try {
                if ((yield dialog.choose (this, null)) != 1) return;
                yield network_session.get_website_data_manager ().clear (WebKit.WebsiteDataTypes.ALL, 0);
                var private_managers = new List<WebKit.WebsiteDataManager> ();
                tabs.foreach ((id, tab) => {
                    if (tab.state.private_mode) {
                        private_managers.append (tab.view.get_network_session ().get_website_data_manager ());
                    }
                });
                foreach (var manager in private_managers) {
                    yield manager.clear (WebKit.WebsiteDataTypes.ALL, 0);
                }
                database.clear_private_data ();
                reset_tabs_after_clear ();
                show_message ("Private Data", "Browsing data was cleared.");
            } catch (Error error) {
                show_message ("Unable to Clear Data", error.message);
            }
        }

        void reset_tabs_after_clear () {
            if (session_save_source != 0) {
                Source.remove (session_save_source);
                session_save_source = 0;
            }
            tabs.foreach ((id, tab) => tab.view.stop_loading ());
            while (notebook.get_n_pages () > 0) notebook.remove_page (0);
            tabs.remove_all ();
            registered_extension_actions.remove_all ();
            Gtk.Widget? button;
            while ((button = extension_buttons.get_first_child ()) != null) {
                extension_buttons.remove (button);
            }
            Gtk.Widget? panel;
            while ((panel = sidebar_content.get_first_child ()) != null) {
                sidebar_content.remove (panel);
            }
            sidebar.visible = false;
            extension_services_started = false;
            add_tab (homepage (), false);
        }

        void confirm_profile_import () {
            import_profile.begin ();
        }

        async void import_profile () {
            var importer = new ProfileImporter (database);
            if (!importer.is_available ()) {
                show_message ("Profile Import", "No legacy Midori profile was found.");
                return;
            }
            var dialog = new Gtk.AlertDialog ("Import legacy browser data?");
            dialog.detail = "Bookmarks, history and selected settings will be copied once. The previous session will not be opened.";
            dialog.buttons = { "Cancel", "Import" };
            dialog.cancel_button = 0;
            try {
                if ((yield dialog.choose (this, null)) != 1) return;
                var result = importer.import_once ();
                show_message ("Profile Import", "%d bookmarks, %d history entries and %d settings imported."
                    .printf (result.bookmarks, result.history, result.settings));
            } catch (Error error) {
                show_message ("Profile Import Failed", error.message);
            }
        }

        void show_about () {
            var about = new Gtk.AboutDialog ();
            about.transient_for = this;
            about.modal = true;
            about.program_name = Config.APP_NAME;
            about.version = Config.VERSION;
            about.logo_icon_name = Config.APP_ID;
            about.comments = "A privacy-minded GTK 4 and WebKitGTK browser";
            about.website = "https://github.com/lamppkk/xanhbrowser";
            about.present ();
        }

        void show_message (string heading, string detail) {
            var dialog = new Gtk.AlertDialog (heading);
            dialog.detail = detail;
            dialog.show (this);
        }

        public void create_extension_tab (string uri) {
            add_tab (uri, false);
        }

        public string? get_active_extension_uri () {
            return active_tab ()?.state.uri;
        }

        public uint64 get_active_extension_tab_id () {
            var tab = active_tab ();
            return tab != null ? tab.state.id : 0;
        }

        public bool is_active_extension_tab_private () {
            var tab = active_tab ();
            return tab == null || tab.state.private_mode;
        }

        public async string execute_extension_script (string world, string code) throws Error {
            var tab = active_tab ();
            if (tab == null) throw new IOError.NOT_FOUND ("No active tab");
            var value = yield tab.view.evaluate_javascript (code, -1, world, null, null);
            return value.to_json (0);
        }

        public void show_extension_notification (string id, string heading, string message) {
            var notification = new Notification (heading);
            notification.set_body (message);
            application.send_notification ("extension-" + id, notification);
        }
    }
}
