/* SPDX-License-Identifier: LGPL-2.1-or-later */

namespace Xanh {
    class TabRecord : Object {
        public TabState state { get; construct; }
        public WebKit.WebView view { get; construct; }
        public Gtk.Label label { get; construct; }
        public WebExtensionBridge bridge { get; construct; }
        public CredentialBridge? credential_bridge { get; construct; }
        public ExternalNavigationBridge? external_navigation_bridge { get; construct; }
        public WebProcessRecoveryPolicy recovery { get; construct; }
        public ulong credential_request_signal { get; set; }
        public ulong external_navigation_signal { get; set; }

        public TabRecord (TabState state, WebKit.WebView view, Gtk.Label label,
                WebExtensionBridge bridge, CredentialBridge? credential_bridge,
                ExternalNavigationBridge? external_navigation_bridge) {
            Object (state: state, view: view, label: label, bridge: bridge,
                credential_bridge: credential_bridge,
                external_navigation_bridge: external_navigation_bridge,
                recovery: new WebProcessRecoveryPolicy ());
        }
    }

    public class BrowserWindow : Gtk.ApplicationWindow, ExtensionHost {
        const string HOME = "https://duckduckgo.com/";
        public const int MAX_SYNC_TABS = 200;
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
        bool clearing_data;
        uint64 next_tab_id = 1;
        uint session_save_source;
        Gtk.Popover? credential_picker;
        CredentialBridge? credential_picker_bridge;
        string? credential_picker_request_id;
        Cancellable? credential_request_cancellable;
        uint credential_picker_timeout_source;
        WebKit.PermissionRequest? pending_permission_request;
        TabRecord? pending_permission_tab;
        string? pending_permission_document_uri;
        Cancellable? pending_permission_cancellable;
        uint pending_permission_timeout_source;
        uint64 permission_generation;

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
            notify["is-active"].connect (() => {
                if (!is_active) {
                    cancel_credential_picker ();
                    cancel_permission_request ();
                    (application as BrowserApplication)?.lock_sync_vault ();
                    tabs.foreach ((id, tab) => {
                        if (tab.recovery.cancel_automatic_recovery ()) {
                            tab.view.stop_loading ();
                            show_process_stopped (tab);
                        }
                    });
                } else {
                    maybe_recover_active_tab ();
                }
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
                    begin_explicit_navigation (tab);
                    tab.view.go_back ();
                }
            });
            header.pack_start (back);
            forward = new Gtk.Button.from_icon_name ("go-next-symbolic");
            forward.tooltip_text = "Forward";
            forward.clicked.connect (() => {
                var tab = active_tab ();
                if (tab != null) {
                    begin_explicit_navigation (tab);
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
                    begin_explicit_navigation (tab);
                    tab.view.load_uri (recovery_uri);
                } else {
                    begin_explicit_navigation (tab);
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
                    if (AddressResolver.is_safe_external_uri (address.text)) {
                        launch_external_uri (address.text);
                        return;
                    }
                    begin_explicit_navigation (tab);
                    tab.view.load_uri (resolve_address (address.text));
                }
            });
            header.set_title_widget (address);

