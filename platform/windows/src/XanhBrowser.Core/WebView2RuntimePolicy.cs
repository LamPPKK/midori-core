using System.Globalization;

namespace XanhBrowser.Core;

public static class WebView2RuntimePolicy
{
    public const string MinimumVersion = "151.0.4129.50";

    private static readonly int[] MinimumComponents = ParseMinimumVersion();

    public static bool IsSupported(string? browserVersionString)
    {
        if (!TryParseStableVersion(browserVersionString, out var actual))
        {
            return false;
        }

        for (var index = 0; index < MinimumComponents.Length; index++)
        {
            if (actual[index] != MinimumComponents[index])
            {
                return actual[index] > MinimumComponents[index];
            }
        }

        return true;
    }

    internal static bool TryParseStableVersion(string? value, out int[] components)
    {
        components = [];
        if (string.IsNullOrEmpty(value) || value.Length > 64)
        {
            return false;
        }

        var parts = value.Split('.');
        if (parts.Length != 4)
        {
            return false;
        }

        var parsed = new int[4];
        for (var index = 0; index < parts.Length; index++)
        {
            var part = parts[index];
            if (part.Length == 0
                || (part.Length > 1 && part[0] == '0')
                || part.Any(character => character is < '0' or > '9')
                || !int.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out parsed[index]))
            {
                return false;
            }
        }

        components = parsed;
        return true;
    }

    private static int[] ParseMinimumVersion()
    {
        if (!TryParseStableVersion(MinimumVersion, out var components))
        {
            throw new InvalidOperationException("The WebView2 minimum version is invalid.");
        }

        return components;
    }
}
