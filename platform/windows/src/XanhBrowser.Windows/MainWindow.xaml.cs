using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Security.Cryptography;
using Windows.Storage;
using Windows.Storage.Pickers;
using XanhBrowser.Core;

namespace XanhBrowser.Windows;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Title = "Xanh Browser";
        Closed += MainWindow_Closed;
        AddTab(isPrivate: false);
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
        foreach (var item in BrowserTabs.TabItems.OfType<TabViewItem>())
        {
            (item.Content as BrowserTab)?.Dispose();
        }
    }
}