            var bookmark = new Gtk.Button.from_icon_name ("starred-symbolic");
            bookmark.tooltip_text = "Bookmark this page";
            bookmark.clicked.connect (() => {
                var tab = active_tab ();
                if (tab != null && plugin_host.bookmarks_enabled) {
                    plugin_host.bookmark_requested (tab.state);
                    (application as BrowserApplication)?.save_synced_bookmark (tab.state);
                }
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
                cancel_credential_picker ();
                cancel_permission_request ();
                var selected = page as WebKit.WebView;
                tabs.foreach ((id, tab) => {
                    if (tab.view != selected &&
                            tab.recovery.cancel_automatic_recovery ()) {
                        tab.view.stop_loading ();
                        show_process_stopped (tab);
                    }
                });
                update_chrome ();
                maybe_recover_active_tab ();
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
            menu.append ("Firefox Sync", "win.firefox-sync");
            menu.append ("Tabs from Other Devices", "win.remote-tabs");
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
            add_action (action ("firefox-sync", () =>
                (application as BrowserApplication)?.show_sync_settings (this)));
            add_action (action ("remote-tabs", () => show_remote_tabs.begin ()));
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
            begin_explicit_navigation (tab);
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
            begin_explicit_navigation (tab);
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
            CredentialBridge? credential_bridge = null;
            ExternalNavigationBridge? external_navigation_bridge = null;
            try {
                external_navigation_bridge = new ExternalNavigationBridge (manager);
            } catch (Error error) {
                warning ("Cannot install isolated external-navigation bridge: %s", error.message);
            }
            if (!private_mode) {
                bridge.action_available.connect (register_extension_action);
                bridge.load_default_locations (!extension_services_started);
                extension_services_started = true;
                try {
                    credential_bridge = new CredentialBridge (manager, view);
                } catch (Error error) {
                    warning ("Cannot install isolated credential bridge: %s", error.message);
                }
            }
            var record = new TabRecord (
                state, view, label, bridge, credential_bridge, external_navigation_bridge);
            if (external_navigation_bridge != null) {
                record.external_navigation_signal =
                    external_navigation_bridge.request.connect ((external_uri, document_uri) =>
                        handle_external_navigation (record, external_uri, document_uri));
            }
            if (credential_bridge != null) {
                record.credential_request_signal =
                    credential_bridge.request.connect ((request_id, navigation_nonce,
                            document_url, origin) => {
                        handle_credential_request.begin (record, request_id,
                            navigation_nonce, document_url, origin);
                    });
            }
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
            tab.view.decide_policy.connect ((decision, type) => {
                if (type != WebKit.PolicyDecisionType.NAVIGATION_ACTION &&
                        type != WebKit.PolicyDecisionType.NEW_WINDOW_ACTION) {
                    return false;
                }
                var navigation = decision as WebKit.NavigationPolicyDecision;
                string? uri = navigation?.get_navigation_action ().get_request ().get_uri ();
                if (AddressResolver.is_safe_navigation_uri (uri)) {
                    decision.use ();
                } else {
                    decision.ignore ();
                }
                return true;
            });
            tab.view.notify["title"].connect (() => {
                if (!tab.recovery.process_stopped) {
                    tab.state.title = tab.view.title ?? "New Tab";
                }
                update_tab_label (tab);
                update_chrome ();
                schedule_session_save ();
            });
            tab.view.notify["uri"].connect (() => {
                if (!tab.recovery.process_stopped) {
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
                if (event == WebKit.LoadEvent.STARTED &&
                        credential_picker_bridge == tab.credential_bridge) {
                    cancel_credential_picker ();
                }
                if (event == WebKit.LoadEvent.STARTED &&
                        pending_permission_tab == tab) {
                    cancel_permission_request ();
                }
                if (event == WebKit.LoadEvent.COMMITTED) {
                    tab.recovery.record_committed_uri (tab.view.uri);
                }
                if (event == WebKit.LoadEvent.FINISHED) {
                    if (tab.recovery.finish_automatic_recovery (true)) {
                        tab.state.recovery_uri = null;
                        status.label = "Page process recovered";
                    }
                    bool usable_page = !tab.recovery.process_stopped;
                    if (usable_page) {
                        tab.state.uri = tab.view.uri ?? "about:blank";
                        tab.state.title = tab.view.title ?? tab.state.uri;
                    }
                    var browser_application = application as BrowserApplication;
                    bool application_clear = browser_application != null &&
                        browser_application.is_browsing_data_clear_in_progress ();
                    if (usable_page && !clearing_data && !application_clear) {
                        try { database.record_history (
                            tab.state.uri, tab.state.title, tab.state.private_mode); }
                        catch (Error error) {
                            warning ("Cannot record history: %s", error.message);
                        }
                        (application as BrowserApplication)?.record_synced_history (tab.state);
                    }
                    if (usable_page) plugin_host.page_loaded (tab.state);
                    update_chrome ();
                    schedule_session_save ();
                }
            });
            tab.view.load_failed.connect ((event, uri, error) => {
                if (!tab.recovery.finish_automatic_recovery (false)) return false;
                show_process_stopped (tab);
                return true;
            });
            tab.view.load_failed_with_tls_errors.connect ((uri, certificate, errors) => {
                if (tab.recovery.finish_automatic_recovery (false))
                    show_process_stopped (tab);
                show_tls_error.begin (tab, uri, certificate, errors);
                return true;
            });
            tab.view.permission_request.connect ((request) => {
                handle_permission_request (tab, request);
                return true;
            });
            tab.view.web_process_terminated.connect ((reason) => {
                if (credential_picker_bridge == tab.credential_bridge)
                    cancel_credential_picker ();
                if (pending_permission_tab == tab)
                    cancel_permission_request ();
                tab.recovery.record_termination ();
                tab.state.recovery_uri = tab.recovery.recovery_uri;
                show_process_stopped (tab);
                maybe_recover_tab (tab);
            });
            tab.view.create.connect ((navigation) => {
                add_tab ("about:blank", tab.state.private_mode);
                var created = active_tab ();
                return created != null ? created.view : null;
            });
        }

        void handle_permission_request (TabRecord tab, WebKit.PermissionRequest request) {
            cancel_permission_request ();
            string? document_uri = tab.view.uri;
            string? capability = permission_capability (request, document_uri);
            if (capability == null || !permission_context_is_current (tab, document_uri)) {
                request.deny ();
                status.label = "Website permission denied";
                return;
            }

            permission_generation++;
            uint64 generation = permission_generation;
            pending_permission_request = request;
            pending_permission_tab = tab;
            pending_permission_document_uri = document_uri;
            pending_permission_cancellable = new Cancellable ();
            pending_permission_timeout_source = Timeout.add_seconds (30, () => {
                if (generation == permission_generation) {
                    pending_permission_timeout_source = 0;
                    cancel_permission_request ();
                }
                return Source.REMOVE;
            });
            ask_permission.begin (tab, request, document_uri, capability, generation);
        }

        async void ask_permission (TabRecord tab, WebKit.PermissionRequest request,
                string document_uri, string capability, uint64 generation) {
            string? origin = PermissionPolicy.display_origin (document_uri);
            if (origin == null) {
                cancel_permission_request ();
                return;
            }
            var dialog = new Gtk.AlertDialog ("Allow website permission?");
            dialog.detail = "%s wants to %s. Xanh will not remember this decision after navigation."
                .printf (origin, capability);
            dialog.buttons = { "Deny", "Allow on This Page" };
            dialog.cancel_button = 0;
            dialog.default_button = 0;
            int choice = 0;
            try {
                choice = yield dialog.choose (this, pending_permission_cancellable);
            } catch (Error error) {
                choice = 0;
            }
            if (generation != permission_generation ||
                    pending_permission_request != request ||
                    pending_permission_document_uri != document_uri) {
                return;
            }
            if (!permission_context_is_current (tab, document_uri)) {
                finish_permission_request (false);
                return;
            }
            finish_permission_request (choice == 1);
        }

        string? permission_capability (WebKit.PermissionRequest request,
                string? document_uri) {
            var media = request as WebKit.UserMediaPermissionRequest;
            if (media != null) {
                if (WebKit.user_media_permission_is_for_display_device (media) &&
                        media.is_for_audio_device)
                    return "share your screen and audio";
                if (WebKit.user_media_permission_is_for_display_device (media))
                    return "share your screen";
                if (media.is_for_audio_device && media.is_for_video_device)
                    return "use your camera and microphone";
                if (media.is_for_video_device) return "use your camera";
                if (media.is_for_audio_device) return "use your microphone";
                return null;
            }
            if (request is WebKit.GeolocationPermissionRequest)
                return "access your location";
            if (request is WebKit.DeviceInfoPermissionRequest)
                return "list available camera and microphone devices";
            if (request is WebKit.PointerLockPermissionRequest)
                return "lock the pointer inside this page";
            var storage = request as WebKit.WebsiteDataAccessPermissionRequest;
            if (storage != null && document_uri != null &&
                    PermissionPolicy.storage_access_matches_document (
                        document_uri, storage.get_current_domain (),
                        storage.get_requesting_domain ())) {
                return "let %s access its website data while you visit %s".printf (
                    storage.get_requesting_domain (), storage.get_current_domain ());
            }
            return null;
        }

        bool permission_context_is_current (TabRecord tab, string? document_uri) {
            var browser_application = application as BrowserApplication;
            bool application_clear = browser_application != null &&
                browser_application.is_browsing_data_clear_in_progress ();
            return PermissionPolicy.is_prompt_context_current (
                document_uri, tab.view.uri, is_active, active_tab () == tab,
                tab.recovery.process_stopped, clearing_data || application_clear);
        }

        void finish_permission_request (bool allow) {
            var request = pending_permission_request;
            var cancellable = pending_permission_cancellable;
            pending_permission_request = null;
            pending_permission_tab = null;
            pending_permission_document_uri = null;
            pending_permission_cancellable = null;
            permission_generation++;
            if (pending_permission_timeout_source != 0) {
                Source.remove (pending_permission_timeout_source);
                pending_permission_timeout_source = 0;
            }
            cancellable?.cancel ();
            if (request == null) return;
            if (allow) {
                request.allow ();
                status.label = "Website permission allowed for this page";
            } else {
                request.deny ();
                status.label = "Website permission denied";
            }
        }

        void cancel_permission_request (TabRecord? tab = null) {
            if (pending_permission_request == null ||
                    (tab != null && pending_permission_tab != tab)) {
                return;
            }
            finish_permission_request (false);
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
                        begin_explicit_navigation (tab);
                        tab.view.load_uri (uri);
                    }
                } else if (tab.view.can_go_back ()) {
                    begin_explicit_navigation (tab);
                    tab.view.go_back ();
                }
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

        void begin_explicit_navigation (TabRecord tab) {
            if (credential_picker_bridge == tab.credential_bridge)
                cancel_credential_picker ();
            cancel_permission_request (tab);
            tab.recovery.reset_for_explicit_navigation ();
            tab.state.recovery_uri = null;
        }

        void handle_external_navigation (TabRecord tab, string external_uri,
                string document_uri) {
            var browser_application = application as BrowserApplication;
            if (!is_active || clearing_data || active_tab () != tab ||
                    tab.recovery.process_stopped || tab.view.uri != document_uri ||
                    !AddressResolver.is_safe_web_uri (document_uri) ||
                    !AddressResolver.is_safe_external_uri (external_uri) ||
                    (browser_application != null &&
                        browser_application.is_browsing_data_clear_in_progress ())) {
                return;
            }
            launch_external_uri (external_uri);
        }

        void launch_external_uri (string uri) {
            try {
                AppInfo.launch_default_for_uri (uri, null);
                status.label = "Opened link in an external application";
            } catch (Error error) {
                warning ("Cannot open external URI: %s", error.message);
                status.label = "No application can open this link";
            }
        }

        void maybe_recover_active_tab () {
            var tab = active_tab ();
            if (tab != null) maybe_recover_tab (tab);
        }

        void maybe_recover_tab (TabRecord tab) {
            if (!is_active || clearing_data || active_tab () != tab) return;
            var browser_application = application as BrowserApplication;
            if (browser_application != null &&
                    browser_application.is_browsing_data_clear_in_progress ()) return;
            string? uri = tab.recovery.take_automatic_recovery (true);
            if (uri == null) return;
            tab.state.recovery_uri = uri;
            status.label = "Recovering page process…";
            tab.view.load_uri (uri);
        }

        void show_process_stopped (TabRecord tab) {
            tab.state.recovery_uri = tab.recovery.recovery_uri;
            tab.state.title = "Page process stopped";
            tab.state.progress = 0.0;
            update_tab_label (tab);
            if (active_tab () == tab) {
                status.label = tab.state.recovery_uri == null ?
                    "Page process stopped; open another address to continue" :
                    "Page process stopped; use Reload to try again";
                update_chrome ();
            }
        }

        void close_active_tab () {
            var tab = active_tab ();
            if (tab != null) close_tab (tab.state.id);
        }

        void close_tab (uint64 id) {
            var tab = tabs.lookup (id);
            if (tab == null) return;
            if (credential_picker_bridge == tab.credential_bridge)
                cancel_credential_picker ();
            cancel_permission_request (tab);
            disconnect_tab_bridges (tab);
            int page = notebook.page_num (tab.view);
            if (page >= 0) notebook.remove_page (page);
            tabs.remove (id);
            if (notebook.get_n_pages () == 0) add_tab (homepage (), false);
            update_chrome ();
            schedule_session_save ();
        }

        void disconnect_tab_bridges (TabRecord tab) {
            if (tab.credential_bridge != null && tab.credential_request_signal != 0) {
                SignalHandler.disconnect (
                    tab.credential_bridge, tab.credential_request_signal);
                tab.credential_request_signal = 0;
            }
            if (tab.external_navigation_bridge != null &&
                    tab.external_navigation_signal != 0) {
                SignalHandler.disconnect (
                    tab.external_navigation_bridge, tab.external_navigation_signal);
                tab.external_navigation_signal = 0;
            }
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
            cancel_credential_picker ();
            cancel_permission_request ();
            tabs.foreach ((id, tab) => disconnect_tab_bridges (tab));
            if (session_save_source != 0) {
                Source.remove (session_save_source);
                session_save_source = 0;
            }
            plugin_host.shutting_down ();
            if (plugin_host.session_enabled) persist_session ();
            plugins.shutdown ();
            (application as BrowserApplication)?.window_closing ();
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

        async void handle_credential_request (TabRecord tab, string request_id,
                string navigation_nonce, string document_url, string origin) {
            var bridge = tab.credential_bridge;
            var browser_application = application as BrowserApplication;
            if (bridge == null || browser_application == null || tab.state.private_mode ||
                    active_tab () != tab || !is_active || clearing_data ||
                    browser_application.is_browsing_data_clear_in_progress ()) {
                bridge?.cancel_request (request_id);
                return;
            }
            if (credential_picker_bridge != null) {
                bridge.cancel_request (request_id);
                return;
            }
            var cancellable = new Cancellable ();
            credential_picker_bridge = bridge;
            credential_picker_request_id = request_id;
            credential_request_cancellable = cancellable;
            credential_picker_timeout_source = Timeout.add_seconds (5 * 60, () => {
                credential_picker_timeout_source = 0;
                cancel_credential_picker ();
                return Source.REMOVE;
            });
            try {
                string json = yield browser_application.get_sync_credentials (
                    document_url, origin, cancellable);
                if (!bridge.request_is_current (
                        request_id, navigation_nonce, document_url, origin) ||
                        active_tab () != tab || !is_active) {
                    bridge.cancel_request (request_id);
                    return;
                }
                var records = CredentialDataPolicy.parse (json, origin);
                if (records.length () == 0) {
                    bridge.cancel_request (request_id);
                    return;
                }
                var selected = yield choose_sync_credential (records, origin);
                if (selected == null ||
                        !bridge.request_is_current (
                            request_id, navigation_nonce, document_url, origin) ||
                        active_tab () != tab || !is_active) {
                    bridge.cancel_request (request_id);
                    return;
                }
                yield browser_application.touch_sync_credential (
                    selected.id, document_url, origin, cancellable);
                if (!bridge.request_is_current (
                        request_id, navigation_nonce, document_url, origin) ||
                        active_tab () != tab || !is_active) {
                    bridge.cancel_request (request_id);
                    return;
                }
                yield bridge.fill_async (
                    request_id, navigation_nonce, document_url, origin,
                    selected.username, selected.password, cancellable);
            } catch (Error error) {
                bridge.cancel_request (request_id);
                warning ("Saved-login request failed closed");
                status.label = "Saved login unavailable";
            } finally {
                if (credential_picker_bridge == bridge &&
                        credential_picker_request_id == request_id) {
                    var picker = credential_picker;
                    credential_picker = null;
                    credential_picker_bridge = null;
                    credential_picker_request_id = null;
                    credential_request_cancellable = null;
                    if (credential_picker_timeout_source != 0) {
                        Source.remove (credential_picker_timeout_source);
                        credential_picker_timeout_source = 0;
                    }
                    picker?.popdown ();
                }
            }
        }

        async SyncCredentialRecord? choose_sync_credential (
                List<SyncCredentialRecord> records, string origin) {
            var picker = new Gtk.Popover ();
            picker.autohide = false;
            picker.has_arrow = false;
            picker.set_size_request (440, 320);
            var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
            root.margin_start = 16;
            root.margin_end = 16;
            root.margin_top = 16;
            root.margin_bottom = 16;
            var heading = new Gtk.Label ("Saved logins for %s".printf (origin));
            heading.halign = Gtk.Align.START;
            heading.ellipsize = Pango.EllipsizeMode.MIDDLE;
            root.append (heading);
            var explanation = new Gtk.Label (
                "Choose a username to fill this page. Passwords are never shown.");
            explanation.halign = Gtk.Align.START;
            explanation.wrap = true;
            explanation.add_css_class ("dim-label");
            root.append (explanation);
            var list = new Gtk.ListBox ();
            list.selection_mode = Gtk.SelectionMode.SINGLE;
            foreach (var record in records) {
                var row = new Gtk.ListBoxRow ();
                var label = new Gtk.Label (
                    record.username == "" ? "(No username)" : record.username);
                label.halign = Gtk.Align.START;
                label.ellipsize = Pango.EllipsizeMode.END;
                label.margin_start = 10;
                label.margin_end = 10;
                label.margin_top = 10;
                label.margin_bottom = 10;
                row.set_child (label);
                row.set_data<SyncCredentialRecord> ("xanh-credential", record);
                list.append (row);
            }
            var scroll = new Gtk.ScrolledWindow ();
            scroll.vexpand = true;
            scroll.set_child (list);
            root.append (scroll);
            var cancel = new Gtk.Button.with_label ("Cancel");
            cancel.halign = Gtk.Align.END;
            root.append (cancel);
            picker.set_child (root);

            SyncCredentialRecord? selected = null;
            bool completed = false;
            SourceFunc resume = choose_sync_credential.callback;
            list.row_activated.connect ((row) => {
                if (completed) return;
                selected = row.get_data<SyncCredentialRecord> ("xanh-credential");
                completed = true;
                picker.popdown ();
                Idle.add (() => {
                    resume ();
                    return Source.REMOVE;
                });
            });
            cancel.clicked.connect (() => picker.popdown ());
            picker.closed.connect (() => {
                if (!completed) {
                    completed = true;
                    Idle.add (() => {
                        resume ();
                        return Source.REMOVE;
                    });
                }
            });
            picker.set_parent (address);
            credential_picker = picker;
            picker.popup ();
            yield;
            if (credential_picker == picker) credential_picker = null;
            picker.unparent ();
            return selected;
        }

        void cancel_credential_picker () {
            var picker = credential_picker;
            var bridge = credential_picker_bridge;
            string? request_id = credential_picker_request_id;
            var cancellable = credential_request_cancellable;
            credential_picker = null;
            credential_picker_bridge = null;
            credential_picker_request_id = null;
            credential_request_cancellable = null;
            if (credential_picker_timeout_source != 0) {
                Source.remove (credential_picker_timeout_source);
                credential_picker_timeout_source = 0;
            }
            cancellable?.cancel ();
            if (bridge != null && request_id != null)
                bridge.cancel_request (request_id);
            picker?.popdown ();
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
                var app = application as BrowserApplication;
                bool use_places = app != null && app.synced_places_available ();
                var pages = bookmarks
                    ? (use_places ? database.list_places_bookmarks () : database.list_bookmarks ())
                    : (use_places ? database.list_places_history () : database.list_history ());
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

        async void show_remote_tabs () {
            try {
                var app = application as BrowserApplication;
                if (app == null || !app.sync_connected ()) {
                    show_message ("Tabs from Other Devices", "Connect Firefox Sync to view remote tabs.");
                    return;
                }
                var devices = yield app.get_remote_tabs ();
                var window = new Gtk.Window ();
                window.title = "Tabs from Other Devices";
                window.transient_for = this;
                window.default_width = 680;
                window.default_height = 520;
                var list = new Gtk.ListBox ();
                foreach (var device in devices) {
                    foreach (var page in device.tabs) {
                        var row = new Gtk.ListBoxRow ();
                        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
                        var title = new Gtk.Label (page.title);
                        title.halign = Gtk.Align.START;
                        title.ellipsize = Pango.EllipsizeMode.END;
                        var detail = new Gtk.Label ("%s · %s".printf (device.name, page.uri));
                        detail.halign = Gtk.Align.START;
                        detail.ellipsize = Pango.EllipsizeMode.END;
                        detail.add_css_class ("dim-label");
                        box.append (title);
                        box.append (detail);
                        row.set_child (box);
                        row.set_data<string> ("uri", page.uri);
                        list.append (row);
                    }
                }
                if (devices.length () == 0) {
                    var empty = new Gtk.Label ("No remote tabs are available.");
                    empty.margin_top = 24;
                    empty.margin_bottom = 24;
                    list.append (empty);
                }
                list.row_activated.connect ((row) => {
                    string? uri = row.get_data<string> ("uri");
                    if (BrowserDatabase.is_web_uri (uri)) add_tab (uri, false);
                    window.close ();
                });
                var scroll = new Gtk.ScrolledWindow ();
                scroll.set_child (list);
                window.set_child (scroll);
                window.present ();
            } catch (Error error) {
                show_message ("Tabs from Other Devices", error.message);
            }
        }

        public int append_sync_tabs (Json.Builder builder, int remaining) {
            int64 now = new DateTime.now_utc ().to_unix () * 1000;
            int emitted = 0;
            for (int index = 0;
                    index < notebook.get_n_pages () && emitted < remaining &&
                    emitted < MAX_SYNC_TABS; index++) {
                var view = notebook.get_nth_page (index) as WebKit.WebView;
                if (view == null) continue;
                var tab = find_tab (view);
                if (tab == null || tab.state.private_mode ||
                        !SyncDataCoordinator.is_sync_web_uri (tab.state.uri)) continue;
                builder.begin_object ();
                builder.set_member_name ("title");
                builder.add_string_value (
                    SyncDataCoordinator.sanitized_sync_title (tab.state.title));
                builder.set_member_name ("url_history");
                builder.begin_array ();
                builder.add_string_value (tab.state.uri);
                builder.end_array ();
                builder.set_member_name ("icon_url");
                builder.add_null_value ();
                builder.set_member_name ("last_used_epoch_millis");
                builder.add_int_value (now);
                builder.set_member_name ("is_private");
                builder.add_boolean_value (false);
                builder.set_member_name ("is_pinned");
                builder.add_boolean_value (false);
                builder.end_object ();
                emitted++;
            }
            return emitted;
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
                var browser_application = application as BrowserApplication;
                if (browser_application == null ||
                        !browser_application.begin_browsing_data_clear ()) {
                    show_message ("Clear Browsing Data", "A clear operation is already running.");
                    return;
                }
                var clearing_windows = new List<BrowserWindow> ();
                foreach (var window in browser_application.get_windows ()) {
                    var browser = window as BrowserWindow;
                    if (browser != null) {
                        clearing_windows.append (browser);
                        browser.prepare_for_data_clear ();
                    }
                }
                string? sync_warning = null;
                try {
                    try { yield browser_application.clear_synced_history (); }
                    catch (Error error) { sync_warning = error.message; }
                    try { browser_application.clear_sync_migration_snapshots (); }
                    catch (Error error) {
                        sync_warning = append_clear_warning (sync_warning, error.message);
                    }
                    var managers = new List<WebKit.WebsiteDataManager> ();
                    foreach (var browser in clearing_windows)
                        browser.append_data_managers (managers);
                    foreach (var manager in managers) {
                        yield manager.clear (WebKit.WebsiteDataTypes.ALL, 0);
                    }
                    database.clear_private_data ();
                    foreach (var browser in clearing_windows)
                        browser.reset_tabs_after_clear ();
                    if (sync_warning == null) {
                        show_message ("Private Data", "Browsing data was cleared.");
                    } else {
                        show_message ("Browsing Data Partially Cleared",
                            "Website and legacy browsing data were cleared, but some Firefox " +
                            "Sync data cleanup remains pending: " + sync_warning);
                    }
                } finally {
                    foreach (var browser in clearing_windows)
                        browser.finish_data_clear ();
                    browser_application.finish_browsing_data_clear ();
                }
            } catch (Error error) {
                show_message ("Unable to Clear Data", error.message);
            }
        }

        void prepare_for_data_clear () {
            clearing_data = true;
            cancel_credential_picker ();
            cancel_permission_request ();
            tabs.foreach ((id, tab) => tab.view.stop_loading ());
        }

        void finish_data_clear () {
            clearing_data = false;
        }

        void append_data_managers (List<WebKit.WebsiteDataManager> managers) {
            managers.append (network_session.get_website_data_manager ());
            tabs.foreach ((id, tab) => {
                if (tab.state.private_mode) {
                    managers.append (tab.view.get_network_session ()
                        .get_website_data_manager ());
                }
            });
        }

        string append_clear_warning (string? current, string addition) {
            return current == null ? addition : current + "; " + addition;
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
                (application as BrowserApplication)?.import_new_legacy_data ();
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
