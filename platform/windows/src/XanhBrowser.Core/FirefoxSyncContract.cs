namespace XanhBrowser.Core;

public enum FirefoxAccountState { Disconnected, Authenticating, Connected, AuthIssues }
public enum FirefoxSyncEngine { Bookmarks, History, Tabs, Passwords }
public enum FirefoxSyncReason { Startup, Manual, Scheduled, LocalChange, PreSleep }
public enum FirefoxSyncStatus { Idle, Running, Success, Partial, NetworkError, AuthError, BackedOff }

public sealed record FirefoxSyncConfiguration(
    Uri AccountsUri,
    Uri? TokenServerUri,
    string ClientId,
    string RedirectUri,
    string DeviceName)
{
    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(ClientId) || string.IsNullOrWhiteSpace(DeviceName))
            throw new ArgumentException("Client ID and device name are required.");
        if (!Uri.TryCreate(RedirectUri, UriKind.Absolute, out var redirect)
            || redirect.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
            || string.IsNullOrWhiteSpace(redirect.Host)
            || !string.IsNullOrEmpty(redirect.UserInfo)
            || !string.IsNullOrEmpty(redirect.Fragment))
            throw new ArgumentException(
                "Redirect URI must be an absolute non-cleartext callback without userinfo or a fragment.");
        RequireHttpsOrigin(AccountsUri, nameof(AccountsUri));
        if (TokenServerUri is not null) RequireHttpsOrigin(TokenServerUri, nameof(TokenServerUri));
    }

    private static void RequireHttpsOrigin(Uri uri, string name)
    {
        if (!uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            || string.IsNullOrWhiteSpace(uri.Host)
            || !string.IsNullOrEmpty(uri.UserInfo))
            throw new ArgumentException($"{name} must be an HTTPS origin without userinfo.");
    }
}

public sealed record FirefoxSyncSchedule(
    DateTimeOffset? LastSync = null,
    DateTimeOffset? NextAllowed = null,
    DateTimeOffset? LocalChange = null)
{
    public static readonly TimeSpan ForegroundInterval = TimeSpan.FromMinutes(15);
    public static readonly TimeSpan LocalChangeDebounce = TimeSpan.FromSeconds(30);

    public bool IsDue(FirefoxSyncReason reason, DateTimeOffset now)
    {
        if (NextAllowed is { } next && now < next) return false;
        return reason switch
        {
            FirefoxSyncReason.Manual or FirefoxSyncReason.PreSleep => true,
            FirefoxSyncReason.Startup or FirefoxSyncReason.Scheduled =>
                LastSync is not { } lastSync || now - lastSync >= ForegroundInterval,
            FirefoxSyncReason.LocalChange =>
                LocalChange is { } localChange && now - localChange >= LocalChangeDebounce,
            _ => false,
        };
    }
}

public sealed record CredentialAccessContext(
    Uri DocumentUri,
    Uri TopFrameOrigin,
    Uri FrameOrigin,
    bool IsPrivate,
    bool UserSelected)
{
    public bool IsAllowed => !IsPrivate
        && UserSelected
        && IsSecure(DocumentUri)
        && Origin(DocumentUri) == Origin(TopFrameOrigin)
        && Origin(TopFrameOrigin) == Origin(FrameOrigin);

    private static bool IsSecure(Uri uri) => uri.Scheme == Uri.UriSchemeHttps
        && string.IsNullOrEmpty(uri.UserInfo);

    private static string Origin(Uri uri) => $"{uri.Scheme.ToLowerInvariant()}://{uri.IdnHost.ToLowerInvariant()}:{uri.Port}";
}

public sealed class FirefoxSyncVaultSession
{
    public static readonly TimeSpan IdleTimeout = TimeSpan.FromMinutes(5);
    private DateTimeOffset? _lastActivity;

    public void Unlock(DateTimeOffset now) => _lastActivity = now;

    public bool Touch(DateTimeOffset now)
    {
        if (!IsUnlocked(now)) return false;
        _lastActivity = now;
        return true;
    }

    public bool IsUnlocked(DateTimeOffset now)
    {
        if (_lastActivity is not { } last || now - last >= IdleTimeout)
        {
            _lastActivity = null;
            return false;
        }
        return true;
    }

    public void Lock() => _lastActivity = null;
}
