using System.Collections.Concurrent;
using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using XanhBrowser.Core;

namespace XanhBrowser.Core.Tests;

[TestClass]
public sealed class FirefoxSyncCoordinatorTests
{
    private static FirefoxSyncConfiguration Configuration() => new(
        new Uri("https://accounts.firefox.com"),
        null,
        "approved-client",
        "xanh-browser://accounts/oauth",
        "Xanh Browser Windows");

    [TestMethod]
    public void NativeConfigurationDistinguishesMozillaAndSelfHosted()
    {
        using var mozilla = JsonDocument.Parse(Configuration().ToNativeJson());
        Assert.AreEqual("mozilla", mozilla.RootElement.GetProperty("server").GetProperty("kind").GetString());
        Assert.AreEqual("desktop", mozilla.RootElement.GetProperty("device_kind").GetString());

        var selfHosted = Configuration() with
        {
            AccountsUri = new Uri("https://accounts.example.test"),
            TokenServerUri = new Uri("https://sync.example.test/token"),
        };
        using var custom = JsonDocument.Parse(selfHosted.ToNativeJson());
        Assert.AreEqual("self-hosted", custom.RootElement.GetProperty("server").GetProperty("kind").GetString());
        Assert.AreEqual(
            "https://sync.example.test/token",
            custom.RootElement.GetProperty("server").GetProperty("token_server_url").GetString());
    }

    [TestMethod]
    public void OAuthCallbackRequiresTheExactEndpointAndSingleCodeAndState()
    {
        var valid = FirefoxSyncCoordinator.ParseOAuthCallback(
            "xanh-browser://accounts/oauth",
            new Uri("xanh-browser://accounts/oauth?code=a%2Bb&state=state-value"));
        Assert.AreEqual("a+b", valid.Code);
        Assert.AreEqual("state-value", valid.State);

        foreach (var callback in new[]
        {
            "xanh-browser://accounts/other?code=a&state=b",
            "xanh-browser://evil/oauth?code=a&state=b",
            "xanh-browser://accounts/oauth?code=a&code=b&state=c",
            "xanh-browser://accounts/oauth?code=a&state=b&token=secret",
            "xanh-browser://accounts/oauth?code=a&state=b#fragment",
            "xanh-browser://user@accounts/oauth?code=a&state=b",
        })
        {
            Assert.ThrowsException<ArgumentException>(() =>
                FirefoxSyncCoordinator.ParseOAuthCallback(
                    "xanh-browser://accounts/oauth", new Uri(callback)), callback);
        }
    }

