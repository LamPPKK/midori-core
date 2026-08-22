using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

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
    public bool IsMozillaHosted => TokenServerUri is null;

    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(ClientId) || string.IsNullOrWhiteSpace(DeviceName))
            throw new ArgumentException("Client ID and device name are required.");
        if (!Uri.TryCreate(RedirectUri, UriKind.Absolute, out var redirect)
            || redirect.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
            || string.IsNullOrWhiteSpace(redirect.Host)
            || !string.IsNullOrEmpty(redirect.UserInfo)
            || !string.IsNullOrEmpty(redirect.Query)
            || !string.IsNullOrEmpty(redirect.Fragment))
            throw new ArgumentException(
                "Redirect URI must be an absolute non-cleartext callback without userinfo, query or fragment.");
        RequireHttpsOrigin(AccountsUri, nameof(AccountsUri));
        if (TokenServerUri is not null) RequireHttpsOrigin(TokenServerUri, nameof(TokenServerUri));
        if (IsMozillaHosted
            && !AccountsUri.GetLeftPart(UriPartial.Authority)
                .Equals("https://accounts.firefox.com", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException(
                "A custom Accounts server also requires its HTTPS Token Server URL.");
    }

    public string ToNativeJson()
    {
        Validate();
        object server = IsMozillaHosted
            ? new { kind = "mozilla" }
            : new
            {
                kind = "self-hosted",
                accounts_url = AccountsUri.AbsoluteUri.TrimEnd('/'),
                token_server_url = TokenServerUri!.AbsoluteUri,
            };
        return System.Text.Json.JsonSerializer.Serialize(new
        {
            server,
            client_id = ClientId,
            redirect_uri = RedirectUri,
            device_name = DeviceName,
            device_kind = "desktop",
        });
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
        && IsSecureOrigin(TopFrameOrigin)
        && IsSecureOrigin(FrameOrigin)
        && Origin(DocumentUri) == Origin(TopFrameOrigin)
        && Origin(TopFrameOrigin) == Origin(FrameOrigin);

    public string ToNativeJson()
    {
        if (!IsAllowed) throw new ArgumentException("Credential context is not allowed.");
        return JsonSerializer.Serialize(new
        {
            document_url = DocumentUri.AbsoluteUri,
            top_frame_origin = CanonicalOrigin(TopFrameOrigin),
            frame_origin = CanonicalOrigin(FrameOrigin),
            is_private = IsPrivate,
            user_selected = UserSelected,
        });
    }

    internal string ExpectedOrigin => CanonicalOrigin(DocumentUri);

    private static bool IsSecure(Uri uri) => uri.IsAbsoluteUri
        && uri.Scheme == Uri.UriSchemeHttps
        && string.IsNullOrEmpty(uri.UserInfo)
        && Encoding.UTF8.GetByteCount(uri.AbsoluteUri) <= 8_192;

    private static bool IsSecureOrigin(Uri uri) => IsSecure(uri)
        && uri.AbsolutePath == "/"
        && string.IsNullOrEmpty(uri.Query)
        && string.IsNullOrEmpty(uri.Fragment);

    private static string Origin(Uri uri) => $"{uri.Scheme.ToLowerInvariant()}://{uri.IdnHost.ToLowerInvariant()}:{uri.Port}";

    private static string CanonicalOrigin(Uri uri)
    {
        var builder = new UriBuilder(Uri.UriSchemeHttps, uri.IdnHost.ToLowerInvariant())
        {
            Port = uri.IsDefaultPort ? -1 : uri.Port,
        };
        return builder.Uri.GetLeftPart(UriPartial.Authority);
    }
}

public sealed record FirefoxCredentialRecord(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("origin")] string Origin,
    [property: JsonPropertyName("form_action_origin")] string FormActionOrigin,
    [property: JsonPropertyName("username_field")] string UsernameField,
    [property: JsonPropertyName("password_field")] string PasswordField,
    [property: JsonPropertyName("username")] string Username,
    [property: JsonPropertyName("password")] string Password,
    [property: JsonPropertyName("time_created_epoch_millis")] long TimeCreatedEpochMillis,
    [property: JsonPropertyName("time_password_changed_epoch_millis")] long TimePasswordChangedEpochMillis,
    [property: JsonPropertyName("time_last_used_epoch_millis")] long TimeLastUsedEpochMillis,
    [property: JsonPropertyName("times_used")] long TimesUsed)
{
    public bool IsAllowedFor(CredentialAccessContext context)
    {
        if (!context.IsAllowed
            || !Uri.TryCreate(Origin, UriKind.Absolute, out var storedOrigin)
            || !Uri.TryCreate(FormActionOrigin, UriKind.Absolute, out var actionOrigin))
            return false;
        var expected = context.ExpectedOrigin;
        return IsSecureOrigin(storedOrigin, expected)
            && IsSecureOrigin(actionOrigin, expected)
            && Encoding.UTF8.GetByteCount(Id) is > 0 and <= 128
            && Id.All(character => character is >= 'a' and <= 'z'
                or >= 'A' and <= 'Z'
                or >= '0' and <= '9'
                or '-' or '_')
            && Encoding.UTF8.GetByteCount(Username) <= 1_024
            && Encoding.UTF8.GetByteCount(Password) is > 0 and <= 4_096
            && ValidField(UsernameField)
            && ValidField(PasswordField)
            && TimeCreatedEpochMillis >= 0
            && TimePasswordChangedEpochMillis >= 0
            && TimeLastUsedEpochMillis >= 0
            && TimesUsed >= 0;
    }

    private static bool IsSecureOrigin(Uri value, string expected) =>
        value.IsAbsoluteUri
        && value.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
        && string.IsNullOrEmpty(value.UserInfo)
        && value.AbsolutePath == "/"
        && string.IsNullOrEmpty(value.Query)
        && string.IsNullOrEmpty(value.Fragment)
        && value.GetLeftPart(UriPartial.Authority).Equals(expected, StringComparison.OrdinalIgnoreCase);

    private static bool ValidField(string value) => Encoding.UTF8.GetByteCount(value) <= 256
        && !value.Any(char.IsControl);
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
