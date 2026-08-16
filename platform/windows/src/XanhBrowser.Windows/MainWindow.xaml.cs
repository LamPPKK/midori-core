using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace XanhBrowser.Windows;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Title = "Xanh Browser";
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

        sender.TabItems.Remove(args.Tab);
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

        browser.TitleChanged += (_, title) => tab.Header = string.IsNullOrWhiteSpace(title)
            ? (isPrivate ? "Private tab" : "New tab")
            : title;

        BrowserTabs.TabItems.Add(tab);
        BrowserTabs.SelectedItem = tab;
    }
}
