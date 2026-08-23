using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace XanhBrowser.Core;

public interface IFirefoxSyncRuntime : IDisposable
{
    FirefoxAccountState Initialize();
    FirefoxAccountState AccountState { get; }
    string BeginOAuth();
    FirefoxAccountState CompleteOAuth(string code, string state);
    string AccountJson();
    string? PersistedState();
    bool VaultUnlocked { get; }
    void UnlockVault(string localLoginsKey);
    void LockVault();
    string Sync(FirefoxSyncReason reason, string enginesJson);
    string UpdateLocalTabs(string tabsJson);
    string RemoteTabsJson();
    string BookmarkRootGuid(int root);
    string CreateBookmark(string bookmarkJson);
    string BookmarksJson(int root);
    void UpdateBookmark(string updateJson);
    bool DeleteBookmark(string guid, bool isPrivate);
    string RecordHistory(string visitsJson);
    string RecentHistoryJson(uint limit);
    void DeleteHistoryVisit(string url, long visitedAtEpochMillis);
    void ClearHistory();
    string CredentialsJson(string contextJson);
    string AddCredential(string credentialJson);
    string UpdateCredential(string credentialJson);
    bool DeleteCredential(string id, string contextJson);
    void TouchCredential(string id, string contextJson);
    void Disconnect(bool deleteLocal);
}

public interface IFirefoxSyncRuntimeFactory
{
    IFirefoxSyncRuntime Open(
        string configurationJson,
        string profileDirectory,
        string? localLoginsKey,
        string? accountJson,
        string? persistedSyncState);

    string GenerateLocalLoginsKey();
}

public sealed class NativeFirefoxSyncFactory : IFirefoxSyncRuntimeFactory
{
    public IFirefoxSyncRuntime Open(
        string configurationJson,
        string profileDirectory,
        string? localLoginsKey,
        string? accountJson,
        string? persistedSyncState) => new NativeFirefoxSync(
            configurationJson,
            profileDirectory,
            localLoginsKey,
            accountJson,
            persistedSyncState);

    public string GenerateLocalLoginsKey() => NativeFirefoxSync.GenerateLocalLoginsKey();
}

public sealed class NativeFirefoxSync : IFirefoxSyncRuntime
{
    private readonly SyncRuntimeHandle _handle;

    public NativeFirefoxSync(
        string configurationJson,
        string profileDirectory,
        string? localLoginsKey,
        string? accountJson,
        string? persistedSyncState)
    {
        _handle = NativeMethods.Open(
            configurationJson,
            profileDirectory,
            localLoginsKey,
            accountJson,
            persistedSyncState);
        if (_handle.IsInvalid) throw new InvalidOperationException(NativeMethods.TakeLastError());
    }

    public FirefoxAccountState Initialize() => (FirefoxAccountState)Checked(NativeMethods.Initialize(_handle));
    public FirefoxAccountState AccountState => (FirefoxAccountState)Checked(NativeMethods.AccountState(_handle));

    public static string GenerateLocalLoginsKey() =>
        NativeMethods.TakeOwned(NativeMethods.GenerateLocalLoginsKey());

    public string BeginOAuth() => NativeMethods.TakeOwned(NativeMethods.BeginOAuth(_handle));

    public FirefoxAccountState CompleteOAuth(string code, string state) =>
        (FirefoxAccountState)Checked(NativeMethods.CompleteOAuth(_handle, code, state));

    public string AccountJson() => NativeMethods.TakeOwned(NativeMethods.AccountJson(_handle));
    public string? PersistedState()
    {
        var state = NativeMethods.TakeOwned(NativeMethods.PersistedState(_handle));
        return state.Length == 0 ? null : state;
    }
    public bool VaultUnlocked => NativeMethods.VaultUnlocked(_handle);

    public void UnlockVault(string localLoginsKey)
    {
        if (!NativeMethods.UnlockVault(_handle, localLoginsKey))
            throw new InvalidOperationException(NativeMethods.TakeLastError());
    }

    public void LockVault()
    {
        if (!NativeMethods.LockVault(_handle))
            throw new InvalidOperationException(NativeMethods.TakeLastError());
    }

