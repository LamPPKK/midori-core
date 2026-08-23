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
            "xanh-browser://accounts/oauth?code=a%00b&state=c",
        })
        {
            Assert.ThrowsException<ArgumentException>(() =>
                FirefoxSyncCoordinator.ParseOAuthCallback(
                    "xanh-browser://accounts/oauth", new Uri(callback)), callback);
        }
        var oversized = new string('a', 4_097);
        Assert.ThrowsException<ArgumentException>(() =>
            FirefoxSyncCoordinator.ParseOAuthCallback(
                "xanh-browser://accounts/oauth",
                new Uri($"xanh-browser://accounts/oauth?code={oversized}&state=value")));
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
    public async Task OAuthFlowIsMemoryBoundAndRequiresTheExactState()
    {
        var runtime = new FakeRuntime();
        var store = new FakeSecretStore();
        using var coordinator = Create(runtime, store);
        await coordinator.InitializeAsync();
        store.Values.TryRemove(FirefoxSyncSecret.AccountState, out _);

        var launch = await coordinator.BeginOAuthAsync();

        Assert.AreEqual("https://accounts.firefox.com", launch.AccountOrigin);
        Assert.IsFalse(store.Values.ContainsKey(FirefoxSyncSecret.AccountState));
        Assert.AreEqual(FirefoxAccountState.Authenticating, coordinator.Snapshot.AccountState);
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(
            () => coordinator.BeginOAuthAsync());
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(
            () => coordinator.CompleteOAuthAsync(
                new Uri("xanh-browser://accounts/oauth?code=code&state=wrong")));
        Assert.AreEqual(0, runtime.CompleteOAuthCalls);

        var snapshot = await coordinator.CompleteOAuthAsync(
            new Uri("xanh-browser://accounts/oauth?code=code&state=expected-state"));
        Assert.AreEqual(FirefoxAccountState.Connected, snapshot.AccountState);
        Assert.AreEqual(1, runtime.CompleteOAuthCalls);
        Assert.AreEqual("opaque-account", store.Values[FirefoxSyncSecret.AccountState]);
    }

    [TestMethod]
    public async Task OAuthCallbackAfterCoordinatorRestartFailsBeforeNativeCompletion()
    {
        var runtime = new FakeRuntime();
        using var coordinator = Create(runtime, new FakeSecretStore());
        await coordinator.InitializeAsync();

        await Assert.ThrowsExceptionAsync<InvalidOperationException>(
            () => coordinator.CompleteOAuthAsync(
                new Uri("xanh-browser://accounts/oauth?code=code&state=expected-state")));
        Assert.AreEqual(0, runtime.CompleteOAuthCalls);
    }

    [TestMethod]
    public async Task InitializationDoesNotRestoreAuthenticatingStateWithoutPkceState()
    {
        var runtime = new FakeRuntime { State = FirefoxAccountState.Authenticating };
        var store = new FakeSecretStore();
        store.Values[FirefoxSyncSecret.AccountState] = "stale-account";
        store.Values[FirefoxSyncSecret.SyncState] = "stale-sync";
        using var coordinator = Create(runtime, store);

        var snapshot = await coordinator.InitializeAsync();

        Assert.AreEqual(FirefoxAccountState.Disconnected, snapshot.AccountState);
        Assert.AreEqual(
            "Firefox Accounts sign-in expired; start sign-in again",
            snapshot.Detail);
        Assert.IsFalse(store.Values.ContainsKey(FirefoxSyncSecret.AccountState));
        Assert.IsFalse(store.Values.ContainsKey(FirefoxSyncSecret.SyncState));
        CollectionAssert.AreEqual(
            new[] { FirefoxSyncSecret.SyncState, FirefoxSyncSecret.AccountState },
            store.Deletes);
    }

    [TestMethod]
    public async Task StaleOAuthCleanupIsRetryableWhenAccountDeleteFails()
    {
        var runtime = new FakeRuntime { State = FirefoxAccountState.Authenticating };
        var store = new FakeSecretStore();
        store.Values[FirefoxSyncSecret.AccountState] = "stale-account";
        store.Values[FirefoxSyncSecret.SyncState] = "stale-sync";
        store.TargetedDeleteFailures.Add(FirefoxSyncSecret.AccountState);
        using var first = Create(runtime, store);

        await Assert.ThrowsExceptionAsync<IOException>(() => first.InitializeAsync());
        Assert.IsFalse(store.Values.ContainsKey(FirefoxSyncSecret.SyncState));
        Assert.AreEqual("stale-account", store.Values[FirefoxSyncSecret.AccountState]);

        using var retry = Create(runtime, store);
        var snapshot = await retry.InitializeAsync();
        Assert.AreEqual(FirefoxAccountState.Disconnected, snapshot.AccountState);
        Assert.IsFalse(store.Values.ContainsKey(FirefoxSyncSecret.AccountState));
    }

    [TestMethod]
    public async Task OAuthAuthorizationRequiresConfiguredHostAndPort()
    {
        var configuration = Configuration() with
        {
            AccountsUri = new Uri("https://accounts.example.test:8443"),
            TokenServerUri = new Uri("https://sync.example.test/token"),
        };
        var acceptedRuntime = new FakeRuntime
        {
            BeginOAuthValue =
                "https://accounts.example.test:8443/oauth?state=expected-state",
        };
        using var accepted = Create(
            acceptedRuntime, new FakeSecretStore(), configuration: configuration);
        await accepted.InitializeAsync();
        var launch = await accepted.BeginOAuthAsync();
        Assert.AreEqual("https://accounts.example.test:8443", launch.AccountOrigin);

        foreach (var value in new[]
        {
            "https://evil.example.test:8443/oauth?state=expected-state",
            "https://accounts.example.test:443/oauth?state=expected-state",
        })
        {
            var runtime = new FakeRuntime { BeginOAuthValue = value };
            using var coordinator = Create(
                runtime, new FakeSecretStore(), configuration: configuration);
            await coordinator.InitializeAsync();
            await Assert.ThrowsExceptionAsync<InvalidOperationException>(
                () => coordinator.BeginOAuthAsync());
        }
    }

    [TestMethod]
    public async Task DisposeAsyncDrainsNativeCompletionBeforeFreeingRuntime()
    {
        using var entered = new ManualResetEventSlim();
        using var proceed = new ManualResetEventSlim();
        var runtime = new FakeRuntime
        {
            CompleteOAuthEntered = entered,
            CompleteOAuthContinue = proceed,
        };
        var coordinator = Create(runtime, new FakeSecretStore());
        await coordinator.InitializeAsync();
        await coordinator.BeginOAuthAsync();

        var completion = coordinator.CompleteOAuthAsync(
            new Uri("xanh-browser://accounts/oauth?code=code&state=expected-state"));
        Assert.IsTrue(entered.Wait(TimeSpan.FromSeconds(5)));
        var disposal = coordinator.DisposeAsync().AsTask();
        Assert.IsFalse(disposal.IsCompleted);

        proceed.Set();
        var snapshot = await completion;
        await disposal;

        Assert.AreEqual(FirefoxAccountState.Connected, snapshot.AccountState);
        Assert.AreEqual(1, runtime.DisposeCalls);
        await Assert.ThrowsExceptionAsync<ObjectDisposedException>(
            () => coordinator.SyncAsync(FirefoxSyncReason.Manual));
    }

    [TestMethod]
    public async Task AmbiguousNativeBeginFailureQuarantinesOAuthUntilRestart()
    {
        var runtime = new FakeRuntime { BeginOAuthError = new IOException("native failure") };
        using var coordinator = Create(runtime, new FakeSecretStore());
        await coordinator.InitializeAsync();

        await Assert.ThrowsExceptionAsync<IOException>(() => coordinator.BeginOAuthAsync());
        runtime.BeginOAuthError = null;
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(
            () => coordinator.BeginOAuthAsync());
        Assert.AreEqual(1, runtime.BeginOAuthCalls);

        var ambiguousRuntime = new FakeRuntime
        {
            BeginOAuthValue = "https://accounts.firefox.com/oauth?state&state=expected-state",
        };
        using var ambiguousCoordinator = Create(ambiguousRuntime, new FakeSecretStore());
        await ambiguousCoordinator.InitializeAsync();
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(
            () => ambiguousCoordinator.BeginOAuthAsync());
        Assert.AreEqual(1, ambiguousRuntime.BeginOAuthCalls);
    }

    [TestMethod]
    public async Task PersistedSyncStateIsCommittedBeforeAccountState()
    {
        var store = new FakeSecretStore();
        using var coordinator = Create(new FakeRuntime(), store);

        await coordinator.InitializeAsync();

        CollectionAssert.AreEqual(
            new[] { FirefoxSyncSecret.SyncState, FirefoxSyncSecret.AccountState },
            store.Writes);
    }

    [TestMethod]
    public async Task FirstSyncFailureDoesNotUndoCompletedOAuth()
    {
        var runtime = new FakeRuntime { SyncError = new IOException("network failure") };
        using var coordinator = Create(runtime, new FakeSecretStore());
        await coordinator.InitializeAsync();
        await coordinator.BeginOAuthAsync();

        var snapshot = await coordinator.CompleteOAuthAsync(
            new Uri("xanh-browser://accounts/oauth?code=code&state=expected-state"));

        Assert.AreEqual(FirefoxAccountState.Connected, snapshot.AccountState);
        Assert.AreEqual(FirefoxSyncStatus.NetworkError, snapshot.Status);
        Assert.AreEqual("Sign-in completed; the first Sync did not finish", snapshot.Detail);
    }

    [TestMethod]
    public async Task AbandonedOAuthReopensPersistedStateAndRejectsOldCallback()
    {
        var runtime = new FakeRuntime
        {
            BeginOAuthValue = "https://accounts.firefox.com/oauth?state=first",
        };
        using var coordinator = Create(runtime, new FakeSecretStore());
        await coordinator.InitializeAsync();
        await coordinator.BeginOAuthAsync();

        var snapshot = await coordinator.AbandonOAuthAsync();
        Assert.AreEqual(FirefoxAccountState.Disconnected, snapshot.AccountState);

        runtime.BeginOAuthValue = "https://accounts.firefox.com/oauth?state=second";
        await coordinator.BeginOAuthAsync();
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(
            () => coordinator.CompleteOAuthAsync(
                new Uri("xanh-browser://accounts/oauth?code=code&state=first")));
        snapshot = await coordinator.CompleteOAuthAsync(
            new Uri("xanh-browser://accounts/oauth?code=code&state=second"));
        Assert.AreEqual(FirefoxAccountState.Connected, snapshot.AccountState);
    }

    [TestMethod]
    public async Task AbandoningAuthenticatingRuntimeDeletesSyncStateBeforeAccountState()
    {
        var runtime = new FakeRuntime();
        var store = new FakeSecretStore();
        using var coordinator = Create(runtime, store);
        await coordinator.InitializeAsync();
        await coordinator.BeginOAuthAsync();
        runtime.State = FirefoxAccountState.Authenticating;

        await coordinator.AbandonOAuthAsync();

        CollectionAssert.AreEqual(
            new[] { FirefoxSyncSecret.SyncState, FirefoxSyncSecret.AccountState },
            store.Deletes.TakeLast(2).ToArray());
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

        var draft = new FirefoxCredentialDraft(
            "new@example.org",
            "new-secret",
            "username",
            "password");
        var added = await coordinator.AddCredentialAsync(context, draft);
        Assert.AreEqual("added-credential", added.Id);
        Assert.AreEqual(1, runtime.AddCredentialCalls);
        Assert.AreEqual(draft, runtime.LastCredentialDraft);

        var updatedDraft = draft with
        {
            Username = "updated@example.org",
            Password = "updated-secret",
        };
        var updated = await coordinator.UpdateCredentialAsync(
            added.Id,
            context,
            updatedDraft);
        Assert.AreEqual(added.Id, updated.Id);
        Assert.AreEqual("updated@example.org", updated.Username);
        Assert.AreEqual(1, runtime.UpdateCredentialCalls);
        Assert.IsTrue(await coordinator.DeleteCredentialAsync(added.Id, context));
        Assert.AreEqual(1, runtime.DeleteCredentialCalls);

        var privateContext = context with { IsPrivate = true };
        await Assert.ThrowsExceptionAsync<ArgumentException>(
            () => coordinator.AddCredentialAsync(privateContext, draft));
        Assert.AreEqual(1, runtime.AddCredentialCalls);

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

    [TestMethod]
    public async Task RemoteTabsAreTypedBoundedAndRequireAnExplicitHostOpen()
    {
        var runtime = new FakeRuntime
        {
            State = FirefoxAccountState.Connected,
            RemoteTabsResult = """
                [{"device_id":"device-id","device_name":"Work Desktop","device_kind":"desktop","last_modified_epoch_millis":1700000000001,"tabs":[{"title":"Example","url_history":["https://example.org/current","https://example.org/previous"],"icon_url":null,"last_used_epoch_millis":1700000000000,"is_pinned":false}]}]
                """,
        };
        using var coordinator = Create(runtime, new FakeSecretStore());
        await coordinator.InitializeAsync();

        var devices = await coordinator.RemoteTabsAsync();

        Assert.AreEqual(1, devices.Count);
        Assert.AreEqual("device-id", devices[0].DeviceId);
        Assert.AreEqual("https://example.org/current", devices[0].Tabs[0].PrimaryUri?.AbsoluteUri);

        runtime.RemoteTabsResult = runtime.RemoteTabsResult.Replace(
            "https://example.org/current",
            "javascript:alert(1)",
            StringComparison.Ordinal);
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(() =>
            coordinator.RemoteTabsAsync());

        runtime.RemoteTabsResult = JsonSerializer.Serialize(
            Enumerable.Range(0, 2).Select(device => new
            {
                device_id = $"device-{device}",
                device_name = $"Device {device}",
                device_kind = "desktop",
                last_modified_epoch_millis = 1,
                tabs = Enumerable.Range(0, FirefoxRemoteTabsPolicy.MaximumTabsTotal / 2 + 1)
                    .Select(index => new
                    {
                        title = $"Tab {index}",
                        url_history = new[] { $"https://example.org/{device}/{index}" },
                        icon_url = (string?)null,
                        last_used_epoch_millis = 1,
                        is_pinned = false,
                    }).ToArray(),
            }).ToArray());
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(() =>
            coordinator.RemoteTabsAsync());

        runtime.RemoteTabsResult = JsonSerializer.Serialize(
            Enumerable.Range(0, FirefoxRemoteTabsPolicy.MaximumDevices + 1).Select(device => new
            {
                device_id = $"device-{device}",
                device_name = $"Device {device}",
                device_kind = "desktop",
                last_modified_epoch_millis = 1,
                tabs = new[]
                {
                    new
                    {
                        title = "Tab",
                        url_history = new[] { $"https://example.org/{device}" },
                        icon_url = (string?)null,
                        last_used_epoch_millis = 1,
                        is_pinned = false,
                    },
                },
            }).ToArray());
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(() =>
            coordinator.RemoteTabsAsync());

        runtime.RemoteTabsResult = "[\"" + new string(
            'x', FirefoxRemoteTabsPolicy.MaximumJsonBytes) + "\"]";
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(() =>
            coordinator.RemoteTabsAsync());
    }

    private static FirefoxSyncCoordinator Create(
        FakeRuntime runtime,
        FakeSecretStore store,
        Func<DateTimeOffset>? clock = null,
        string? profileDirectory = null,
        FirefoxSyncConfiguration? configuration = null) => new(
            configuration ?? Configuration(),
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
        public Exception? SyncError { get; set; }
        public Exception? UnlockError { get; set; }
        public Exception? BeginOAuthError { get; set; }
        public string BeginOAuthValue { get; set; } =
            "https://accounts.firefox.com/oauth?state=expected-state";
        public int BeginOAuthCalls { get; private set; }
        public int SyncCalls { get; private set; }
        public int DisconnectCalls { get; private set; }
        public int TouchCredentialCalls { get; private set; }
        public int AddCredentialCalls { get; private set; }
        public int UpdateCredentialCalls { get; private set; }
        public int DeleteCredentialCalls { get; private set; }
        public int CompleteOAuthCalls { get; private set; }
        public int DisposeCalls { get; private set; }
        public ManualResetEventSlim? CompleteOAuthEntered { get; set; }
        public ManualResetEventSlim? CompleteOAuthContinue { get; set; }
        public FirefoxCredentialDraft? LastCredentialDraft { get; private set; }
        public int MaximumConcurrentCalls => _maximumConcurrentCalls;
        public bool LastDisconnectDeletedLocal { get; private set; }
        public string BookmarksResult { get; set; } = "[]";
        public string HistoryResult { get; set; } = "[]";
        public string RemoteTabsResult { get; set; } = "[]";
        public string LastTabsPayload { get; private set; } = "";
        public string LastBookmarkUpdate { get; private set; } = "";
        public string LastHistoryPayload { get; private set; } = "";
        public string? LastDeletedBookmarkGuid { get; private set; }
        public long LastDeletedHistoryTimestamp { get; private set; }
        public FirefoxAccountState AccountState => State;
        public bool VaultUnlocked { get; private set; }
        public string CredentialsResult { get; set; } = "[]";

        public FirefoxAccountState Initialize() => State;
        public string BeginOAuth()
        {
            BeginOAuthCalls++;
            if (BeginOAuthError is not null) throw BeginOAuthError;
            return BeginOAuthValue;
        }
        public FirefoxAccountState CompleteOAuth(string code, string state)
        {
            CompleteOAuthCalls++;
            CompleteOAuthEntered?.Set();
            CompleteOAuthContinue?.Wait();
            return State = FirefoxAccountState.Connected;
        }
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
                if (SyncError is not null) throw SyncError;
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

        public string RemoteTabsJson() => RemoteTabsResult;
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
        public string AddCredential(string credentialJson)
        {
            AddCredentialCalls++;
            LastCredentialDraft = ParseCredentialDraft(credentialJson);
            return CredentialResult("added-credential", LastCredentialDraft);
        }

        public string UpdateCredential(string credentialJson)
        {
            UpdateCredentialCalls++;
            using var payload = JsonDocument.Parse(credentialJson);
            LastCredentialDraft = ParseCredentialDraft(payload.RootElement);
            return CredentialResult(
                payload.RootElement.GetProperty("id").GetString()!,
                LastCredentialDraft);
        }

        public bool DeleteCredential(string id, string contextJson)
        {
            DeleteCredentialCalls++;
            return true;
        }

        public void TouchCredential(string id, string contextJson) => TouchCredentialCalls++;

        public void Disconnect(bool deleteLocal)
        {
            DisconnectCalls++;
            LastDisconnectDeletedLocal = deleteLocal;
            State = FirefoxAccountState.Disconnected;
            VaultUnlocked = false;
        }

        public void Dispose() => DisposeCalls++;

        private static FirefoxCredentialDraft ParseCredentialDraft(string value)
        {
            using var payload = JsonDocument.Parse(value);
            return ParseCredentialDraft(payload.RootElement);
        }

        private static FirefoxCredentialDraft ParseCredentialDraft(JsonElement payload) => new(
            payload.GetProperty("username").GetString()!,
            payload.GetProperty("password").GetString()!,
            payload.GetProperty("username_field").GetString()!,
            payload.GetProperty("password_field").GetString()!);

        private static string CredentialResult(string id, FirefoxCredentialDraft draft) =>
            JsonSerializer.Serialize(new
            {
                id,
                origin = "https://example.org",
                form_action_origin = "https://example.org",
                username_field = draft.UsernameField,
                password_field = draft.PasswordField,
                username = draft.Username,
                password = draft.Password,
                time_created_epoch_millis = 1,
                time_password_changed_epoch_millis = 1,
                time_last_used_epoch_millis = 1,
                times_used = 0,
            });
    }

    private sealed class FakeSecretStore : IFirefoxSyncSecretStore
    {
        public ConcurrentDictionary<FirefoxSyncSecret, string> Values { get; } = new();
        public List<FirefoxSyncSecret> Writes { get; } = new();
        public List<FirefoxSyncSecret> Deletes { get; } = new();
        public int DeleteFailuresRemaining { get; set; }
        public HashSet<FirefoxSyncSecret> TargetedDeleteFailures { get; } = [];

        public Task<string?> ReadAsync(
            FirefoxSyncSecret secret,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(Values.TryGetValue(secret, out var value) ? value : null);

        public Task WriteAsync(
            FirefoxSyncSecret secret,
            string value,
            CancellationToken cancellationToken = default)
        {
            Writes.Add(secret);
            Values[secret] = value;
            return Task.CompletedTask;
        }

        public Task DeleteAsync(
            FirefoxSyncSecret secret,
            CancellationToken cancellationToken = default)
        {
            Deletes.Add(secret);
            if (TargetedDeleteFailures.Remove(secret))
                throw new IOException("injected targeted secure-store failure");
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
