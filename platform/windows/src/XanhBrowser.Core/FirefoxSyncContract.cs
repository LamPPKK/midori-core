using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace XanhBrowser.Core;

public enum FirefoxAccountState { Disconnected, Authenticating, Connected, AuthIssues }
public enum FirefoxSyncEngine { Bookmarks, History, Tabs, Passwords }
public enum FirefoxSyncReason { Startup, Manual, Scheduled, LocalChange, PreSleep }
public enum FirefoxSyncStatus { Idle, Running, Success, Partial, NetworkError, AuthError, BackedOff }
public enum FirefoxBookmarkRoot { Menu, Toolbar, Unfiled, Mobile }
public enum FirefoxHistoryTransition
{
    Link,
    Typed,
    Bookmark,
    RedirectPermanent,
    RedirectTemporary,
    Download,
    Reload,
}

public sealed record FirefoxBookmarkRecord(
    [property: JsonPropertyName("guid")] string Guid,
    [property: JsonPropertyName("parent_guid")] string? ParentGuid,
    [property: JsonPropertyName("position")] uint Position,
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("title")] string? Title,
    [property: JsonPropertyName("url")] string? Url,
    [property: JsonPropertyName("is_openable")] bool IsOpenable,
    [property: JsonPropertyName("date_added_epoch_millis")] long DateAddedEpochMillis,
    [property: JsonPropertyName("last_modified_epoch_millis")] long LastModifiedEpochMillis)
{
    public bool IsSafe => FirefoxPlacesPolicy.IsGuid(Guid)
        && (ParentGuid is null || FirefoxPlacesPolicy.IsGuid(ParentGuid))
        && Kind is "bookmark" or "folder" or "separator"
        && FirefoxPlacesPolicy.IsSafeTitle(Title)
        && FirefoxPlacesPolicy.IsSafeTimestamp(DateAddedEpochMillis, allowZero: true)
        && FirefoxPlacesPolicy.IsSafeTimestamp(LastModifiedEpochMillis, allowZero: true)
        && FirefoxPlacesPolicy.IsSafeBookmarkUrl(Kind, Url, IsOpenable);

    public Uri? OpenableUri => IsOpenable
        && Uri.TryCreate(Url, UriKind.Absolute, out var uri)
        && FirefoxPlacesPolicy.IsAllowedWebUri(uri)
            ? uri
            : null;
}

public sealed record FirefoxHistoryVisitRecord(
    [property: JsonPropertyName("url")] string Url,
    [property: JsonPropertyName("title")] string? Title,
    [property: JsonPropertyName("visited_at_epoch_millis")] long VisitedAtEpochMillis,
    [property: JsonPropertyName("transition")] string Transition,
    [property: JsonPropertyName("is_remote")] bool IsRemote)
{
    public bool IsSafe => Uri.TryCreate(Url, UriKind.Absolute, out var uri)
        && FirefoxPlacesPolicy.IsAllowedWebUri(uri)
        && FirefoxPlacesPolicy.IsSafeTitle(Title)
        && FirefoxPlacesPolicy.IsSafeTimestamp(VisitedAtEpochMillis, allowZero: false)
        && Transition is "link" or "typed" or "bookmark" or "redirect-permanent"
            or "redirect-temporary" or "download" or "reload";

    public Uri? OpenableUri => IsSafe && Uri.TryCreate(Url, UriKind.Absolute, out var uri)
        ? uri
        : null;
}

public sealed record FirefoxLocalTab(
    string Title,
    IReadOnlyList<Uri> UrlHistory,
    Uri? IconUri,
    DateTimeOffset LastUsed,
    bool IsPrivate,
    bool IsPinned = false);

public static class FirefoxPlacesPolicy
{
    private static readonly long MaximumEpochMillis = DateTimeOffset.MaxValue.ToUnixTimeMilliseconds();
    public const int MaximumTitleBytes = 4_096;
    public const int MaximumUrlBytes = 8_192;
    public const int MaximumBookmarks = 10_000;
    public const int MaximumHistoryResults = 500;
    public const int MaximumLocalTabs = 500;

    public static bool IsGuid(string? value) => value is { Length: 12 }
        && value.All(character => character is >= 'a' and <= 'z'
            or >= 'A' and <= 'Z'
            or >= '0' and <= '9'
            or '-' or '_');

    public static bool IsAllowedWebUri(Uri uri) => AddressResolver.IsAllowedWebUri(uri)
        && string.IsNullOrEmpty(uri.UserInfo)
        && Encoding.UTF8.GetByteCount(uri.AbsoluteUri) <= MaximumUrlBytes;

    public static bool IsSafeTitle(string? value) => value is null
        || Encoding.UTF8.GetByteCount(value) <= MaximumTitleBytes
        && !value.Any(char.IsControl);

    public static string SanitizeTitle(string? value, string fallback)
    {
        var candidate = string.IsNullOrWhiteSpace(value) ? fallback : value;
        var output = new StringBuilder(Math.Min(candidate.Length, MaximumTitleBytes));
        var bytes = 0;
        var pendingSpace = false;
        foreach (var rune in candidate.EnumerateRunes())
        {
            if (Rune.IsWhiteSpace(rune))
            {
                if (output.Length > 0) pendingSpace = true;
                continue;
            }
            if (Rune.IsControl(rune)) continue;
            var encodedBytes = rune.Utf8SequenceLength;
            var separatorBytes = pendingSpace ? 1 : 0;
            if (bytes + separatorBytes + encodedBytes > MaximumTitleBytes) break;
            if (pendingSpace)
            {
                output.Append(' ');
                bytes++;
            }
            output.Append(rune);
            bytes += encodedBytes;
            pendingSpace = false;
        }
        return output.Length == 0 ? "Untitled" : output.ToString();
    }

    internal static bool IsSafeBookmarkUrl(string kind, string? value, bool isOpenable)
    {
        if (kind == "separator") return value is null && !isOpenable;
        if (kind == "folder") return value is null && !isOpenable;
        if (value is null
            || Encoding.UTF8.GetByteCount(value) > MaximumUrlBytes
            || value.Any(char.IsControl))
            return false;
        if (!isOpenable) return true;
        return Uri.TryCreate(value, UriKind.Absolute, out var uri) && IsAllowedWebUri(uri);
    }

    internal static bool IsSafeTimestamp(long value, bool allowZero) =>
        value <= MaximumEpochMillis && (allowZero ? value >= 0 : value > 0);

    internal static string TransitionName(FirefoxHistoryTransition transition) => transition switch
    {
        FirefoxHistoryTransition.Link => "link",
        FirefoxHistoryTransition.Typed => "typed",
        FirefoxHistoryTransition.Bookmark => "bookmark",
        FirefoxHistoryTransition.RedirectPermanent => "redirect-permanent",
        FirefoxHistoryTransition.RedirectTemporary => "redirect-temporary",
        FirefoxHistoryTransition.Download => "download",
        FirefoxHistoryTransition.Reload => "reload",
        _ => throw new ArgumentOutOfRangeException(nameof(transition)),
    };
}

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
