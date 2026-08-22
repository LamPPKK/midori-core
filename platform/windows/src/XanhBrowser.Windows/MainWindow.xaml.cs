using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Security.Cryptography;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.System;
using XanhBrowser.Core;

namespace XanhBrowser.Windows;

public sealed partial class MainWindow : Window
{
    private FirefoxSyncCoordinator? _sync;
    private readonly SemaphoreSlim _historyOperations = new(1, 1);
    private readonly SemaphoreSlim _syncInitialization = new(1, 1);
    private readonly DispatcherTimer _vaultTimer = new() { Interval = TimeSpan.FromSeconds(30) };
    private Uri? _pendingSyncCallback;
    private bool _credentialDialogOpen;
    private bool _historyClearInProgress;
    private bool _userPresenceInProgress;
    private long _historyClearGeneration;

    public MainWindow()
    {
        InitializeComponent();
        Title = "Xanh Browser";
        Closed += MainWindow_Closed;
        Activated += MainWindow_Activated;
        BrowserTabs.Loaded += BrowserTabs_Loaded;
        _vaultTimer.Tick += VaultTimer_Tick;
        _vaultTimer.Start();
        AddTab(isPrivate: false);
    }

    public async void HandleFirefoxSyncCallback(Uri callback)
    {
        if (BrowserTabs.XamlRoot is null)
        {
            _pendingSyncCallback = callback;
            return;
        }
        try
        {
            if (!await EnsureFirefoxSyncAsync(showConfiguration: false))
                throw new InvalidOperationException("Firefox Sync is not configured on this device.");
            await _sync!.CompleteOAuthAsync(callback);
            await PublishLocalTabsAsync();
            UpdateFirefoxSyncUi(_sync.Snapshot);
            await ShowMessageAsync("Firefox Sync", "Sign-in completed and the first sync was requested.");
        }
        catch (Exception error)
        {
            await ShowMessageAsync("Firefox Sync sign-in failed", error.Message);
        }
    }

    private async void BrowserTabs_Loaded(object sender, RoutedEventArgs e)
    {
        try
        {
            await EnsureFirefoxSyncAsync(showConfiguration: false);
            if (_pendingSyncCallback is { } callback)
            {
                _pendingSyncCallback = null;
                HandleFirefoxSyncCallback(callback);
            }
        }
        catch (Exception error)
        {
            FirefoxSyncStatus.Text = $"Sync unavailable: {error.Message}";
        }
    }

    private async void FirefoxSync_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (!await EnsureFirefoxSyncAsync(showConfiguration: true)) return;
            if (_sync!.Snapshot.AccountState == FirefoxAccountState.Connected)
            {
                await SyncCurrentTabsAsync(FirefoxSyncReason.Manual);
                UpdateFirefoxSyncUi(_sync.Snapshot);
                return;
            }
            if (_sync.Snapshot.AccountState == FirefoxAccountState.Authenticating)
            {
                await ShowMessageAsync("Firefox Sync", "Finish sign-in in the system browser.");
                return;
            }

