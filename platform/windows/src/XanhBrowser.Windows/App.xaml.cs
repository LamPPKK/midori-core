using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using ProtocolActivatedEventArgs = Windows.ApplicationModel.Activation.ProtocolActivatedEventArgs;

namespace XanhBrowser.Windows;

public partial class App : Application
{
    private Window? _window;
    private AppInstance? _mainInstance;

    public App()
    {
        InitializeComponent();
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        var main = AppInstance.FindOrRegisterForKey("io.github.lamppkk.xanhbrowser.main");
        if (!main.IsCurrent)
        {
            await main.RedirectActivationToAsync(activation);
            Exit();
            return;
        }

        _mainInstance = main;
        _mainInstance.Activated += MainInstance_Activated;
        var window = new MainWindow();
        _window = window;
        _window.Activate();
        if (ProtocolUri(activation) is { } callback)
            window.HandleFirefoxSyncCallback(callback);
    }

    private void MainInstance_Activated(object? sender, AppActivationArguments args)
    {
        if (ProtocolUri(args) is not { } callback || _window is not MainWindow window) return;
        window.DispatcherQueue.TryEnqueue(() =>
        {
            window.Activate();
            window.HandleFirefoxSyncCallback(callback);
        });
    }

    private static Uri? ProtocolUri(AppActivationArguments args) =>
        args.Kind == ExtendedActivationKind.Protocol
        && args.Data is ProtocolActivatedEventArgs protocol
            ? protocol.Uri
            : null;

}