    public string Sync(FirefoxSyncReason reason, string enginesJson) =>
        NativeMethods.TakeOwned(NativeMethods.Sync(_handle, (int)reason, enginesJson));

    public string UpdateLocalTabs(string tabsJson) =>
        NativeMethods.TakeOwned(NativeMethods.UpdateLocalTabs(_handle, tabsJson));

    public string RemoteTabsJson() =>
        NativeMethods.TakeOwned(NativeMethods.RemoteTabsJson(_handle));

    public string BookmarkRootGuid(int root) =>
        NativeMethods.TakeOwned(NativeMethods.BookmarkRootGuid(root));

    public string CreateBookmark(string bookmarkJson) =>
        NativeMethods.TakeOwned(NativeMethods.CreateBookmark(_handle, bookmarkJson));

    public string BookmarksJson(int root) =>
        NativeMethods.TakeOwned(NativeMethods.BookmarksJson(_handle, root));

    public void UpdateBookmark(string updateJson)
    {
        if (!NativeMethods.UpdateBookmark(_handle, updateJson))
            throw new InvalidOperationException(NativeMethods.TakeLastError());
    }

    public bool DeleteBookmark(string guid, bool isPrivate)
    {
        var result = NativeMethods.DeleteBookmark(_handle, guid, isPrivate);
        return result >= 0
            ? result == 1
            : throw new InvalidOperationException(NativeMethods.TakeLastError());
    }

    public string RecordHistory(string visitsJson) =>
        NativeMethods.TakeOwned(NativeMethods.RecordHistory(_handle, visitsJson));

    public string RecentHistoryJson(uint limit) =>
        NativeMethods.TakeOwned(NativeMethods.RecentHistoryJson(_handle, limit));

    public void DeleteHistoryVisit(string url, long visitedAtEpochMillis)
    {
        if (!NativeMethods.DeleteHistoryVisit(_handle, url, visitedAtEpochMillis))
            throw new InvalidOperationException(NativeMethods.TakeLastError());
    }

    public void ClearHistory()
    {
        if (!NativeMethods.ClearHistory(_handle))
            throw new InvalidOperationException(NativeMethods.TakeLastError());
    }

    // These JSON strings contain plaintext credentials. Callers must keep
    // them inside the native credential UI lifetime and must never log them.
    public string CredentialsJson(string contextJson) =>
        NativeMethods.TakeOwned(NativeMethods.CredentialsJson(_handle, contextJson));

    public string AddCredential(string credentialJson) =>
        NativeMethods.TakeOwned(NativeMethods.AddCredential(_handle, credentialJson));

    public string UpdateCredential(string credentialJson) =>
        NativeMethods.TakeOwned(NativeMethods.UpdateCredential(_handle, credentialJson));

    public bool DeleteCredential(string id, string contextJson)
    {
        var result = NativeMethods.DeleteCredential(_handle, id, contextJson);
        return result >= 0
            ? result == 1
            : throw new InvalidOperationException(NativeMethods.TakeLastError());
    }

    public void TouchCredential(string id, string contextJson)
    {
        if (!NativeMethods.TouchCredential(_handle, id, contextJson))
            throw new InvalidOperationException(NativeMethods.TakeLastError());
    }

    public void Disconnect(bool deleteLocal)
    {
        if (!NativeMethods.Disconnect(_handle, deleteLocal))
            throw new InvalidOperationException(NativeMethods.TakeLastError());
    }

    public void Dispose() => _handle.Dispose();

    private static int Checked(int value) => value >= 0
        ? value
        : throw new InvalidOperationException(NativeMethods.TakeLastError());
}

internal sealed class SyncRuntimeHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public SyncRuntimeHandle() : base(true) { }
    protected override bool ReleaseHandle()
    {
        NativeMethods.Free(handle);
        return true;
    }
}

internal static class NativeMethods
{
    private const string Library = "xanh_sync_core";

