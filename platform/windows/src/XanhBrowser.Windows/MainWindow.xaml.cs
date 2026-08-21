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
    private readonly SemaphoreSlim _syncInitialization = new(1, 1);
    private readonly DispatcherTimer _vaultTimer = new() { Interval = TimeSpan.FromSeconds(30) };
    private Uri? _pendingSyncCallback;

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
                await _sync.SyncAsync(FirefoxSyncReason.Manual);
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
                    await coordinator.SyncAsync(FirefoxSyncReason.Startup);
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
                else if (!await coordinator.UnlockVaultAsync())
                    detail.Text = "Windows Hello or PIN verification was not completed.";
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

    private async void VaultTimer_Tick(object? sender, object e)
    {
        if (_sync is null) return;
        try
        {
            await _sync.LockVaultIfIdleAsync();
            if (_sync.Snapshot.AccountState == FirefoxAccountState.Connected)
                await _sync.SyncAsync(FirefoxSyncReason.Scheduled);
        }
        catch { FirefoxSyncStatus.Text = "Firefox Sync scheduling needs attention"; }
    }

    private async void MainWindow_Activated(object sender, WindowActivatedEventArgs args)
    {
        if (_sync is null) return;
        try
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated)
                await _sync.LockVaultAsync();
            else if (_sync.Snapshot.AccountState == FirefoxAccountState.Connected)
                await _sync.SyncAsync(FirefoxSyncReason.Startup);
        }
        catch { FirefoxSyncStatus.Text = "Firefox Sync foreground handling needs attention"; }
    }

    private void BrowserTabs_AddTabButtonClick(TabView sender, object args) => AddTab(isPrivate: false);

    private void NewPrivateTab_Click(object sender, RoutedEventArgs e) => AddTab(isPrivate: true);

    private void BrowserTabs_TabCloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs args)
    {
        if (sender.TabItems.Count <= 1)
        {
            return;
        }

        if (args.Tab is TabViewItem tab)
        {
            (tab.Content as BrowserTab)?.Dispose();
            sender.TabItems.Remove(tab);
        }
    }

    private TabViewItem AddTab(bool isPrivate, Uri? initialUri = null)
    {
        var browser = new BrowserTab(isPrivate, initialUri);
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

    private static void AttachBrowser(TabViewItem tab, BrowserTab browser)
    {
        browser.TitleChanged += (_, title) => tab.Header = string.IsNullOrWhiteSpace(title)
            ? (browser.IsPrivate ? "Private tab" : "New tab")
            : title;
        browser.BrowserProcessExited += (_, _) =>
        {
            var replacement = new BrowserTab(browser.IsPrivate, browser.CurrentUri);
            browser.Dispose();
            tab.Content = replacement;
            AttachBrowser(tab, replacement);
        };
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