            var launch = await _sync.BeginOAuthAsync();
            if (!await ConfirmAccountDomainAsync(launch.AccountDomain)) return;
            WindowsFirefoxSyncConfiguration.EnsureProtocolRegistration();
            if (!await Launcher.LaunchUriAsync(launch.AuthorizationUri))
                throw new InvalidOperationException("Windows could not open the system browser.");
            UpdateFirefoxSyncUi(_sync.Snapshot);
        }
        catch (Exception error)
        {
            await ShowMessageAsync("Firefox Sync failed", error.Message);
        }
    }

    private async void FirefoxSyncSettings_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (!await EnsureFirefoxSyncAsync(showConfiguration: true)) return;
            await ShowFirefoxSyncSettingsAsync();
        }
        catch (Exception error)
        {
            await ShowMessageAsync("Firefox Sync settings failed", error.Message);
        }
    }

    private async Task<bool> EnsureFirefoxSyncAsync(bool showConfiguration)
    {
        await _syncInitialization.WaitAsync();
        try
        {
            if (_sync is not null) return true;
            var configuration = WindowsFirefoxSyncConfiguration.Load();
            if (configuration is null && showConfiguration)
                configuration = await PromptForSelfHostedSyncAsync();
            if (configuration is null) return false;

            var coordinator = new FirefoxSyncCoordinator(
                configuration,
                WindowsFirefoxSyncConfiguration.ProfileDirectory,
                new NativeFirefoxSyncFactory(),
                new WindowsSyncSecretStore());
            coordinator.SnapshotChanged += Sync_SnapshotChanged;
            try
            {
                await coordinator.InitializeAsync();
                _sync = coordinator;
                if (coordinator.Snapshot.AccountState == FirefoxAccountState.Connected)
                    await SyncCurrentTabsAsync(FirefoxSyncReason.Startup);
                UpdateFirefoxSyncUi(coordinator.Snapshot);
            }
            catch
            {
                coordinator.SnapshotChanged -= Sync_SnapshotChanged;
                coordinator.Dispose();
                throw;
            }
            return true;
        }
        finally
        {
            _syncInitialization.Release();
        }
    }

    private async Task<FirefoxSyncConfiguration?> PromptForSelfHostedSyncAsync()
    {
        var accounts = new TextBox
        {
            Header = "Accounts server (HTTPS)",
            PlaceholderText = "https://accounts.example.org",
        };
        var token = new TextBox
        {
            Header = "Token Server (HTTPS)",
            PlaceholderText = "https://sync.example.org/token",
        };
        var client = new TextBox
        {
            Header = "Client ID issued by this deployment",
        };
        var content = new StackPanel { Spacing = 10 };
        content.Children.Add(new TextBlock
        {
            Text = "This build has no approved Mozilla production client ID. Configure the same self-hosted Accounts/Sync deployment used by Firefox.",
            TextWrapping = TextWrapping.Wrap,
        });
        content.Children.Add(accounts);
        content.Children.Add(token);
        content.Children.Add(client);
        var dialog = new ContentDialog
        {
            XamlRoot = BrowserTabs.XamlRoot,
            Title = "Configure Firefox Sync",
            Content = content,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return null;
        var configuration = new FirefoxSyncConfiguration(
            new Uri(accounts.Text.Trim()),
            new Uri(token.Text.Trim()),
            client.Text.Trim(),
            WindowsFirefoxSyncConfiguration.RedirectUri,
            Environment.MachineName);
        configuration.Validate();
        WindowsFirefoxSyncConfiguration.SaveSelfHosted(configuration);
        return configuration;
    }

    private async Task<bool> ConfirmAccountDomainAsync(string domain)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = BrowserTabs.XamlRoot,
            Title = "Open Firefox Accounts?",
            Content = $"Xanh Browser will open the system browser and continue sign-in at {domain}. TLS errors cannot be bypassed.",
            PrimaryButtonText = "Continue",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    private async Task ShowFirefoxSyncSettingsAsync()
    {
        var coordinator = _sync!;
        var snapshot = coordinator.Snapshot;
        var bookmarks = EngineToggle("Bookmarks", FirefoxSyncEngine.Bookmarks, snapshot);
        var history = EngineToggle("History", FirefoxSyncEngine.History, snapshot);
        var tabs = EngineToggle("Tabs", FirefoxSyncEngine.Tabs, snapshot);
        var passwords = EngineToggle("Passwords", FirefoxSyncEngine.Passwords, snapshot);
        var vault = new Button { Content = snapshot.VaultUnlocked ? "Lock password vault" : "Unlock password vault" };
        var remoteTabs = new Button { Content = "Show remote tabs" };
        var disconnect = new Button { Content = "Disconnect" };
        var detail = new TextBlock { Text = snapshot.Detail, TextWrapping = TextWrapping.Wrap };
        var disconnectRequested = false;
        var content = new StackPanel { Spacing = 8, MinWidth = 360 };
        content.Children.Add(detail);
        foreach (var control in new Control[] { bookmarks, history, tabs, passwords, vault, remoteTabs, disconnect })
            content.Children.Add(control);
        var dialog = new ContentDialog
        {
            XamlRoot = BrowserTabs.XamlRoot,
            Title = "Firefox Sync",
            Content = content,
            CloseButtonText = "Done",
        };
        vault.Click += async (_, _) =>
        {
            try
            {
                if (coordinator.Snapshot.VaultUnlocked) await coordinator.LockVaultAsync();
                else
                {
                    _userPresenceInProgress = true;
                    try
                    {
                        if (!await coordinator.UnlockVaultAsync())
                            detail.Text = "Windows Hello or PIN verification was not completed.";
                    }
                    finally { _userPresenceInProgress = false; }
                }
                vault.Content = coordinator.Snapshot.VaultUnlocked ? "Lock password vault" : "Unlock password vault";
            }
            catch (Exception error)
            {
                detail.Text = error.Message;
            }
        };
        remoteTabs.Click += async (_, _) =>
        {
            try
            {
                var json = await coordinator.RemoteTabsJsonAsync();
                detail.Text = RemoteTabsSummary(json);
            }
            catch (Exception error)
            {
                detail.Text = error.Message;
            }
        };
        disconnect.Click += (_, _) =>
        {
            disconnectRequested = true;
            dialog.Hide();
        };
        await dialog.ShowAsync();
        if (disconnectRequested)
        {
            var deleteLocal = await ConfirmDeleteLocalSyncDataAsync();
            if (deleteLocal is not null)
                await coordinator.DisconnectAsync(deleteLocal.Value);
        }
    }

    private CheckBox EngineToggle(
        string label,
        FirefoxSyncEngine engine,
        FirefoxSyncHostSnapshot snapshot)
    {
        var toggle = new CheckBox
        {
            Content = label,
            IsChecked = snapshot.EnabledEngines.Contains(engine),
        };
        toggle.Checked += async (_, _) =>
        {
            try { if (_sync is not null) await _sync.SetEngineEnabledAsync(engine, true); }
            catch (Exception error) { FirefoxSyncStatus.Text = error.Message; }
        };
        toggle.Unchecked += async (_, _) =>
        {
            try { if (_sync is not null) await _sync.SetEngineEnabledAsync(engine, false); }
            catch (Exception error) { FirefoxSyncStatus.Text = error.Message; }
        };
        return toggle;
    }

    private async Task<bool?> ConfirmDeleteLocalSyncDataAsync()
    {
        var dialog = new ContentDialog
        {
            XamlRoot = BrowserTabs.XamlRoot,
            Title = "Disconnect Firefox Sync",
            Content = "Keep local data by default, or remove Places, Logins, Tabs, Sync metadata and the device-local vault key.",
            PrimaryButtonText = "Keep local data",
            SecondaryButtonText = "Remove from device",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        return await dialog.ShowAsync() switch
        {
            ContentDialogResult.Primary => false,
            ContentDialogResult.Secondary => true,
            _ => null,
        };
    }

    private static string RemoteTabsSummary(string json)
    {
        using var document = System.Text.Json.JsonDocument.Parse(json);
        if (document.RootElement.ValueKind != System.Text.Json.JsonValueKind.Array)
            return "No remote devices are available.";
        var devices = document.RootElement.GetArrayLength();
        var tabs = 0;
        foreach (var device in document.RootElement.EnumerateArray())
            if (device.TryGetProperty("tabs", out var values)
                && values.ValueKind == System.Text.Json.JsonValueKind.Array)
                tabs += values.GetArrayLength();
        return devices == 0
            ? "No remote devices are available."
            : $"{tabs} tab(s) from {devices} device(s). Remote tabs are never opened automatically.";
    }

    private void Sync_SnapshotChanged(object? sender, FirefoxSyncHostSnapshot snapshot) =>
        DispatcherQueue.TryEnqueue(() => UpdateFirefoxSyncUi(snapshot));

    private void UpdateFirefoxSyncUi(FirefoxSyncHostSnapshot snapshot)
    {
        FirefoxSyncStatus.Text = snapshot.Detail;
        FirefoxSyncButton.Label = snapshot.AccountState switch
        {
            FirefoxAccountState.Connected => "Sync now",
            FirefoxAccountState.Authenticating => "Finish sign-in",
            FirefoxAccountState.AuthIssues => "Fix Sync",
            _ => "Set up Sync",
        };
    }

    private async Task PublishLocalTabsAsync(bool markLocalChange = true)
    {
        if (_sync is null) return;
        var tabs = BrowserTabs.TabItems
            .OfType<TabViewItem>()
            .Select(item => item.Content)
            .OfType<BrowserTab>()
            .Where(tab => !tab.IsPrivate
                && FirefoxPlacesPolicy.IsAllowedWebUri(tab.LastSuccessfulUri))
            .Take(FirefoxPlacesPolicy.MaximumLocalTabs)
            .Select(tab => new FirefoxLocalTab(
                tab.CurrentTitle,
                new[] { tab.LastSuccessfulUri },
                null,
                tab.LastUsed,
                false))
            .ToArray();
        await _sync.UpdateLocalTabsAsync(tabs, markLocalChange);
    }

    private async Task SyncCurrentTabsAsync(FirefoxSyncReason reason)
    {
        if (_sync is null) return;
        await PublishLocalTabsAsync(markLocalChange: false);
        await _sync.SyncAsync(reason);
    }

    private async void Browser_PageVisited(object? sender, BrowserPageVisitedEventArgs args)
    {
        if (args.IsPrivate || _historyClearInProgress) return;
        var clearGeneration = Interlocked.Read(ref _historyClearGeneration);
        await _historyOperations.WaitAsync();
        try
        {
            if (!await EnsureFirefoxSyncAsync(showConfiguration: false) || _sync is null) return;
            if (_historyClearInProgress
                || clearGeneration != Interlocked.Read(ref _historyClearGeneration))
                return;
            await _sync.RecordHistoryAsync(
                args.Uri,
                args.Title,
                args.VisitedAt,
                FirefoxHistoryTransition.Link,
                isPrivate: false);
            if (_historyClearInProgress
                || clearGeneration != Interlocked.Read(ref _historyClearGeneration))
            {
                await _sync.DeleteHistoryVisitAsync(
                    args.Uri,
                    args.VisitedAt.ToUnixTimeMilliseconds());
                return;
            }
            await PublishLocalTabsAsync();
        }
        catch (Exception)
        {
            FirefoxSyncStatus.Text = "Firefox Sync could not record this history visit";
        }
        finally
        {
            _historyOperations.Release();
        }
    }

    private async void VaultTimer_Tick(object? sender, object e)
    {
        if (_sync is null) return;
        try
        {
            await _sync.LockVaultIfIdleAsync();
            if (_sync.Snapshot.AccountState == FirefoxAccountState.Connected)
            {
                await _sync.SyncAsync(FirefoxSyncReason.LocalChange);
                await SyncCurrentTabsAsync(FirefoxSyncReason.Scheduled);
            }
        }
        catch { FirefoxSyncStatus.Text = "Firefox Sync scheduling needs attention"; }
    }

    private async void MainWindow_Activated(object sender, WindowActivatedEventArgs args)
    {
        if (_sync is null) return;
        try
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated
                && !_userPresenceInProgress)
                await _sync.LockVaultAsync();
            else if (_sync.Snapshot.AccountState == FirefoxAccountState.Connected)
                await SyncCurrentTabsAsync(FirefoxSyncReason.Startup);
        }
        catch { FirefoxSyncStatus.Text = "Firefox Sync foreground handling needs attention"; }
    }

    private void BrowserTabs_AddTabButtonClick(TabView sender, object args) => AddTab(isPrivate: false);

    private void NewPrivateTab_Click(object sender, RoutedEventArgs e) => AddTab(isPrivate: true);

    private async void BrowserTabs_TabCloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs args)
    {
        if (sender.TabItems.Count <= 1)
        {
            return;
        }

        if (args.Tab is TabViewItem tab)
        {
            (tab.Content as BrowserTab)?.Dispose();
            sender.TabItems.Remove(tab);
            try { await PublishLocalTabsAsync(); }
            catch (Exception) { FirefoxSyncStatus.Text = "Firefox Sync could not update local tabs"; }
        }
    }

    private TabViewItem AddTab(bool isPrivate, Uri? initialUri = null)
    {
        var browser = new BrowserTab(isPrivate, initialUri, ShowCredentialPickerAsync);
        var tab = new TabViewItem
        {
            Header = isPrivate ? "Private tab" : "New tab",
            IconSource = new SymbolIconSource
            {
                Symbol = isPrivate ? Symbol.ProtectedDocument : Symbol.World,
            },
            Content = browser,
        };

        AttachBrowser(tab, browser);

        BrowserTabs.TabItems.Add(tab);
        BrowserTabs.SelectedItem = tab;
        return tab;
    }

    private BrowserTab? SelectedBrowser() =>
        (BrowserTabs.SelectedItem as TabViewItem)?.Content as BrowserTab;

    private async void AddBookmark_Click(object sender, RoutedEventArgs e)
    {
        var browser = SelectedBrowser();
        if (browser is null) return;
        if (browser.IsPrivate)
        {
            await ShowMessageAsync(
                "Private browsing",
                "Bookmarks cannot be created from a private tab.");
            return;
        }
        try
        {
            if (!await EnsureFirefoxSyncAsync(showConfiguration: true) || _sync is null) return;
            await _sync.CreateBookmarkAsync(
                browser.LastSuccessfulUri,
                browser.CurrentTitle,
                FirefoxBookmarkRoot.Mobile,
                isPrivate: false);
            await ShowMessageAsync("Bookmark saved", "The page was saved to Mobile Bookmarks.");
        }
        catch (Exception error)
        {
            await ShowMessageAsync("Bookmark failed", error.Message);
        }
    }

    private async void Bookmarks_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (!await EnsureFirefoxSyncAsync(showConfiguration: true) || _sync is null) return;
            await ShowBookmarksLibraryAsync(_sync);
        }
        catch (Exception error)
        {
            await ShowMessageAsync("Bookmarks unavailable", error.Message);
        }
    }

    private async Task ShowBookmarksLibraryAsync(FirefoxSyncCoordinator coordinator)
    {
        var records = Array.Empty<FirefoxBookmarkRecord>();
        var list = new ListView
        {
            SelectionMode = ListViewSelectionMode.Single,
            MaxHeight = 360,
            MinWidth = 520,
        };
        var title = new TextBox
        {
            Header = "Selected bookmark title",
            MaxLength = FirefoxPlacesPolicy.MaximumTitleBytes,
            IsEnabled = false,
        };
        var open = new Button { Content = "Open selected", IsEnabled = false };
        var rename = new Button { Content = "Rename selected", IsEnabled = false };
        var delete = new Button { Content = "Delete selected", IsEnabled = false };
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(open);
        actions.Children.Add(rename);
        actions.Children.Add(delete);
        var content = new StackPanel { Spacing = 8 };
        content.Children.Add(list);
        content.Children.Add(title);
        content.Children.Add(actions);
        content.Children.Add(status);
        var dialog = new ContentDialog
        {
            XamlRoot = BrowserTabs.XamlRoot,
            Title = "Firefox Sync bookmarks",
            Content = content,
            CloseButtonText = "Done",
        };
        var operationRunning = false;

        FirefoxBookmarkRecord? SelectedRecord() => list.SelectedIndex is >= 0
            && list.SelectedIndex < records.Length
                ? records[list.SelectedIndex]
                : null;
        async Task ReloadAsync(string? detail = null)
        {
            var all = new List<FirefoxBookmarkRecord>();
            foreach (var root in Enum.GetValues<FirefoxBookmarkRoot>())
            {
                all.AddRange(await coordinator.BookmarksAsync(root));
                if (all.Count > FirefoxPlacesPolicy.MaximumBookmarks)
                    throw new InvalidOperationException("Combined bookmark library exceeds 10,000 records.");
            }
            records = all.Where(record => record.Kind == "bookmark").ToArray();
            list.ItemsSource = records.Select(record =>
                $"{record.Title ?? "Untitled"}\n{record.Url ?? "No URL"}").ToArray();
            list.SelectedIndex = records.Length == 0 ? -1 : 0;
            status.Text = detail ?? (records.Length == 0
                ? "No Firefox Sync bookmarks are available."
                : $"{records.Length} bookmark(s). Unsafe Firefox URLs remain manageable but cannot be opened.");
        }
        list.SelectionChanged += (_, _) =>
        {
            var selected = SelectedRecord();
            title.Text = selected?.Title ?? "";
            title.IsEnabled = selected is not null;
            open.IsEnabled = selected?.OpenableUri is not null;
            rename.IsEnabled = selected is not null;
            delete.IsEnabled = selected is not null;
        };
        open.Click += (_, _) =>
        {
            if (SelectedRecord()?.OpenableUri is { } uri)
            {
                AddTab(isPrivate: false, initialUri: uri);
                dialog.Hide();
            }
        };
        rename.Click += async (_, _) =>
        {
            var selected = SelectedRecord();
            if (operationRunning || selected is null) return;
            operationRunning = true;
            actions.IsEnabled = false;
            try
            {
                await coordinator.RenameBookmarkAsync(selected.Guid, title.Text, isPrivate: false);
                await ReloadAsync("Bookmark renamed. The next Sync will publish the exact GUID update.");
            }
            catch (Exception error) { status.Text = error.Message; }
            finally
            {
                operationRunning = false;
                actions.IsEnabled = true;
            }
        };
        delete.Click += async (_, _) =>
        {
            var selected = SelectedRecord();
            if (operationRunning || selected is null) return;
            operationRunning = true;
            actions.IsEnabled = false;
            try
            {
                var deleted = await coordinator.DeleteBookmarkAsync(selected.Guid, isPrivate: false);
                await ReloadAsync(deleted ? "Bookmark deleted by exact GUID." : "Bookmark no longer exists.");
            }
            catch (Exception error) { status.Text = error.Message; }
            finally
            {
                operationRunning = false;
                actions.IsEnabled = true;
            }
        };

        await ReloadAsync();
        await dialog.ShowAsync();
    }

    private async void History_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (!await EnsureFirefoxSyncAsync(showConfiguration: true) || _sync is null) return;
            await ShowHistoryLibraryAsync(_sync);
        }
        catch (Exception error)
        {
            await ShowMessageAsync("History unavailable", error.Message);
        }
    }

    private async Task ShowHistoryLibraryAsync(FirefoxSyncCoordinator coordinator)
    {
        var records = Array.Empty<FirefoxHistoryVisitRecord>();
        var list = new ListView
        {
            SelectionMode = ListViewSelectionMode.Single,
            MaxHeight = 420,
            MinWidth = 560,
        };
        var open = new Button { Content = "Open selected", IsEnabled = false };
        var delete = new Button { Content = "Delete selected visit", IsEnabled = false };
        var clear = new Button { Content = "Clear all Sync history" };
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(open);
        actions.Children.Add(delete);
        actions.Children.Add(clear);
        var content = new StackPanel { Spacing = 8 };
        content.Children.Add(list);
        content.Children.Add(actions);
        content.Children.Add(status);
        var dialog = new ContentDialog
        {
            XamlRoot = BrowserTabs.XamlRoot,
            Title = "Firefox Sync history",
            Content = content,
            CloseButtonText = "Done",
        };
        var operationRunning = false;
        var clearRequested = false;

        FirefoxHistoryVisitRecord? SelectedRecord() => list.SelectedIndex is >= 0
            && list.SelectedIndex < records.Length
                ? records[list.SelectedIndex]
                : null;
        async Task ReloadAsync(string? detail = null)
        {
            records = (await coordinator.RecentHistoryAsync()).ToArray();
            list.ItemsSource = records.Select(record =>
            {
                var visited = DateTimeOffset.FromUnixTimeMilliseconds(record.VisitedAtEpochMillis)
                    .ToLocalTime();
                return $"{record.Title ?? record.Url}\n{record.Url} — {visited:g}";
            }).ToArray();
            list.SelectedIndex = records.Length == 0 ? -1 : 0;
            status.Text = detail ?? (records.Length == 0
                ? "No history is available."
                : $"{records.Length} recent visit(s). Remote visits are shown but never opened automatically.");
        }
        list.SelectionChanged += (_, _) =>
        {
            var selected = SelectedRecord();
            open.IsEnabled = selected?.OpenableUri is not null;
            delete.IsEnabled = selected is not null;
        };
        open.Click += (_, _) =>
        {
            if (SelectedRecord()?.OpenableUri is { } uri)
            {
                AddTab(isPrivate: false, initialUri: uri);
                dialog.Hide();
            }
        };
        delete.Click += async (_, _) =>
        {
            var selected = SelectedRecord();
            if (operationRunning || selected?.OpenableUri is not { } uri) return;
            operationRunning = true;
            actions.IsEnabled = false;
            try
            {
                await coordinator.DeleteHistoryVisitAsync(uri, selected.VisitedAtEpochMillis);
                await ReloadAsync("The selected URL/timestamp visit was deleted.");
            }
            catch (Exception error) { status.Text = error.Message; }
            finally
            {
                operationRunning = false;
                actions.IsEnabled = true;
            }
        };
        clear.Click += (_, _) =>
        {
            if (operationRunning) return;
            clearRequested = true;
            dialog.Hide();
        };

        await ReloadAsync();
        await dialog.ShowAsync();
        if (clearRequested && await ConfirmClearSyncedHistoryAsync())
        {
            _historyClearInProgress = true;
            Interlocked.Increment(ref _historyClearGeneration);
            await _historyOperations.WaitAsync();
            try
            {
                await coordinator.ClearHistoryAsync();
                await ShowMessageAsync(
                    "History cleared",
                    "All local Places history was cleared and the deletion will be published by the next Sync.");
            }
            finally
            {
                _historyOperations.Release();
                _historyClearInProgress = false;
            }
        }
    }

    private async Task<bool> ConfirmClearSyncedHistoryAsync()
    {
        var dialog = new ContentDialog
        {
            XamlRoot = BrowserTabs.XamlRoot,
            Title = "Clear all Firefox Sync history?",
            Content = "This deletes every local Places history visit and publishes the deletion on the next Sync. It does not clear WebView2 cookies or cache.",
            PrimaryButtonText = "Clear history",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    private async Task<FirefoxCredentialRecord?> ShowCredentialPickerAsync(
        CredentialAccessContext context)
    {
        if (_credentialDialogOpen || context.IsPrivate || !context.IsAllowed) return null;
        _credentialDialogOpen = true;
        try
        {
            if (!await EnsureFirefoxSyncAsync(showConfiguration: false) || _sync is null) return null;
            if (!_sync.Snapshot.VaultUnlocked)
            {
                _userPresenceInProgress = true;
                try
                {
                    if (!await _sync.UnlockVaultAsync()) return null;
                }
                finally { _userPresenceInProgress = false; }
            }
            var credentials = await _sync.CredentialsAsync(context);
            if (credentials.Count == 0) return null;
            var labels = credentials
                .Select(record => string.IsNullOrWhiteSpace(record.Username)
                    ? "(empty username)"
                    : record.Username)
                .ToList();
            var list = new ListView
            {
                ItemsSource = labels,
                SelectionMode = ListViewSelectionMode.Single,
                SelectedIndex = 0,
                MaxHeight = 320,
                MinWidth = 360,
            };
            var dialog = new ContentDialog
            {
                XamlRoot = BrowserTabs.XamlRoot,
                Title = $"Choose a saved login for {context.DocumentUri.IdnHost}",
                Content = list,
                PrimaryButtonText = "Fill",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Primary,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary
                || list.SelectedIndex < 0
                || list.SelectedIndex >= credentials.Count)
                return null;
            var selected = credentials[list.SelectedIndex];
            await _sync.TouchCredentialAsync(selected.Id, context);
            return selected;
        }
        finally
        {
            _credentialDialogOpen = false;
        }
    }

    private async void ExportBackup_Click(object sender, RoutedEventArgs e)
    {
        var passphrase = await PromptForBackupPasswordAsync("Export encrypted backup");
        if (passphrase is null)
        {
            return;
        }

        var regularTabs = BrowserTabs.TabItems
            .OfType<TabViewItem>()
            .Select(item => item.Content)
            .OfType<BrowserTab>()
            .Where(tab => !tab.IsPrivate && PortableBackup.IsSupportedWebUrl(tab.CurrentUri.AbsoluteUri))
            .ToList();
        var selectedTab = (BrowserTabs.SelectedItem as TabViewItem)?.Content as BrowserTab;
        var selectedIndex = selectedTab is { IsPrivate: false } && regularTabs.Contains(selectedTab)
            ? Math.Max(0, regularTabs.IndexOf(selectedTab))
            : 0;
        var urls = regularTabs.Count == 0
            ? new List<string> { AddressResolver.DefaultHomePage.AbsoluteUri }
            : regularTabs.Select(tab => tab.CurrentUri.AbsoluteUri).ToList();
        var payload = new PortableBackupPayload(
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            "windows-webview2",
            urls,
            selectedIndex,
            false);

        try
        {
            var picker = new FileSavePicker
            {
                SuggestedFileName = $"xanh-browser-{DateTime.UtcNow:yyyyMMdd-HHmmss}",
            };
            picker.FileTypeChoices.Add("Xanh Browser encrypted backup", [PortableBackup.FileExtension]);
            InitializePicker(picker);
            var file = await picker.PickSaveFileAsync();
            if (file is null)
            {
                return;
            }
            await FileIO.WriteBytesAsync(file, PortableBackup.Encode(payload, passphrase));
            await ShowMessageAsync("Backup exported", "The encrypted backup can be stored in an OS, Google Drive, OneDrive or Git-synced folder.");
        }
        catch (Exception error)
        {
            await ShowMessageAsync("Backup failed", error.Message);
        }
    }

    private async void ImportBackup_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add(PortableBackup.FileExtension);
        InitializePicker(picker);
        var file = await picker.PickSingleFileAsync();
        if (file is null)
        {
            return;
        }

        var passphrase = await PromptForBackupPasswordAsync("Import encrypted backup");
        if (passphrase is null)
        {
            return;
        }

        try
        {
            var properties = await file.GetBasicPropertiesAsync();
            if (properties.Size > PortableBackup.MaxEncodedBytes)
            {
                throw new InvalidDataException("Backup is too large.");
            }
            var buffer = await FileIO.ReadBufferAsync(file);
            if (buffer.Length > PortableBackup.MaxEncodedBytes)
            {
                throw new InvalidDataException("Backup is too large.");
            }
            CryptographicBuffer.CopyToByteArray(buffer, out var bytes);
            var backup = PortableBackup.Decode(bytes, passphrase);
            TabViewItem? selected = null;
            for (var index = 0; index < backup.Urls.Count; index++)
            {
                if (!Uri.TryCreate(backup.Urls[index], UriKind.Absolute, out var uri)
                    || !AddressResolver.IsAllowedWebUri(uri))
                {
                    continue;
                }
                var tab = AddTab(isPrivate: false, uri);
                if (index == backup.SelectedIndex)
                {
                    selected = tab;
                }
            }
            if (selected is not null)
            {
                BrowserTabs.SelectedItem = selected;
            }
            await ShowMessageAsync("Backup imported", "Regular tabs were added. Cookies, passwords, cache and private tabs are never imported.");
        }
        catch (Exception error)
        {
            await ShowMessageAsync("Backup failed", error.Message);
        }
    }

    private async Task<string?> PromptForBackupPasswordAsync(string title)
    {
        var password = new PasswordBox
        {
            Header = "Backup password",
            PlaceholderText = "At least 8 characters",
        };
        var dialog = new ContentDialog
        {
            XamlRoot = BrowserTabs.XamlRoot,
            Title = title,
            Content = password,
            PrimaryButtonText = "Continue",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return null;
        }
        if (password.Password.Length < 8)
        {
            await ShowMessageAsync("Password too short", "Use at least 8 characters.");
            return null;
        }
        return password.Password;
    }

    private async Task ShowMessageAsync(string title, string message)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = BrowserTabs.XamlRoot,
            Title = title,
            Content = message,
            CloseButtonText = "OK",
        };
        await dialog.ShowAsync();
    }

    private void InitializePicker(object picker)
    {
        var windowHandle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, windowHandle);
    }

    private void AttachBrowser(TabViewItem tab, BrowserTab browser)
    {
        browser.TitleChanged += (_, title) => tab.Header = string.IsNullOrWhiteSpace(title)
            ? (browser.IsPrivate ? "Private tab" : "New tab")
            : title;
        browser.RecoveryRequested += (_, args) =>
        {
            if (!ReferenceEquals(tab.Content, browser))
            {
                return;
            }

            var replacement = new BrowserTab(
                browser.IsPrivate,
                args.Target,
                ShowCredentialPickerAsync,
                automaticRecoveryUsed: true);
            browser.Dispose();
            tab.Content = replacement;
            AttachBrowser(tab, replacement);
        };
        browser.PageVisited += Browser_PageVisited;
    }

    private void MainWindow_Closed(object sender, WindowEventArgs args)
    {
        _vaultTimer.Stop();
        if (_sync is not null)
        {
            _sync.SnapshotChanged -= Sync_SnapshotChanged;
            _sync.Dispose();
            _sync = null;
        }
        foreach (var item in BrowserTabs.TabItems.OfType<TabViewItem>())
        {
            (item.Content as BrowserTab)?.Dispose();
        }
    }
}
