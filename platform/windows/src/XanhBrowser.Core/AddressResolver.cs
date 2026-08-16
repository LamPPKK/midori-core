namespace XanhBrowser.Core;

public enum NavigationTargetKind
{
    Web,
    External,
}

public sealed record NavigationTarget(NavigationTargetKind Kind, Uri Uri);

public static class AddressResolver
{
    public static readonly Uri DefaultHomePage = new("https://duckduckgo.com/");

    private static readonly HashSet<string> ExternalSchemes = new(StringComparer.OrdinalIgnoreCase)
    {
        "mailto",
        "tel",
        "sms",
        "bingmaps",
        "ms-drive-to",
        "ms-walk-to",
    };

    public static NavigationTarget? Resolve(string? input)
    {
        var value = input?.Trim();
        if (string.IsNullOrEmpty(value))
        {
            return null;
        }

        if (Uri.TryCreate(value, UriKind.Absolute, out var explicitUri))
        {
            return Classify(explicitUri);
        }

        var colonIndex = value.IndexOf(':');
        if (colonIndex > 0 && Uri.CheckSchemeName(value[..colonIndex]))
        {
            return null;
        }

        if (LooksLikeHost(value)
            && Uri.TryCreate($"https://{value}", UriKind.Absolute, out var hostUri))
        {
            return Classify(hostUri);
        }

        return new NavigationTarget(
            NavigationTargetKind.Web,
            new Uri($"https://duckduckgo.com/?q={Uri.EscapeDataString(value)}"));
    }

    public static bool IsAllowedWebUri(Uri? uri)
    {
        if (uri is null || !uri.IsAbsoluteUri)
        {
            return false;
        }

        if (uri.Scheme.Equals("about", StringComparison.OrdinalIgnoreCase))
        {
            return uri.OriginalString.Equals("about:blank", StringComparison.OrdinalIgnoreCase);
        }

        return (uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
                || uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            && !string.IsNullOrWhiteSpace(uri.IdnHost);
    }

    public static bool IsAllowedExternalUri(Uri? uri) =>
        uri is { IsAbsoluteUri: true } && ExternalSchemes.Contains(uri.Scheme);

    private static NavigationTarget? Classify(Uri uri)
    {
        if (IsAllowedWebUri(uri))
        {
            return new NavigationTarget(NavigationTargetKind.Web, uri);
        }

        return IsAllowedExternalUri(uri)
            ? new NavigationTarget(NavigationTargetKind.External, uri)
            : null;
    }

    private static bool LooksLikeHost(string value)
    {
        if (value.Any(char.IsWhiteSpace))
        {
            return false;
        }

        var slash = value.IndexOf('/');
        var candidate = slash >= 0 ? value[..slash] : value;
        return candidate.Equals("localhost", StringComparison.OrdinalIgnoreCase)
            || candidate.Contains('.', StringComparison.Ordinal);
    }
}
