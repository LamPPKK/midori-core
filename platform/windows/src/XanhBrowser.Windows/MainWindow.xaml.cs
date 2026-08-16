using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

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

    private void AddTab(bool isPrivate)
    {
        var browser = new BrowserTab(isPrivate);
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