    [TestMethod]
    public async Task InitializeAndSyncPersistOpaqueNativeStateAndBackoff()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_000);
        var runtime = new FakeRuntime
        {
            State = FirefoxAccountState.Connected,
            SyncResult = "{\"status\":\"success\",\"next_sync_allowed_epoch_seconds\":1200}",
        };
        var store = new FakeSecretStore();
        using var coordinator = Create(runtime, store, () => now);

        await coordinator.InitializeAsync();
        var result = await coordinator.SyncAsync(FirefoxSyncReason.Manual);

        Assert.AreEqual(FirefoxSyncStatus.Success, result.Status);
        Assert.AreEqual(now, result.LastSync);
        Assert.AreEqual(DateTimeOffset.FromUnixTimeSeconds(1_200), result.NextAllowed);
        Assert.AreEqual("opaque-account", store.Values[FirefoxSyncSecret.AccountState]);
        Assert.AreEqual("opaque-sync", store.Values[FirefoxSyncSecret.SyncState]);
        Assert.AreEqual(1, runtime.SyncCalls);

        now = DateTimeOffset.FromUnixTimeSeconds(1_100);
        result = await coordinator.SyncAsync(FirefoxSyncReason.Manual);
        Assert.AreEqual(FirefoxSyncStatus.BackedOff, result.Status);
        Assert.AreEqual(1, runtime.SyncCalls);
    }

    [TestMethod]
    public async Task NativeOperationsAreSingleFlight()
    {
        var runtime = new FakeRuntime
        {
            State = FirefoxAccountState.Connected,
            SyncDelay = TimeSpan.FromMilliseconds(50),
        };
        using var coordinator = Create(runtime, new FakeSecretStore());
        await coordinator.InitializeAsync();

        await Task.WhenAll(
            coordinator.SyncAsync(FirefoxSyncReason.Manual),
            coordinator.SyncAsync(FirefoxSyncReason.Manual));

        Assert.AreEqual(2, runtime.SyncCalls);
        Assert.AreEqual(1, runtime.MaximumConcurrentCalls);
    }

    [TestMethod]
    public async Task OAuthStateIsPersistedBeforeTheSystemBrowserOpens()
    {
        var runtime = new FakeRuntime();
        var store = new FakeSecretStore();
        using var coordinator = Create(runtime, store);
        await coordinator.InitializeAsync();
        store.Values.TryRemove(FirefoxSyncSecret.AccountState, out _);

        var launch = await coordinator.BeginOAuthAsync();

        Assert.AreEqual("accounts.firefox.com", launch.AccountDomain);
        Assert.AreEqual("opaque-account", store.Values[FirefoxSyncSecret.AccountState]);
        Assert.AreEqual(FirefoxAccountState.Authenticating, coordinator.Snapshot.AccountState);
    }

    [TestMethod]
    public async Task GeneratedVaultKeyIsStoredOnlyAfterNativeUnlockSucceeds()
    {
        var profile = Path.Combine(Path.GetTempPath(), $"xanh-sync-{Guid.NewGuid():N}");
        Directory.CreateDirectory(profile);
        await File.WriteAllTextAsync(Path.Combine(profile, "logins.sqlite"), "unreadable");
        var runtime = new FakeRuntime
        {
            State = FirefoxAccountState.Connected,
            UnlockError = new InvalidOperationException("redacted native failure"),
        };
        var store = new FakeSecretStore();
        using var coordinator = Create(runtime, store, profileDirectory: profile);
        await coordinator.InitializeAsync();

        await Assert.ThrowsExceptionAsync<InvalidOperationException>(
            () => coordinator.UnlockVaultAsync());

        Assert.IsFalse(store.Values.ContainsKey(FirefoxSyncSecret.LoginsKey));
        Assert.IsFalse(File.Exists(Path.Combine(profile, "logins.sqlite")));
        Assert.IsFalse(runtime.VaultUnlocked);
        Directory.Delete(profile, recursive: true);
    }

    [TestMethod]
    public async Task DisconnectRetryCannotChangeTheLocalDataChoice()
    {
        var runtime = new FakeRuntime { State = FirefoxAccountState.Connected };
        var store = new FakeSecretStore();
        using var coordinator = Create(runtime, store);
        await coordinator.InitializeAsync();
        store.DeleteFailuresRemaining = 1;

        await Assert.ThrowsExceptionAsync<IOException>(() => coordinator.DisconnectAsync(deleteLocal: true));
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(
            () => coordinator.DisconnectAsync(deleteLocal: false));
        await coordinator.DisconnectAsync(deleteLocal: true);

        Assert.AreEqual(1, runtime.DisconnectCalls);
        Assert.IsTrue(runtime.LastDisconnectDeletedLocal);
        Assert.AreEqual(FirefoxAccountState.Disconnected, coordinator.Snapshot.AccountState);
        Assert.AreEqual(0, store.Values.Count);
    }

    private static FirefoxSyncCoordinator Create(
        FakeRuntime runtime,
        FakeSecretStore store,
        Func<DateTimeOffset>? clock = null,
        string? profileDirectory = null) => new(
            Configuration(),
            profileDirectory ?? Path.Combine(Path.GetTempPath(), $"xanh-sync-{Guid.NewGuid():N}"),
            new FakeRuntimeFactory(runtime),
            store,
            clock);

    private sealed class FakeRuntimeFactory(FakeRuntime runtime) : IFirefoxSyncRuntimeFactory
    {
        public IFirefoxSyncRuntime Open(
            string configurationJson,
            string profileDirectory,
            string? localLoginsKey,
            string? accountJson,
            string? persistedSyncState) => runtime;

        public string GenerateLocalLoginsKey() => "generated-device-key";
    }

    private sealed class FakeRuntime : IFirefoxSyncRuntime
    {
        private int _activeCalls;
        private int _maximumConcurrentCalls;

        public FirefoxAccountState State { get; set; } = FirefoxAccountState.Disconnected;
        public string SyncResult { get; set; } =
            "{\"status\":\"success\",\"next_sync_allowed_epoch_seconds\":null}";
        public TimeSpan SyncDelay { get; set; }
        public Exception? UnlockError { get; set; }
        public int SyncCalls { get; private set; }
        public int DisconnectCalls { get; private set; }
        public int MaximumConcurrentCalls => _maximumConcurrentCalls;
        public bool LastDisconnectDeletedLocal { get; private set; }
        public FirefoxAccountState AccountState => State;
        public bool VaultUnlocked { get; private set; }

        public FirefoxAccountState Initialize() => State;
        public string BeginOAuth() => "https://accounts.firefox.com/oauth";
        public FirefoxAccountState CompleteOAuth(string code, string state) =>
            State = FirefoxAccountState.Connected;
        public string AccountJson() => "opaque-account";
        public string? PersistedState() => "opaque-sync";

        public void UnlockVault(string localLoginsKey)
        {
            if (UnlockError is not null) throw UnlockError;
            VaultUnlocked = true;
        }

        public void LockVault() => VaultUnlocked = false;

        public string Sync(FirefoxSyncReason reason, string enginesJson)
        {
            var active = Interlocked.Increment(ref _activeCalls);
            InterlockedExtensions.Max(ref _maximumConcurrentCalls, active);
            try
            {
                SyncCalls++;
                if (SyncDelay > TimeSpan.Zero) Thread.Sleep(SyncDelay);
                return SyncResult;
            }
            finally
            {
                Interlocked.Decrement(ref _activeCalls);
            }
        }

        public string RemoteTabsJson() => "[]";

        public void Disconnect(bool deleteLocal)
        {
            DisconnectCalls++;
            LastDisconnectDeletedLocal = deleteLocal;
            State = FirefoxAccountState.Disconnected;
            VaultUnlocked = false;
        }

        public void Dispose() { }
    }

    private sealed class FakeSecretStore : IFirefoxSyncSecretStore
    {
        public ConcurrentDictionary<FirefoxSyncSecret, string> Values { get; } = new();
        public int DeleteFailuresRemaining { get; set; }

        public Task<string?> ReadAsync(
            FirefoxSyncSecret secret,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(Values.TryGetValue(secret, out var value) ? value : null);

        public Task WriteAsync(
            FirefoxSyncSecret secret,
            string value,
            CancellationToken cancellationToken = default)
        {
            Values[secret] = value;
            return Task.CompletedTask;
        }

        public Task DeleteAsync(
            FirefoxSyncSecret secret,
            CancellationToken cancellationToken = default)
        {
            if (DeleteFailuresRemaining > 0)
            {
                DeleteFailuresRemaining--;
                throw new IOException("injected secure-store failure");
            }
            Values.TryRemove(secret, out _);
            return Task.CompletedTask;
        }

        public Task<bool> VerifyUserPresenceAsync(
            string reason,
            CancellationToken cancellationToken = default) => Task.FromResult(true);
    }

    private static class InterlockedExtensions
    {
        public static void Max(ref int location, int value)
        {
            var current = Volatile.Read(ref location);
            while (current < value)
            {
                var observed = Interlocked.CompareExchange(ref location, value, current);
                if (observed == current) return;
                current = observed;
            }
        }
    }
}
