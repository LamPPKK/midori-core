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
internal sealed class WindowsSyncSecretStore
{
    private const string AccountState = "account-state";
    private const string SyncState = "sync-state";
    private const string LoginsKey = "logins-key";
    private readonly FirefoxSyncVaultSession _vault = new();

    public Task StoreAccountStateAsync(string value) => StoreAsync(AccountState, value);
    public Task StoreSyncStateAsync(string value) => StoreAsync(SyncState, value);
    public Task<string?> ReadAccountStateAsync() => ReadAsync(AccountState);
    public Task<string?> ReadSyncStateAsync() => ReadAsync(SyncState);

    public async Task<string?> UnlockLoginsKeyAsync(Func<string> createKey, string reason)
    {
        var availability = await UserConsentVerifier.CheckAvailabilityAsync();
        if (availability != UserConsentVerifierAvailability.Available) return null;
        var result = await UserConsentVerifier.RequestVerificationAsync(reason);
        if (result != UserConsentVerificationResult.Verified) return null;

        var key = await ReadAsync(LoginsKey);
        if (key is null)
        {
            key = createKey();
            await StoreAsync(LoginsKey, key);
        }
        _vault.Unlock(DateTimeOffset.UtcNow);
        return key;
    }

    public bool TouchVault() => _vault.Touch(DateTimeOffset.UtcNow);
    public void LockVault() => _vault.Lock();

    public async Task DeleteAllAsync()
    {
        LockVault();
        var folder = await GetFolderAsync();
        foreach (var name in new[] { AccountState, SyncState, LoginsKey })
        {
            var file = await folder.TryGetItemAsync(FileName(name)) as StorageFile;
            if (file is not null) await file.DeleteAsync(StorageDeleteOption.PermanentDelete);
        }
    }

    private static async Task StoreAsync(string name, string value)
    {
        var clear = CryptographicBuffer.ConvertStringToBinary(value, BinaryStringEncoding.Utf8);
        var encrypted = await new DataProtectionProvider("LOCAL=user").ProtectAsync(clear);
        var folder = await GetFolderAsync();
        var file = await folder.CreateFileAsync(FileName(name), CreationCollisionOption.ReplaceExisting);
        await FileIO.WriteBufferAsync(file, encrypted);
    }

    private static async Task<string?> ReadAsync(string name)
    {
        var folder = await GetFolderAsync();
        var file = await folder.TryGetItemAsync(FileName(name)) as StorageFile;
        if (file is null) return null;
        var encrypted = await FileIO.ReadBufferAsync(file);
        var clear = await new DataProtectionProvider().UnprotectAsync(encrypted);
        CryptographicBuffer.CopyToByteArray(clear, out var bytes);
        return Encoding.UTF8.GetString(bytes);
    }

    private static async Task<StorageFolder> GetFolderAsync() =>
        await ApplicationData.Current.LocalFolder.CreateFolderAsync(
            "FirefoxSync",
            CreationCollisionOption.OpenIfExists);

    private static string FileName(string name) => $"{name}.dpapi";
}
