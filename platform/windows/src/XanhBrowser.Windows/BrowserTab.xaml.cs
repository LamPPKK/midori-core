using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.Web.WebView2.Core;
using System.Text.Json;
using Windows.System;
using XanhBrowser.Core;

namespace XanhBrowser.Windows;

public sealed partial class BrowserTab : UserControl, IDisposable
{
    private readonly bool _isPrivate;
    private readonly Uri _initialUri;
    private readonly Func<CredentialAccessContext, Task<FirefoxCredentialRecord?>>? _credentialPicker;
    private readonly string _credentialTabId = Guid.NewGuid().ToString("N");
    private bool _disposed;
    private bool _permissionDialogOpen;
    private Uri _currentUri;
    private string? _credentialNonce;
    private string? _credentialScriptId;

    public event EventHandler<string>? TitleChanged;
    public event EventHandler? BrowserProcessExited;

    public bool IsPrivate => _isPrivate;
    public Uri CurrentUri => _currentUri;

    public BrowserTab(
        bool isPrivate,
        Uri? initialUri = null,
        Func<CredentialAccessContext, Task<FirefoxCredentialRecord?>>? credentialPicker = null)
    {
        _isPrivate = isPrivate;
        _credentialPicker = credentialPicker;
        _initialUri = initialUri is not null && AddressResolver.IsAllowedWebUri(initialUri)
            ? initialUri
            : AddressResolver.DefaultHomePage;
        _currentUri = _initialUri;
        InitializeComponent();
        Loaded += BrowserTab_Loaded;
    }

