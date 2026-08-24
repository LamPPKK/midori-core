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
    private bool _credentialLibraryOpen;
    private bool _credentialSurfaceForeground = true;
    private bool _historyClearInProgress;
    private bool _userPresenceInProgress;
    private long _historyClearGeneration;
    private ContentDialog? _activeCredentialDialog;
    private IAdblockEngine? _adblockEngine;
    private bool _adblockEnabled;
    private bool _adblockInitializationAttempted;
    private bool _isClosing;

    public MainWindow()
    {
        _adblockEnabled = AdblockPreference.Resolve(
            ApplicationData.Current.LocalSettings.Values[AdblockPreference.StorageKey]);
        InitializeComponent();
        AdblockToggle.IsChecked = _adblockEnabled;
        Title = "Xanh Browser";
        Closed += MainWindow_Closed;
        Activated += MainWindow_Activated;
        BrowserTabs.Loaded += BrowserTabs_Loaded;
        BrowserTabs.SelectionChanged += BrowserTabs_SelectionChanged;
        _vaultTimer.Tick += VaultTimer_Tick;
        _vaultTimer.Start();
    }

    public async void HandleFirefoxSyncCallback(Uri callback)
    {
        if (_isClosing) return;
        if (BrowserTabs.XamlRoot is null)
        {
            _pendingSyncCallback = callback;
            return;
        }
        try
        {
            if (!await EnsureFirefoxSyncAsync(showConfiguration: false))
                throw new InvalidOperationException("Firefox Sync is not configured on this device.");
            var coordinator = _sync!;
            await coordinator.CompleteOAuthAsync(callback);
            if (_isClosing) return;
            await PublishLocalTabsAsync();
            UpdateFirefoxSyncUi(coordinator.Snapshot);
            await ShowMessageAsync("Firefox Sync", "Sign-in completed and the first sync was requested.");
        }
        catch (Exception error)
        {
            if (_isClosing) return;
            await ShowMessageAsync("Firefox Sync sign-in failed", error.Message);
        }
    }

    private async void BrowserTabs_Loaded(object sender, RoutedEventArgs e)
    {
        if (_adblockEnabled)
        {
            await EnsureAdblockAsync();
        }
        if (!_isClosing && BrowserTabs.TabItems.Count == 0)
        {
            // Do not let the first navigation outrun the default-on native matcher.
            AddTab(isPrivate: false);
        }
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

    private async void AdblockToggle_Click(object sender, RoutedEventArgs e)
    {
        _adblockEnabled = AdblockToggle.IsChecked == true;
        ApplicationData.Current.LocalSettings.Values[AdblockPreference.StorageKey] = _adblockEnabled;
        if (_adblockEnabled)
        {
            await EnsureAdblockAsync();
        }
    }

    private async Task EnsureAdblockAsync()
    {
        if (_isClosing || _adblockEngine is not null || _adblockInitializationAttempted)
        {
            return;
        }
        _adblockInitializationAttempted = true;

        // The native baseline is tiny and local. Resolve it synchronously so no tab-creation
        // event can run while this method is suspended and outrun the default-on matcher.
        _adblockEngine = NativeAdblockEngine.TryCreate(AppContext.BaseDirectory)
            ?? BaselineAdblockEngine.Instance;
        await Task.CompletedTask;
    }

    private IAdblockEngine? CurrentAdblockEngine() =>
        _adblockEnabled ? _adblockEngine : null;

    private async void FirefoxSync_Click(object sender, RoutedEventArgs e)
    {
        if (_isClosing) return;
        var oauthStarted = false;
        try
        {
            if (!await EnsureFirefoxSyncAsync(showConfiguration: true)) return;
            if (_isClosing || _sync is null) return;
            var coordinator = _sync;
            if (coordinator.Snapshot.AccountState == FirefoxAccountState.Connected)
            {
                await SyncCurrentTabsAsync(FirefoxSyncReason.Manual);
                if (!_isClosing) UpdateFirefoxSyncUi(coordinator.Snapshot);
                return;
            }
            if (coordinator.Snapshot.AccountState == FirefoxAccountState.Authenticating)
            {
                await ShowMessageAsync("Firefox Sync", "Finish sign-in in the system browser.");
                return;
            }

            if (!await ConfirmAccountOriginAsync(coordinator.AccountOrigin)) return;
            if (_isClosing) return;
            WindowsFirefoxSyncConfiguration.EnsureProtocolRegistration();
            var launch = await coordinator.BeginOAuthAsync();
            oauthStarted = true;
            if (_isClosing) return;
            if (!await Launcher.LaunchUriAsync(launch.AuthorizationUri))
                throw new InvalidOperationException("Windows could not open the system browser.");
            UpdateFirefoxSyncUi(coordinator.Snapshot);
        }
        catch (Exception error)
        {
            if (_isClosing) return;
            Exception displayError = error;
            if (oauthStarted && _sync is not null)
            {
                try { await _sync.AbandonOAuthAsync(); }
                catch (Exception cleanupError)
                {
                    displayError = new AggregateException(error, cleanupError);
                }
            }
            await ShowMessageAsync("Firefox Sync failed", displayError.Message);
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
                if (_isClosing)
                {
                    coordinator.SnapshotChanged -= Sync_SnapshotChanged;
                    await coordinator.DisposeAsync();
                    return false;
                }
                _sync = coordinator;
                if (coordinator.Snapshot.AccountState == FirefoxAccountState.Connected)
                    await SyncCurrentTabsAsync(FirefoxSyncReason.Startup);
                UpdateFirefoxSyncUi(coordinator.Snapshot);
            }
            catch
            {
                coordinator.SnapshotChanged -= Sync_SnapshotChanged;
                await coordinator.DisposeAsync();
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

    private async Task<bool> ConfirmAccountOriginAsync(string origin)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = BrowserTabs.XamlRoot,
            Title = "Open Firefox Accounts?",
            Content = $"Xanh Browser will open the system browser and continue sign-in at {origin}. TLS errors cannot be bypassed.",
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
        var passwordLibrary = new Button
        {
            Content = "Passwords for current site",
            IsEnabled = SelectedBrowser()?.CurrentCredentialContext() is not null,
        };
        var remoteTabs = new Button { Content = "Show remote tabs" };
        var disconnect = new Button { Content = "Disconnect" };
        var detail = new TextBlock { Text = snapshot.Detail, TextWrapping = TextWrapping.Wrap };
        var disconnectRequested = false;
        var remoteTabsRequested = false;
        var passwordLibraryRequested = false;
        var content = new StackPanel { Spacing = 8, MinWidth = 360 };
        content.Children.Add(detail);
        foreach (var control in new Control[]
        {
            bookmarks, history, tabs, passwords, vault, passwordLibrary, remoteTabs, disconnect,
        })
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
        remoteTabs.Click += (_, _) =>
        {
            remoteTabsRequested = true;
            dialog.Hide();
        };
        passwordLibrary.Click += (_, _) =>
        {
            passwordLibraryRequested = true;
            dialog.Hide();
        };
        disconnect.Click += (_, _) =>
        {
            disconnectRequested = true;
            dialog.Hide();
        };
        await dialog.ShowAsync();
        if (passwordLibraryRequested)
        {
            await ShowPasswordsLibraryAsync(coordinator);
            return;
        }
        if (remoteTabsRequested)
        {
            await ShowRemoteTabsLibraryAsync(coordinator);
            return;
        }
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

    private async Task ShowRemoteTabsLibraryAsync(FirefoxSyncCoordinator coordinator)
    {
        var devices = await coordinator.RemoteTabsAsync();
        var groups = new StackPanel { Spacing = 14, MinWidth = 560 };
        var tabOpened = false;
        var dialog = new ContentDialog
        {
            XamlRoot = BrowserTabs.XamlRoot,
            Title = "Tabs from other devices",
            Content = new ScrollViewer
            {
                Content = groups,
                MaxHeight = 480,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            },
            CloseButtonText = "Done",
        };

        if (devices.Count == 0)
        {
            groups.Children.Add(new TextBlock
            {
                Text = "No remote devices are available. Receiving Sync data never opens a tab automatically.",
                TextWrapping = TextWrapping.Wrap,
            });
        }
        foreach (var device in devices)
        {
            var modified = device.LastModifiedEpochMillis == 0
                ? "last update unavailable"
                : $"updated {DateTimeOffset.FromUnixTimeMilliseconds(
                    device.LastModifiedEpochMillis).ToLocalTime():g}";
            groups.Children.Add(new TextBlock
            {
                Text = $"{device.DisplayName} · {RemoteDeviceKindLabel(device.Kind)} · {modified}",
                TextWrapping = TextWrapping.Wrap,
                FontSize = 16,
            });
            foreach (var remoteTab in device.Tabs)
            {
                var uri = remoteTab.PrimaryUri!;
                var lastUsed = remoteTab.LastUsedEpochMillis == 0
                    ? "last used time unavailable"
                    : DateTimeOffset.FromUnixTimeMilliseconds(remoteTab.LastUsedEpochMillis)
                        .ToLocalTime().ToString("g");
                var text = new StackPanel { Spacing = 2 };
                text.Children.Add(new TextBlock
                {
                    Text = remoteTab.IsPinned
                        ? $"Pinned · {remoteTab.DisplayTitle}"
                        : remoteTab.DisplayTitle,
                    TextWrapping = TextWrapping.Wrap,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    MaxLines = 2,
                });
                text.Children.Add(new TextBlock
                {
                    Text = $"{uri.AbsoluteUri}\n{lastUsed}",
                    TextWrapping = TextWrapping.Wrap,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    MaxLines = 3,
                    Opacity = 0.72,
                });
                var open = new Button
                {
                    Content = text,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Stretch,
                };
                open.Click += (_, _) =>
                {
                    if (tabOpened) return;
                    tabOpened = true;
                    groups.IsHitTestVisible = false;
                    AddTab(isPrivate: false, initialUri: uri);
                    dialog.Hide();
                };
                groups.Children.Add(open);
            }
        }
        await dialog.ShowAsync();
    }

    private static string RemoteDeviceKindLabel(FirefoxRemoteDeviceKind kind) => kind switch
    {
        FirefoxRemoteDeviceKind.Desktop => "Desktop",
        FirefoxRemoteDeviceKind.Mobile => "Mobile",
        FirefoxRemoteDeviceKind.Tablet => "Tablet",
        FirefoxRemoteDeviceKind.Tv => "TV",
        FirefoxRemoteDeviceKind.Vr => "VR",
        _ => "Unknown device type",
    };

    private void Sync_SnapshotChanged(object? sender, FirefoxSyncHostSnapshot snapshot) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_isClosing) return;
            if (!snapshot.VaultUnlocked) DismissCredentialDialog();
            UpdateFirefoxSyncUi(snapshot);
        });

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
            if (!_sync.Snapshot.VaultUnlocked) DismissCredentialDialog();
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
        var deactivated = args.WindowActivationState == WindowActivationState.Deactivated;
        var leftForeground = deactivated && !_userPresenceInProgress;
        if (deactivated)
            _credentialSurfaceForeground = false;
        if (leftForeground)
        {
            DismissCredentialDialog();
        }
        else if (args.WindowActivationState != WindowActivationState.Deactivated)
        {
            _credentialSurfaceForeground = true;
        }
        if (_sync is null) return;
        try
        {
            if (leftForeground)
            {
                await _sync.LockVaultAsync();
            }
            else if (args.WindowActivationState != WindowActivationState.Deactivated)
            {
                if (_sync.Snapshot.AccountState == FirefoxAccountState.Connected)
                    await SyncCurrentTabsAsync(FirefoxSyncReason.Startup);
            }
        }
        catch { FirefoxSyncStatus.Text = "Firefox Sync foreground handling needs attention"; }
    }

    private void BrowserTabs_AddTabButtonClick(TabView sender, object args) => AddTab(isPrivate: false);

    private void BrowserTabs_SelectionChanged(object sender, SelectionChangedEventArgs args) =>
        DismissCredentialDialog();

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
        var browser = new BrowserTab(
            isPrivate,
            initialUri,
            ShowCredentialPickerAsync,
            CurrentAdblockEngine);
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
            actions.IsHitTestVisible = false;
            try
            {
                await coordinator.RenameBookmarkAsync(selected.Guid, title.Text, isPrivate: false);
                await ReloadAsync("Bookmark renamed. The next Sync will publish the exact GUID update.");
            }
            catch (Exception error) { status.Text = error.Message; }
            finally
            {
                operationRunning = false;
                actions.IsHitTestVisible = true;
            }
        };
        delete.Click += async (_, _) =>
        {
            var selected = SelectedRecord();
            if (operationRunning || selected is null) return;
            operationRunning = true;
            actions.IsHitTestVisible = false;
            try
            {
                var deleted = await coordinator.DeleteBookmarkAsync(selected.Guid, isPrivate: false);
                await ReloadAsync(deleted ? "Bookmark deleted by exact GUID." : "Bookmark no longer exists.");
            }
            catch (Exception error) { status.Text = error.Message; }
            finally
            {
                operationRunning = false;
                actions.IsHitTestVisible = true;
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
            actions.IsHitTestVisible = false;
            try
            {
                await coordinator.DeleteHistoryVisitAsync(uri, selected.VisitedAtEpochMillis);
                await ReloadAsync("The selected URL/timestamp visit was deleted.");
            }
            catch (Exception error) { status.Text = error.Message; }
            finally
            {
                operationRunning = false;
                actions.IsHitTestVisible = true;
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
        var state = CurrentCredentialState();
        if (_credentialDialogOpen || _credentialLibraryOpen
            || context.IsPrivate || !context.IsAllowed
            || state is null || state.Value.Context != context)
            return null;
        var expectedState = state.Value;
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
            if (CurrentCredentialState() != expectedState) return null;
            var credentials = await _sync.CredentialsAsync(context);
            if (credentials.Count == 0 || CurrentCredentialState() != expectedState) return null;
            var labels = credentials
                .Select(record => record.DisplayUsername)
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
            _activeCredentialDialog = dialog;
            if (await dialog.ShowAsync() != ContentDialogResult.Primary
                || list.SelectedIndex < 0
                || list.SelectedIndex >= credentials.Count
                || CurrentCredentialState() != expectedState)
                return null;
            var selected = credentials[list.SelectedIndex];
            await _sync.TouchCredentialAsync(selected.Id, context);
            return CurrentCredentialState() == expectedState ? selected : null;
        }
        finally
        {
            _activeCredentialDialog = null;
            _credentialDialogOpen = false;
        }
    }

    private async Task ShowPasswordsLibraryAsync(FirefoxSyncCoordinator coordinator)
    {
        var initialState = CurrentCredentialState();
        if (initialState is null)
        {
            await ShowMessageAsync(
                "Passwords unavailable",
                "Select a regular HTTPS page before opening its password library.");
            return;
        }
        var browser = initialState.Value.Browser;
        if (_credentialDialogOpen || _credentialLibraryOpen) return;

        _credentialLibraryOpen = true;
        void ContextChanged(object? sender, EventArgs args) => DismissCredentialDialog();
        browser.CredentialContextChanged += ContextChanged;
        try
        {
            if (!coordinator.Snapshot.VaultUnlocked)
            {
                _userPresenceInProgress = true;
                try
                {
                    if (!await coordinator.UnlockVaultAsync()) return;
                }
                finally { _userPresenceInProgress = false; }
            }
            if (CurrentCredentialState(browser) != initialState.Value) return;

            string? detail = null;
            while (true)
            {
                var state = CurrentCredentialState(browser);
                if (state is null) return;
                var context = state.Value.Context;
                IReadOnlyList<FirefoxCredentialRecord> credentials;
                try
                {
                    credentials = await coordinator.CredentialsAsync(context);
                }
                catch (Exception)
                {
                    if (CurrentCredentialState(browser) is null) return;
                    await ShowMessageAsync(
                        "Passwords unavailable",
                        "The vault or native Logins library rejected the request.");
                    return;
                }
                if (CurrentCredentialState(browser) != state.Value) return;

                var list = new ListView
                {
                    ItemsSource = credentials.Select(record => record.DisplayUsername).ToArray(),
                    SelectionMode = ListViewSelectionMode.Single,
                    SelectedIndex = credentials.Count == 0 ? -1 : 0,
                    MaxHeight = 360,
                    MinWidth = 440,
                };
                var add = new Button { Content = "Add password" };
                var edit = new Button
                {
                    Content = "Edit selected",
                    IsEnabled = credentials.Count > 0,
                };
                var delete = new Button
                {
                    Content = "Delete selected",
                    IsEnabled = credentials.Count > 0,
                };
                var status = new TextBlock
                {
                    Text = detail ?? (credentials.Count == 0
                        ? "No saved passwords for this exact HTTPS origin."
                        : $"{credentials.Count} saved login(s) for this exact HTTPS origin."),
                    TextWrapping = TextWrapping.Wrap,
                };
                var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                actions.Children.Add(add);
                actions.Children.Add(edit);
                actions.Children.Add(delete);
                var content = new StackPanel { Spacing = 8 };
                content.Children.Add(new TextBlock
                {
                    Text = $"Exact origin: {context.CanonicalTopFrameOrigin}",
                    TextWrapping = TextWrapping.Wrap,
                });
                content.Children.Add(list);
                content.Children.Add(actions);
                content.Children.Add(status);
                var dialog = new ContentDialog
                {
                    XamlRoot = BrowserTabs.XamlRoot,
                    Title = "Firefox Sync passwords",
                    Content = content,
                    CloseButtonText = "Done",
                };
                var action = CredentialLibraryAction.None;
                FirefoxCredentialRecord? SelectedRecord() => list.SelectedIndex is >= 0
                    && list.SelectedIndex < credentials.Count
                        ? credentials[list.SelectedIndex]
                        : null;
                list.SelectionChanged += (_, _) =>
                {
                    var selected = SelectedRecord() is not null;
                    edit.IsEnabled = selected;
                    delete.IsEnabled = selected;
                };
                add.Click += (_, _) =>
                {
                    action = CredentialLibraryAction.Add;
                    dialog.Hide();
                };
                edit.Click += (_, _) =>
                {
                    if (SelectedRecord() is null) return;
                    action = CredentialLibraryAction.Edit;
                    dialog.Hide();
                };
                delete.Click += (_, _) =>
                {
                    if (SelectedRecord() is null) return;
                    action = CredentialLibraryAction.Delete;
                    dialog.Hide();
                };

                _activeCredentialDialog = dialog;
                await dialog.ShowAsync();
                if (ReferenceEquals(_activeCredentialDialog, dialog))
                    _activeCredentialDialog = null;
                if (action == CredentialLibraryAction.None) return;
                var selectedRecord = SelectedRecord();
                if (CurrentCredentialState(browser) != state.Value) return;

                try
                {
                    switch (action)
                    {
                        case CredentialLibraryAction.Add:
                        {
                            var draft = await PromptCredentialDraftAsync(
                                state.Value,
                                record: null);
                            if (draft is null) break;
                            if (CurrentCredentialState(browser) != state.Value) return;
                            _ = await coordinator.AddCredentialAsync(context, draft);
                            if (CurrentCredentialState(browser) != state.Value) return;
                            detail = "Password saved for the exact HTTPS origin.";
                            break;
                        }
                        case CredentialLibraryAction.Edit when selectedRecord is not null:
                        {
                            var draft = await PromptCredentialDraftAsync(
                                state.Value,
                                selectedRecord);
                            if (draft is null) break;
                            if (CurrentCredentialState(browser) != state.Value) return;
                            _ = await coordinator.UpdateCredentialAsync(
                                selectedRecord.Id,
                                context,
                                draft);
                            if (CurrentCredentialState(browser) != state.Value) return;
                            detail = "Password updated by exact login ID.";
                            break;
                        }
                        case CredentialLibraryAction.Delete when selectedRecord is not null:
                        {
                            if (!await ConfirmCredentialDeleteAsync(selectedRecord, context)) break;
                            if (CurrentCredentialState(browser) != state.Value) return;
                            var deleted = await coordinator.DeleteCredentialAsync(
                                selectedRecord.Id,
                                context);
                            if (CurrentCredentialState(browser) != state.Value) return;
                            detail = deleted
                                ? "Password deleted by exact login ID."
                                : "The selected password no longer exists.";
                            break;
                        }
                    }
                }
                catch (Exception)
                {
                    detail = "The password operation failed closed.";
                }
            }
        }
        finally
        {
            browser.CredentialContextChanged -= ContextChanged;
            _activeCredentialDialog = null;
            _credentialLibraryOpen = false;
        }
    }

    private async Task<FirefoxCredentialDraft?> PromptCredentialDraftAsync(
        CredentialContextState state,
        FirefoxCredentialRecord? record)
    {
        var context = state.Context;
        var username = new TextBox
        {
            Header = "Username",
            Text = record?.Username ?? "",
            MaxLength = FirefoxCredentialPolicy.MaximumUsernameBytes,
        };
        var password = new PasswordBox
        {
            Header = "Password",
            Password = record?.Password ?? "",
            MaxLength = FirefoxCredentialPolicy.MaximumPasswordBytes,
        };
        var content = new StackPanel { Spacing = 8, MinWidth = 420 };
        content.Children.Add(new TextBlock
        {
            Text = $"This login is restricted to {context.CanonicalTopFrameOrigin}. Passwords remain masked and are never filled without a native user choice.",
            TextWrapping = TextWrapping.Wrap,
        });
        content.Children.Add(username);
        content.Children.Add(password);
        var dialog = new ContentDialog
        {
            XamlRoot = BrowserTabs.XamlRoot,
            Title = record is null ? "Add password" : "Edit password",
            Content = content,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        _activeCredentialDialog = dialog;
        var result = await dialog.ShowAsync();
        if (ReferenceEquals(_activeCredentialDialog, dialog)) _activeCredentialDialog = null;
        if (result != ContentDialogResult.Primary
            || CurrentCredentialState(state.Browser) != state)
            return null;
        var draft = new FirefoxCredentialDraft(
            username.Text,
            password.Password,
            record?.UsernameField ?? "",
            record?.PasswordField ?? "");
        return draft.IsAllowedFor(context)
            ? draft
            : throw new ArgumentException("The credential fields exceed the shared policy.");
    }

    private async Task<bool> ConfirmCredentialDeleteAsync(
        FirefoxCredentialRecord record,
        CredentialAccessContext context)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = BrowserTabs.XamlRoot,
            Title = "Delete this saved password?",
            Content = $"Delete {record.DisplayUsername} by its exact native login ID from {context.CanonicalTopFrameOrigin}?",
            PrimaryButtonText = "Delete password",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        _activeCredentialDialog = dialog;
        var result = await dialog.ShowAsync();
        if (ReferenceEquals(_activeCredentialDialog, dialog)) _activeCredentialDialog = null;
        return result == ContentDialogResult.Primary;
    }

    private CredentialContextState? CurrentCredentialState(BrowserTab? expected = null)
    {
        if (!_credentialSurfaceForeground) return null;
        var selected = SelectedBrowser();
        if (selected is null || expected is not null && !ReferenceEquals(selected, expected))
            return null;
        var context = selected.CurrentCredentialContext();
        return context is null
            ? null
            : new CredentialContextState(
                selected,
                selected.CredentialContextGeneration,
                context);
    }

    private CredentialAccessContext? CurrentCredentialContext() =>
        CurrentCredentialState()?.Context;

    private void DismissCredentialDialog()
    {
        try { _activeCredentialDialog?.Hide(); }
        catch (Exception) { }
        _activeCredentialDialog = null;
    }

    private enum CredentialLibraryAction { None, Add, Edit, Delete }

    private readonly record struct CredentialContextState(
        BrowserTab Browser,
        long Generation,
        CredentialAccessContext Context);

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
        if (_isClosing || BrowserTabs.XamlRoot is null) return;
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
                CurrentAdblockEngine,
                automaticRecoveryUsed: true);
            browser.Dispose();
            tab.Content = replacement;
            AttachBrowser(tab, replacement);
        };
        browser.PageVisited += Browser_PageVisited;
        browser.CredentialContextChanged += (_, _) =>
        {
            if (ReferenceEquals(SelectedBrowser(), browser)) DismissCredentialDialog();
        };
    }

    private async void MainWindow_Closed(object sender, WindowEventArgs args)
    {
        _isClosing = true;
        _vaultTimer.Stop();
        DismissCredentialDialog();
        var coordinator = _sync;
        _sync = null;
        if (coordinator is not null)
        {
            coordinator.SnapshotChanged -= Sync_SnapshotChanged;
        }
        foreach (var item in BrowserTabs.TabItems.OfType<TabViewItem>())
        {
            (item.Content as BrowserTab)?.Dispose();
        }
        _adblockEngine?.Dispose();
        _adblockEngine = null;
        if (coordinator is not null) await coordinator.DisposeAsync();
    }
}
