using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using Microsoft.Windows.AppLifecycle;
using Windows.Storage;
using XanhBrowser.Core;

namespace XanhBrowser.Windows;

internal static class WindowsFirefoxSyncConfiguration
{
    private const string SettingsKey = "FirefoxSyncPublicConfiguration";
    public const string RedirectUri = "xanh-browser-windows://accounts/oauth";

    public static FirefoxSyncConfiguration? Load()
    {
        var approved = Environment.GetEnvironmentVariable("XANH_FXA_PRODUCTION_APPROVED") == "1"
            || BuildMetadata("XanhFxaProductionApproved") == "1";
        var clientId = Environment.GetEnvironmentVariable("XANH_FXA_CLIENT_ID");
        if (string.IsNullOrWhiteSpace(clientId))
            clientId = BuildMetadata("XanhFxaClientId");
        if (approved && !string.IsNullOrWhiteSpace(clientId))
            return new(
                new Uri("https://accounts.firefox.com"),
                null,
                clientId,
                RedirectUri,
                Environment.MachineName);

        var value = ApplicationData.Current.LocalSettings.Values[SettingsKey] as string;
        if (string.IsNullOrWhiteSpace(value)) return null;
        try
        {
            var stored = JsonSerializer.Deserialize<StoredConfiguration>(value);
            if (stored is null) return null;
            var configuration = new FirefoxSyncConfiguration(
                new Uri(stored.AccountsUrl),
                new Uri(stored.TokenServerUrl),
                stored.ClientId,
                RedirectUri,
                Environment.MachineName);
            configuration.Validate();
            return configuration;
        }
        catch (Exception error) when (error is JsonException or UriFormatException or ArgumentException)
        {
            ApplicationData.Current.LocalSettings.Values.Remove(SettingsKey);
            return null;
        }
    }

    public static void SaveSelfHosted(FirefoxSyncConfiguration configuration)
    {
        configuration.Validate();
        if (configuration.IsMozillaHosted)
            throw new ArgumentException("Only an approved build may configure Mozilla-hosted Accounts.");
        var stored = new StoredConfiguration(
            configuration.AccountsUri.AbsoluteUri,
            configuration.TokenServerUri!.AbsoluteUri,
            configuration.ClientId);
        ApplicationData.Current.LocalSettings.Values[SettingsKey] = JsonSerializer.Serialize(stored);
    }

    public static string ProfileDirectory => Path.Combine(
        ApplicationData.Current.LocalFolder.Path, "FirefoxSync", "Profile");

    public static void EnsureProtocolRegistration()
    {
        var executable = Environment.ProcessPath
            ?? Process.GetCurrentProcess().MainModule?.FileName
            ?? throw new InvalidOperationException("Cannot resolve the Xanh Browser executable path.");
        ActivationRegistrationManager.RegisterForProtocolActivation(
            "xanh-browser-windows",
            $"{executable},0",
            "Xanh Browser Firefox Sync",
            executable);
    }

    private sealed record StoredConfiguration(
        string AccountsUrl,
        string TokenServerUrl,
        string ClientId);

    private static string? BuildMetadata(string key) =>
        typeof(WindowsFirefoxSyncConfiguration).Assembly
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(value => value.Key == key)?.Value;
}