    [DllImport(Library, EntryPoint = "xanh_sync_runtime_open")]
    internal static extern SyncRuntimeHandle Open(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string config,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string profile,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? key,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? account,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? state);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_free")]
    internal static extern void Free(nint runtime);
    [DllImport(Library, EntryPoint = "xanh_sync_generate_local_logins_key")]
    internal static extern nint GenerateLocalLoginsKey();
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_initialize")]
    internal static extern int Initialize(SyncRuntimeHandle runtime);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_account_state")]
    internal static extern int AccountState(SyncRuntimeHandle runtime);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_begin_oauth")]
    internal static extern nint BeginOAuth(SyncRuntimeHandle runtime);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_complete_oauth")]
    internal static extern int CompleteOAuth(
        SyncRuntimeHandle runtime,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string code,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string state);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_account_json")]
    internal static extern nint AccountJson(SyncRuntimeHandle runtime);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_persisted_state")]
    internal static extern nint PersistedState(SyncRuntimeHandle runtime);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_unlock_vault")]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool UnlockVault(
        SyncRuntimeHandle runtime,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string localLoginsKey);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_lock_vault")]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool LockVault(SyncRuntimeHandle runtime);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_vault_unlocked")]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool VaultUnlocked(SyncRuntimeHandle runtime);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_sync")]
    internal static extern nint Sync(
        SyncRuntimeHandle runtime,
        int reason,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string engines);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_update_local_tabs")]
    internal static extern nint UpdateLocalTabs(
        SyncRuntimeHandle runtime,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string tabs);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_remote_tabs_json")]
    internal static extern nint RemoteTabsJson(SyncRuntimeHandle runtime);
    [DllImport(Library, EntryPoint = "xanh_sync_bookmark_root_guid")]
    internal static extern nint BookmarkRootGuid(int root);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_create_bookmark")]
    internal static extern nint CreateBookmark(
        SyncRuntimeHandle runtime,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string bookmarkJson);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_bookmarks_json")]
    internal static extern nint BookmarksJson(SyncRuntimeHandle runtime, int root);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_update_bookmark")]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool UpdateBookmark(
        SyncRuntimeHandle runtime,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string updateJson);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_delete_bookmark")]
    internal static extern int DeleteBookmark(
        SyncRuntimeHandle runtime,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string guid,
        [MarshalAs(UnmanagedType.I1)] bool isPrivate);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_record_history")]
    internal static extern nint RecordHistory(
        SyncRuntimeHandle runtime,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string visitsJson);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_recent_history_json")]
    internal static extern nint RecentHistoryJson(SyncRuntimeHandle runtime, uint limit);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_delete_history_visit")]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool DeleteHistoryVisit(
        SyncRuntimeHandle runtime,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string url,
        long visitedAtEpochMillis);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_clear_history")]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool ClearHistory(SyncRuntimeHandle runtime);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_credentials_json")]
    internal static extern nint CredentialsJson(
        SyncRuntimeHandle runtime,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string contextJson);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_add_credential")]
    internal static extern nint AddCredential(
        SyncRuntimeHandle runtime,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string credentialJson);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_update_credential")]
    internal static extern nint UpdateCredential(
        SyncRuntimeHandle runtime,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string credentialJson);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_delete_credential")]
    internal static extern int DeleteCredential(
        SyncRuntimeHandle runtime,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string contextJson);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_touch_credential")]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool TouchCredential(
        SyncRuntimeHandle runtime,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string id,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string contextJson);
    [DllImport(Library, EntryPoint = "xanh_sync_runtime_disconnect")]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool Disconnect(SyncRuntimeHandle runtime, [MarshalAs(UnmanagedType.I1)] bool deleteLocal);
    [DllImport(Library, EntryPoint = "xanh_sync_last_error")]
    private static extern nint LastError();
    [DllImport(Library, EntryPoint = "xanh_sync_string_free")]
    private static extern void StringFree(nint value);

    internal static string TakeLastError() => TakeOptional(LastError()) ?? "Unknown Firefox Sync error";
    internal static string TakeOwned(nint value) => TakeOptional(value)
        ?? throw new InvalidOperationException(TakeLastError());
    internal static string? TakeOptional(nint value)
    {
        if (value == 0) return null;
        try { return Marshal.PtrToStringUTF8(value); }
        finally { StringFree(value); }
    }
}
