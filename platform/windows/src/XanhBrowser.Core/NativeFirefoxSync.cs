using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace XanhBrowser.Core;

public sealed class NativeFirefoxSync : IDisposable
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
    public string? PersistedState() => NativeMethods.TakeOptional(NativeMethods.PersistedState(_handle));
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