    private async void BrowserTab_Loaded(object sender, RoutedEventArgs e)
    {
        Loaded -= BrowserTab_Loaded;

        try
        {
            var userDataFolder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Xanh Browser",
                "WebView2");
            var environmentOptions = new CoreWebView2EnvironmentOptions
            {
                TargetCompatibleBrowserVersion = WebView2RuntimePolicy.MinimumVersion,
                ReleaseChannels = CoreWebView2ReleaseChannels.Stable,
            };
            var environment = await CoreWebView2Environment.CreateWithOptionsAsync(
                null,
                userDataFolder,
                environmentOptions);
            if (_disposed)
            {
                return;
            }
            if (!WebView2RuntimePolicy.IsSupported(environment.BrowserVersionString))
            {
                throw new NotSupportedException(
                    $"Xanh Browser requires the stable WebView2 Runtime "
                    + $"{WebView2RuntimePolicy.MinimumVersion} or newer; "
                    + $"found {environment.BrowserVersionString}.");
            }
            var controllerOptions = environment.CreateCoreWebView2ControllerOptions();
            controllerOptions.IsInPrivateModeEnabled = _isPrivate;
            await BrowserWebView.EnsureCoreWebView2Async(environment, controllerOptions);
            if (_disposed)
            {
                BrowserWebView.Close();
                return;
            }
            if (_credentialPicker is not null && !_isPrivate)
            {
                _credentialScriptId = await BrowserWebView.CoreWebView2
                    .AddScriptToExecuteOnDocumentCreatedAsync(CredentialBootstrapScript());
            }
            Navigate(_initialUri);
        }
        catch (Exception error)
        {
            AddressBox.Text = $"WebView2 failed to initialize: {error.Message}";
        }
    }

    private void BrowserWebView_CoreWebView2Initialized(
        WebView2 sender,
        CoreWebView2InitializedEventArgs args)
    {
        if (args.Exception is not null || sender.CoreWebView2 is null)
        {
            return;
        }

        var settings = sender.CoreWebView2.Settings;
        settings.AreHostObjectsAllowed = false;
        settings.IsWebMessageEnabled = _credentialPicker is not null && !_isPrivate;
        settings.IsScriptEnabled = true;
        settings.AreDefaultScriptDialogsEnabled = true;
        settings.IsGeneralAutofillEnabled = false;
        settings.IsPasswordAutosaveEnabled = false;

        sender.CoreWebView2.Profile.PreferredTrackingPreventionLevel =
            CoreWebView2TrackingPreventionLevel.Balanced;
        sender.CoreWebView2.DocumentTitleChanged += CoreWebView2_DocumentTitleChanged;
        sender.CoreWebView2.HistoryChanged += CoreWebView2_HistoryChanged;
        sender.CoreWebView2.NewWindowRequested += CoreWebView2_NewWindowRequested;
        sender.CoreWebView2.PermissionRequested += CoreWebView2_PermissionRequested;
        sender.CoreWebView2.ProcessFailed += CoreWebView2_ProcessFailed;
        sender.CoreWebView2.SourceChanged += CoreWebView2_SourceChanged;
        if (_credentialPicker is not null && !_isPrivate)
            sender.CoreWebView2.WebMessageReceived += CoreWebView2_WebMessageReceived;
    }

    private void CoreWebView2_DocumentTitleChanged(object? sender, object args)
    {
        if (sender is CoreWebView2 core)
        {
            TitleChanged?.Invoke(this, core.DocumentTitle);
        }
    }

    private void CoreWebView2_HistoryChanged(object? sender, object args) => UpdateNavigationButtons();

    private void CoreWebView2_ProcessFailed(
        object? sender,
        CoreWebView2ProcessFailedEventArgs args)
    {
        switch (args.ProcessFailedKind)
        {
            case CoreWebView2ProcessFailedKind.RenderProcessExited:
                BrowserWebView.Reload();
                break;
            case CoreWebView2ProcessFailedKind.BrowserProcessExited:
                BrowserProcessExited?.Invoke(this, EventArgs.Empty);
                break;
            case CoreWebView2ProcessFailedKind.RenderProcessUnresponsive:
                TitleChanged?.Invoke(this, "Page unresponsive");
                break;
        }
    }

    private async void CoreWebView2_NewWindowRequested(
        CoreWebView2 sender,
        CoreWebView2NewWindowRequestedEventArgs args)
    {
        args.Handled = true;
        if (!args.IsUserInitiated)
        {
            return;
        }

        if (!Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri))
        {
            return;
        }

        if (AddressResolver.IsAllowedWebUri(uri))
        {
            Navigate(uri);
        }
        else if (AddressResolver.IsAllowedExternalUri(uri))
        {
            await Launcher.LaunchUriAsync(uri);
        }
    }

    private async void CoreWebView2_PermissionRequested(
        CoreWebView2 sender,
        CoreWebView2PermissionRequestedEventArgs args)
    {
        var deferral = args.GetDeferral();
        var ownsDialog = false;
        try
        {
            args.Handled = true;
            args.SavesInProfile = false;
            if (_permissionDialogOpen
                || !args.IsUserInitiated
                || !Uri.TryCreate(args.Uri, UriKind.Absolute, out var origin)
                || !origin.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            {
                args.State = CoreWebView2PermissionState.Deny;
                return;
            }

            _permissionDialogOpen = true;
            ownsDialog = true;
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = "Website permission",
                Content = $"{origin.Host} requests {args.PermissionKind} access.",
                PrimaryButtonText = "Allow once",
                CloseButtonText = "Deny",
                DefaultButton = ContentDialogButton.Close,
            };
            var result = await dialog.ShowAsync();
            args.State = result == ContentDialogResult.Primary
                ? CoreWebView2PermissionState.Allow
                : CoreWebView2PermissionState.Deny;
        }
        finally
        {
            if (ownsDialog)
            {
                _permissionDialogOpen = false;
            }
            deferral.Complete();
        }
    }

    private async void AddressBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter)
        {
            return;
        }

        e.Handled = true;
        var target = AddressResolver.Resolve(AddressBox.Text);
        if (target?.Kind == NavigationTargetKind.Web)
        {
            Navigate(target.Uri);
        }
        else if (target?.Kind == NavigationTargetKind.External)
        {
            await Launcher.LaunchUriAsync(target.Uri);
        }
    }

    private async void BrowserWebView_NavigationStarting(
        WebView2 sender,
        CoreWebView2NavigationStartingEventArgs args)
    {
        LoadProgress.Visibility = Visibility.Visible;
        _credentialNonce = null;
        if (Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri)
            && AddressResolver.IsAllowedWebUri(uri))
        {
            return;
        }

        args.Cancel = true;
        LoadProgress.Visibility = Visibility.Collapsed;
        if (args.IsUserInitiated && AddressResolver.IsAllowedExternalUri(uri))
        {
            await Launcher.LaunchUriAsync(uri);
        }
    }

    private async void CoreWebView2_WebMessageReceived(
        CoreWebView2 sender,
        CoreWebView2WebMessageReceivedEventArgs args)
    {
        if (_disposed || _isPrivate || _credentialPicker is null
            || !Uri.TryCreate(args.Source, UriKind.Absolute, out var documentUri)
            || !documentUri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            || !string.IsNullOrEmpty(documentUri.UserInfo)
            || !Uri.TryCreate(sender.Source, UriKind.Absolute, out var currentDocument)
            || currentDocument != documentUri)
            return;

        try
        {
            var json = args.WebMessageAsJson;
            if (json.Length > 4_096) return;
            using var message = JsonDocument.Parse(json);
            var root = message.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("tabId", out var tabId)
                || tabId.GetString() != _credentialTabId
                || !root.TryGetProperty("navigationNonce", out var nonceValue)
                || nonceValue.GetString() is not { Length: > 0 and <= 128 } nonce
                || !root.TryGetProperty("messageType", out var typeValue)
                || typeValue.GetString() is not { Length: > 0 and <= 64 } messageType
                || !root.TryGetProperty("origin", out var originValue)
                || !Uri.TryCreate(originValue.GetString(), UriKind.Absolute, out var claimedOrigin))
                return;

            if (messageType == "credential-ready")
            {
                var readyContext = new CredentialAccessContext(
                    documentUri, claimedOrigin, claimedOrigin, _isPrivate, UserSelected: true);
                if (_credentialNonce is null && readyContext.IsAllowed) _credentialNonce = nonce;
                return;
            }
            if (messageType != "credential-request" || _credentialNonce != nonce) return;

            var context = new CredentialAccessContext(
                documentUri, claimedOrigin, claimedOrigin, _isPrivate, UserSelected: true);
            if (!context.IsAllowed) return;
            var selected = await _credentialPicker(context);
            if (selected is null || _disposed || _credentialNonce != nonce
                || !Uri.TryCreate(sender.Source, UriKind.Absolute, out var latestDocument)
                || latestDocument != documentUri)
                return;
            sender.PostWebMessageAsJson(JsonSerializer.Serialize(new
            {
                type = "credential-selected",
                tabId = _credentialTabId,
                navigationNonce = nonce,
                username = selected.Username,
                password = selected.Password,
            }));
        }
        catch (JsonException)
        {
            // Malformed renderer messages are ignored and never reach native Sync.
        }
        catch (Exception)
        {
            // Credential UI/native-runtime failures are fail-closed for the page.
        }
    }

    private string CredentialBootstrapScript() => $$"""
        (() => {
          if (window.top !== window || location.protocol !== 'https:' || !window.chrome?.webview) return;
          const tabId = '{{_credentialTabId}}';
          const navigationNonce = crypto.randomUUID();
          let requestedFor = null;
          let userGestureDeadline = 0;
          const post = messageType => window.chrome.webview.postMessage({
            tabId,
            navigationNonce,
            messageType,
            origin: location.origin
          });
          const requestCredential = target => {
            if (!(target instanceof HTMLInputElement) || target.type !== 'password') return;
            if (performance.now() > userGestureDeadline) return;
            userGestureDeadline = 0;
            requestedFor = target;
            post('credential-request');
          };
          post('credential-ready');
          document.addEventListener('pointerdown', event => {
            if (!event.isTrusted) return;
            userGestureDeadline = performance.now() + 1500;
            requestCredential(event.target);
          }, true);
          document.addEventListener('keydown', event => {
            if (event.isTrusted) userGestureDeadline = performance.now() + 1500;
          }, true);
          document.addEventListener('focusin', event => {
            if (event.isTrusted) requestCredential(event.target);
          }, true);
          window.chrome.webview.addEventListener('message', event => {
            const credential = event.data;
            if (!credential || credential.type !== 'credential-selected'
                || credential.tabId !== tabId || credential.navigationNonce !== navigationNonce) return;
            const password = requestedFor;
            if (!(password instanceof HTMLInputElement) || !password.isConnected) return;
            const root = password.form || document;
            const user = root.querySelector('input[autocomplete="username"], input[type="email"], input[type="text"]');
            if (user) {
              user.value = credential.username || '';
              user.dispatchEvent(new Event('input', { bubbles: true }));
            }
            password.value = credential.password || '';
            password.dispatchEvent(new Event('input', { bubbles: true }));
            requestedFor = null;
          });
        })();
        """;

    private void BrowserWebView_NavigationCompleted(
        WebView2 sender,
        CoreWebView2NavigationCompletedEventArgs args)
    {
        LoadProgress.Visibility = Visibility.Collapsed;
        UpdateNavigationButtons();
    }

    private void CoreWebView2_SourceChanged(CoreWebView2 sender, CoreWebView2SourceChangedEventArgs args)
    {
        if (Uri.TryCreate(sender.Source, UriKind.Absolute, out var uri)
            && AddressResolver.IsAllowedWebUri(uri))
        {
            _currentUri = uri;
            AddressBox.Text = uri.AbsoluteUri;
        }
    }

    private void BackButton_Click(object sender, RoutedEventArgs e)
    {
        if (BrowserWebView.CanGoBack)
        {
            BrowserWebView.GoBack();
        }
    }

    private void ForwardButton_Click(object sender, RoutedEventArgs e)
    {
        if (BrowserWebView.CanGoForward)
        {
            BrowserWebView.GoForward();
        }
    }

    private void ReloadButton_Click(object sender, RoutedEventArgs e) => BrowserWebView.Reload();

    private async void ClearDataButton_Click(object sender, RoutedEventArgs e)
    {
        if (BrowserWebView.CoreWebView2 is null)
        {
            return;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Clear browsing data?",
            Content = "This clears cookies, cache, permissions and other browsing data for this profile.",
            PrimaryButtonText = "Clear",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };

        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            await BrowserWebView.CoreWebView2.Profile.ClearBrowsingDataAsync(
                CoreWebView2BrowsingDataKinds.AllProfile);
            Navigate(AddressResolver.DefaultHomePage);
        }
    }

    private void Navigate(Uri uri)
    {
        if (BrowserWebView.CoreWebView2 is not null && AddressResolver.IsAllowedWebUri(uri))
        {
            BrowserWebView.CoreWebView2.Navigate(uri.AbsoluteUri);
        }
    }

    private void UpdateNavigationButtons()
    {
        BackButton.IsEnabled = BrowserWebView.CanGoBack;
        ForwardButton.IsEnabled = BrowserWebView.CanGoForward;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Loaded -= BrowserTab_Loaded;
        if (BrowserWebView.CoreWebView2 is not null)
        {
            BrowserWebView.CoreWebView2.DocumentTitleChanged -= CoreWebView2_DocumentTitleChanged;
            BrowserWebView.CoreWebView2.HistoryChanged -= CoreWebView2_HistoryChanged;
            BrowserWebView.CoreWebView2.NewWindowRequested -= CoreWebView2_NewWindowRequested;
            BrowserWebView.CoreWebView2.PermissionRequested -= CoreWebView2_PermissionRequested;
            BrowserWebView.CoreWebView2.ProcessFailed -= CoreWebView2_ProcessFailed;
            BrowserWebView.CoreWebView2.SourceChanged -= CoreWebView2_SourceChanged;
            if (_credentialPicker is not null && !_isPrivate)
                BrowserWebView.CoreWebView2.WebMessageReceived -= CoreWebView2_WebMessageReceived;
            if (_credentialScriptId is not null)
                BrowserWebView.CoreWebView2.RemoveScriptToExecuteOnDocumentCreated(_credentialScriptId);
        }
        BrowserWebView.Close();
        TitleChanged = null;
        BrowserProcessExited = null;
        GC.SuppressFinalize(this);
    }
}
