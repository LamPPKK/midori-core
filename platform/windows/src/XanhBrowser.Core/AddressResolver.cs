using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

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

    private const int MaxWebUrlBytes = 8_192;
    private const int MaxExternalUrlBytes = 2_048;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly IdnMapping StrictIdn = new() { UseStd3AsciiRules = true };
    private static readonly Regex EncodedControl = new(
        "%(?:0[0-9A-Fa-f]|1[0-9A-Fa-f]|7[fF])",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

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
        if (input is null
            || input.Any(char.IsControl)
            || !IsWithinUtf8Limit(input, MaxWebUrlBytes))
        {
            return null;
        }

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

        var search = $"https://duckduckgo.com/?q={Uri.EscapeDataString(value)}";
        return IsWithinUtf8Limit(search, MaxWebUrlBytes)
            ? new NavigationTarget(NavigationTargetKind.Web, new Uri(search))
            : null;
    }

    public static bool IsAllowedWebUri(Uri? uri)
    {
        if (uri is null
            || !uri.IsAbsoluteUri
            || !IsWithinUtf8Limit(uri.OriginalString, MaxWebUrlBytes)
            || uri.OriginalString.Any(char.IsControl))
        {
            return false;
        }

        if (uri.Scheme.Equals("about", StringComparison.OrdinalIgnoreCase))
        {
            return uri.OriginalString.Equals("about:blank", StringComparison.OrdinalIgnoreCase);
        }

        if (!(uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
                || uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            || !string.IsNullOrEmpty(uri.UserInfo)
            || uri.Port is < 0 or > 65_535
            || !HasValidHost(uri))
        {
            return false;
        }

        return IsWithinUtf8Limit(uri.AbsoluteUri, MaxWebUrlBytes);
    }

    public static bool IsAllowedExternalUri(Uri? uri)
    {
        if (uri is not { IsAbsoluteUri: true }
            || !ExternalSchemes.Contains(uri.Scheme))
        {
            return false;
        }

        var value = uri.OriginalString;
        var colon = value.IndexOf(':');
        return colon > 0
            && colon < value.Length - 1
            && !value.Any(char.IsControl)
            && !value.Any(char.IsWhiteSpace)
            && !EncodedControl.IsMatch(value)
            && IsWithinUtf8Limit(value, MaxExternalUrlBytes);
    }

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

    private static bool HasValidHost(Uri uri)
    {
        if (uri.HostNameType is UriHostNameType.IPv4 or UriHostNameType.IPv6)
        {
            return true;
        }
        if (uri.HostNameType != UriHostNameType.Dns)
        {
            return false;
        }

        try
        {
            var ascii = StrictIdn.GetAscii(uri.DnsSafeHost);
            return !string.IsNullOrWhiteSpace(ascii)
                && ascii.Equals(uri.IdnHost, StringComparison.OrdinalIgnoreCase);
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    private static bool IsWithinUtf8Limit(string value, int limit)
    {
        if (value.Length > limit)
        {
            return false;
        }

        try
        {
            return StrictUtf8.GetByteCount(value) <= limit;
        }
        catch (EncoderFallbackException)
        {
            return false;
        }
    }
}
