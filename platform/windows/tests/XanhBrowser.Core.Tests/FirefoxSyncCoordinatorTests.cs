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
        await File.WriteAllTextAsync(Path.Combine(profile, "logins.sqlite-journal"), "rollback");
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
        Assert.IsFalse(File.Exists(Path.Combine(profile, "logins.sqlite-journal")));
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

    [TestMethod]
    public async Task CredentialQueryRequiresUnlockedVaultAndRejectsUnsafeNativeRecords()
    {
        var runtime = new FakeRuntime { State = FirefoxAccountState.Connected };
        var store = new FakeSecretStore();
        using var coordinator = Create(runtime, store);
        await coordinator.InitializeAsync();
        var context = new CredentialAccessContext(
            new Uri("https://example.org/login"),
            new Uri("https://example.org"),
            new Uri("https://example.org"),
            false,
            true);

        await Assert.ThrowsExceptionAsync<InvalidOperationException>(
            () => coordinator.CredentialsAsync(context));
        Assert.IsTrue(await coordinator.UnlockVaultAsync());
        runtime.CredentialsResult = """
            [{"id":"credential-id","origin":"https://example.org","form_action_origin":"https://example.org","username_field":"username","password_field":"password","username":"person@example.org","password":"secret","time_created_epoch_millis":1,"time_password_changed_epoch_millis":1,"time_last_used_epoch_millis":1,"times_used":1}]
            """;
        var records = await coordinator.CredentialsAsync(context);
        Assert.AreEqual(1, records.Count);
        await coordinator.TouchCredentialAsync(records[0].Id, context);
        Assert.AreEqual(1, runtime.TouchCredentialCalls);

        runtime.CredentialsResult = runtime.CredentialsResult.Replace(
            "https://example.org\",\"form_action_origin",
            "https://evil.example\",\"form_action_origin",
            StringComparison.Ordinal);
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(
            () => coordinator.CredentialsAsync(context));
    }

    [TestMethod]
    public async Task PlacesAndTabsUseExactBoundedNativeIdentities()
    {
        var runtime = new FakeRuntime
        {
            State = FirefoxAccountState.Connected,
            BookmarksResult = """
                [
                  {"guid":"bookmark1234","parent_guid":"mobile______","position":0,"kind":"bookmark","title":"One","url":"https://example.org/one","is_openable":true,"date_added_epoch_millis":1,"last_modified_epoch_millis":2},
                  {"guid":"bookmark5678","parent_guid":"mobile______","position":1,"kind":"bookmark","title":"Two","url":"https://example.org/one","is_openable":true,"date_added_epoch_millis":3,"last_modified_epoch_millis":4}
                ]
                """,
            HistoryResult = """
                [{"url":"https://example.org/one","title":"One","visited_at_epoch_millis":1700000000000,"transition":"link","is_remote":false}]
                """,
        };
        var store = new FakeSecretStore();
        using var coordinator = Create(runtime, store);
        await coordinator.InitializeAsync();

        var bookmarks = await coordinator.BookmarksAsync();
        var history = await coordinator.RecentHistoryAsync();
        var created = await coordinator.CreateBookmarkAsync(
            new Uri("https://example.org/new"), "New bookmark");
        await coordinator.RenameBookmarkAsync("bookmark5678", "Renamed");
        Assert.IsTrue(await coordinator.DeleteBookmarkAsync("bookmark1234"));
        await coordinator.RecordHistoryAsync(
            new Uri("https://example.org/visited"),
            "Visited",
            DateTimeOffset.FromUnixTimeMilliseconds(1_700_000_000_001));
        await coordinator.DeleteHistoryVisitAsync(
            new Uri("https://example.org/one"), 1_700_000_000_000);
        await coordinator.UpdateLocalTabsAsync(new[]
        {
            new FirefoxLocalTab(
                "Regular", [new Uri("https://example.org/regular")], null,
                DateTimeOffset.FromUnixTimeMilliseconds(1_700_000_000_002), false),
            new FirefoxLocalTab(
                "Private", [new Uri("https://example.org/private")], null,
                DateTimeOffset.FromUnixTimeMilliseconds(1_700_000_000_003), true),
        });

        Assert.AreEqual(2, bookmarks.Count);
        Assert.AreEqual("bookmark5678", bookmarks[1].Guid);
        Assert.AreEqual(1, history.Count);
        Assert.AreEqual("created_1234", created);
        StringAssert.Contains(runtime.LastBookmarkUpdate, "\"guid\":\"bookmark5678\"");
        Assert.AreEqual("bookmark1234", runtime.LastDeletedBookmarkGuid);
        Assert.AreEqual(1_700_000_000_000, runtime.LastDeletedHistoryTimestamp);
        StringAssert.Contains(runtime.LastHistoryPayload, "https://example.org/visited");
        StringAssert.Contains(runtime.LastTabsPayload, "\"is_private\":true");
        Assert.IsTrue(store.Values.ContainsKey(FirefoxSyncSecret.Schedule));
        await coordinator.SyncAsync(FirefoxSyncReason.Manual);
        using (var schedule = JsonDocument.Parse(store.Values[FirefoxSyncSecret.Schedule]))
            Assert.AreEqual(
                JsonValueKind.Null,
                schedule.RootElement.GetProperty("local_change").ValueKind);
        await Assert.ThrowsExceptionAsync<ArgumentException>(() =>
            coordinator.DeleteBookmarkAsync("not-a-guid"));
        await Assert.ThrowsExceptionAsync<ArgumentException>(() =>
            coordinator.CreateBookmarkAsync(
                new Uri("https://example.org/private"), "Private", isPrivate: true));
        await Assert.ThrowsExceptionAsync<ArgumentException>(() =>
            coordinator.DeleteHistoryVisitAsync(
                new Uri("https://example.org/one"), long.MaxValue));
        runtime.BookmarksResult = runtime.BookmarksResult.Replace(
            "bookmark1234", "bad-guid", StringComparison.Ordinal);
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(() =>
            coordinator.BookmarksAsync());
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
        public int TouchCredentialCalls { get; private set; }
        public int MaximumConcurrentCalls => _maximumConcurrentCalls;
        public bool LastDisconnectDeletedLocal { get; private set; }
        public string BookmarksResult { get; set; } = "[]";
        public string HistoryResult { get; set; } = "[]";
        public string LastTabsPayload { get; private set; } = "";
        public string LastBookmarkUpdate { get; private set; } = "";
        public string LastHistoryPayload { get; private set; } = "";
        public string? LastDeletedBookmarkGuid { get; private set; }
        public long LastDeletedHistoryTimestamp { get; private set; }
        public FirefoxAccountState AccountState => State;
        public bool VaultUnlocked { get; private set; }
        public string CredentialsResult { get; set; } = "[]";

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

        public string UpdateLocalTabs(string tabsJson)
        {
            LastTabsPayload = tabsJson;
            return "{\"accepted_count\":1,\"skipped_private_count\":1}";
        }

        public string RemoteTabsJson() => "[]";
        public string BookmarkRootGuid(int root) => "mobile______";
        public string CreateBookmark(string bookmarkJson) => "created_1234";
        public string BookmarksJson(int root) => BookmarksResult;
        public void UpdateBookmark(string updateJson) => LastBookmarkUpdate = updateJson;

        public bool DeleteBookmark(string guid, bool isPrivate)
        {
            LastDeletedBookmarkGuid = guid;
            return true;
        }

        public string RecordHistory(string visitsJson)
        {
            LastHistoryPayload = visitsJson;
            return "{\"accepted_count\":1,\"skipped_private_count\":0}";
        }

        public string RecentHistoryJson(uint limit) => HistoryResult;

        public void DeleteHistoryVisit(string url, long visitedAtEpochMillis) =>
            LastDeletedHistoryTimestamp = visitedAtEpochMillis;

        public void ClearHistory() { }
        public string CredentialsJson(string contextJson) => CredentialsResult;
        public void TouchCredential(string id, string contextJson) => TouchCredentialCalls++;

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
