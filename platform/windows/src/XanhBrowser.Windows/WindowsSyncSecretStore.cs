using System.Text;
using Windows.Security.Credentials.UI;
using Windows.Security.Cryptography;
using Windows.Security.Cryptography.DataProtection;
using Windows.Storage;
using XanhBrowser.Core;

namespace XanhBrowser.Windows;

/// <summary>
/// Device-local DPAPI persistence for Firefox Account state and Sync keys.
/// Password-vault access additionally requires an explicit Windows Hello/PIN
/// verification and expires after five minutes or when the host calls Lock.
/// </summary>
internal sealed class WindowsSyncSecretStore : IFirefoxSyncSecretStore
{
    public async Task<bool> VerifyUserPresenceAsync(
        string reason,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var availability = await UserConsentVerifier.CheckAvailabilityAsync();
        if (availability != UserConsentVerifierAvailability.Available) return false;
        var result = await UserConsentVerifier.RequestVerificationAsync(reason);
        cancellationToken.ThrowIfCancellationRequested();
        return result == UserConsentVerificationResult.Verified;
    }

    public Task<string?> ReadAsync(
        FirefoxSyncSecret secret,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return ReadProtectedAsync(FileName(secret), cancellationToken);
    }

    public Task WriteAsync(
        FirefoxSyncSecret secret,
        string value,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return StoreProtectedAsync(FileName(secret), value, cancellationToken);
    }

    public async Task DeleteAsync(
        FirefoxSyncSecret secret,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var folder = await GetFolderAsync();
        var file = await folder.TryGetItemAsync(FileName(secret)) as StorageFile;
        cancellationToken.ThrowIfCancellationRequested();
        if (file is not null) await file.DeleteAsync(StorageDeleteOption.PermanentDelete);
    }

    private static async Task StoreProtectedAsync(
        string name,
        string value,
        CancellationToken cancellationToken)
    {
        var clear = CryptographicBuffer.ConvertStringToBinary(value, BinaryStringEncoding.Utf8);
        var encrypted = await new DataProtectionProvider("LOCAL=user").ProtectAsync(clear);
        cancellationToken.ThrowIfCancellationRequested();
        var folder = await GetFolderAsync();
        var file = await folder.CreateFileAsync(name, CreationCollisionOption.ReplaceExisting);
        await FileIO.WriteBufferAsync(file, encrypted);
    }

    private static async Task<string?> ReadProtectedAsync(
        string name,
        CancellationToken cancellationToken)
    {
        var folder = await GetFolderAsync();
        var file = await folder.TryGetItemAsync(name) as StorageFile;
        if (file is null) return null;
        var encrypted = await FileIO.ReadBufferAsync(file);
        var clear = await new DataProtectionProvider().UnprotectAsync(encrypted);
        cancellationToken.ThrowIfCancellationRequested();
        CryptographicBuffer.CopyToByteArray(clear, out var bytes);
        return Encoding.UTF8.GetString(bytes);
    }

    private static async Task<StorageFolder> GetFolderAsync() =>
        await ApplicationData.Current.LocalFolder.CreateFolderAsync(
            "FirefoxSync",
            CreationCollisionOption.OpenIfExists);

    private static string FileName(FirefoxSyncSecret secret) => secret switch
    {
        FirefoxSyncSecret.AccountState => "account-state.dpapi",
        FirefoxSyncSecret.SyncState => "sync-state.dpapi",
        FirefoxSyncSecret.LoginsKey => "logins-key.dpapi",
        FirefoxSyncSecret.Schedule => "schedule.dpapi",
        FirefoxSyncSecret.EngineSelection => "engine-selection.dpapi",
        FirefoxSyncSecret.DisconnectIntent => "disconnect-intent.dpapi",
        _ => throw new ArgumentOutOfRangeException(nameof(secret)),
    };
}
