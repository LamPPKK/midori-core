using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace XanhBrowser.Core;

public enum FirefoxSyncSecret
{
    AccountState,
    SyncState,
    LoginsKey,
    Schedule,
    EngineSelection,
    DisconnectIntent,
}

public interface IFirefoxSyncSecretStore
{
    Task<string?> ReadAsync(FirefoxSyncSecret secret, CancellationToken cancellationToken = default);
    Task WriteAsync(FirefoxSyncSecret secret, string value, CancellationToken cancellationToken = default);
    Task DeleteAsync(FirefoxSyncSecret secret, CancellationToken cancellationToken = default);
    Task<bool> VerifyUserPresenceAsync(string reason, CancellationToken cancellationToken = default);
}

public sealed record FirefoxOAuthLaunch(Uri AuthorizationUri, string AccountDomain);

public sealed record FirefoxSyncHostSnapshot(
    FirefoxAccountState AccountState,
    FirefoxSyncStatus Status,
    IReadOnlySet<FirefoxSyncEngine> EnabledEngines,
    bool VaultUnlocked,
    DateTimeOffset? LastSync,
    DateTimeOffset? NextAllowed,
    string Detail);

public sealed class FirefoxSyncCoordinator : IDisposable
{
    private static readonly FirefoxSyncEngine[] AllEngines =
    {
        FirefoxSyncEngine.Bookmarks,
        FirefoxSyncEngine.History,
        FirefoxSyncEngine.Tabs,
        FirefoxSyncEngine.Passwords,
    };

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    private readonly FirefoxSyncConfiguration _configuration;
    private readonly string _profileDirectory;
    private readonly IFirefoxSyncRuntimeFactory _runtimeFactory;
    private readonly IFirefoxSyncSecretStore _secrets;
    private readonly Func<DateTimeOffset> _clock;
    private readonly SemaphoreSlim _operation = new(1, 1);
    private readonly HashSet<FirefoxSyncEngine> _enabledEngines = new(AllEngines);
    private IFirefoxSyncRuntime? _runtime;
    private FirefoxSyncSchedule _schedule = new();
    private bool? _pendingDisconnectDeleteLocal;
    private bool _nativeDisconnectCompleted;
    private DateTimeOffset? _vaultLastActivity;
    private bool _disposed;

    public FirefoxSyncCoordinator(
        FirefoxSyncConfiguration configuration,
        string profileDirectory,
        IFirefoxSyncRuntimeFactory runtimeFactory,
        IFirefoxSyncSecretStore secrets,
        Func<DateTimeOffset>? clock = null)
    {
        _configuration = configuration;
        _profileDirectory = Path.GetFullPath(profileDirectory);
        _runtimeFactory = runtimeFactory;
        _secrets = secrets;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        Snapshot = new(
            FirefoxAccountState.Disconnected,
            FirefoxSyncStatus.Idle,
            new HashSet<FirefoxSyncEngine>(_enabledEngines),
            false,
            null,
            null,
            "Firefox Sync is not initialized");
    }

    public FirefoxSyncHostSnapshot Snapshot { get; private set; }
    public event EventHandler<FirefoxSyncHostSnapshot>? SnapshotChanged;

    public async Task<FirefoxSyncHostSnapshot> InitializeAsync(
        CancellationToken cancellationToken = default)
    {
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            if (_runtime is not null) return Snapshot;
            _configuration.Validate();
            Directory.CreateDirectory(_profileDirectory);
            var account = await _secrets.ReadAsync(
                FirefoxSyncSecret.AccountState, cancellationToken).ConfigureAwait(false);
            var syncState = await _secrets.ReadAsync(
                FirefoxSyncSecret.SyncState, cancellationToken).ConfigureAwait(false);
            var scheduleJson = await _secrets.ReadAsync(
                FirefoxSyncSecret.Schedule, cancellationToken).ConfigureAwait(false);
            _schedule = ParseSchedule(scheduleJson);
            var enginesJson = await _secrets.ReadAsync(
                FirefoxSyncSecret.EngineSelection, cancellationToken).ConfigureAwait(false);
            RestoreEngineSelection(enginesJson);
            var disconnectIntent = await _secrets.ReadAsync(
                FirefoxSyncSecret.DisconnectIntent, cancellationToken).ConfigureAwait(false);
            _pendingDisconnectDeleteLocal = ParseDisconnectIntent(disconnectIntent);

            _runtime = await Task.Run(
                () => _runtimeFactory.Open(
                    _configuration.ToNativeJson(),
                    _profileDirectory,
                    null,
                    account,
                    syncState),
                cancellationToken).ConfigureAwait(false);
            try
            {
                var state = await Task.Run(_runtime.Initialize, cancellationToken).ConfigureAwait(false);
                await PersistRuntimeStateAsync(cancellationToken).ConfigureAwait(false);
                Publish(state, FirefoxSyncStatus.Idle, "Firefox Sync is ready");
                if (_pendingDisconnectDeleteLocal is { } deleteLocal)
                    await DisconnectLockedAsync(deleteLocal, cancellationToken).ConfigureAwait(false);
                return Snapshot;
            }
            catch
            {
                _runtime.Dispose();
                _runtime = null;
                throw;
            }
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task<FirefoxOAuthLaunch> BeginOAuthAsync(
        CancellationToken cancellationToken = default)
    {
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            var value = await Task.Run(runtime.BeginOAuth, cancellationToken).ConfigureAwait(false);
            if (!Uri.TryCreate(value, UriKind.Absolute, out var authorization)
                || !authorization.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
                || !string.IsNullOrEmpty(authorization.UserInfo))
                throw new InvalidOperationException("Firefox Accounts returned an unsafe authorization URL.");
            await PersistRuntimeStateAsync(cancellationToken).ConfigureAwait(false);
            Publish(FirefoxAccountState.Authenticating, FirefoxSyncStatus.Idle,
                "Waiting for the system browser to complete sign-in");
            return new FirefoxOAuthLaunch(authorization, _configuration.AccountsUri.IdnHost);
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task<FirefoxSyncHostSnapshot> CompleteOAuthAsync(
        Uri callback,
        CancellationToken cancellationToken = default)
    {
        var (code, state) = ParseOAuthCallback(_configuration.RedirectUri, callback);
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            var accountState = await Task.Run(
                () => runtime.CompleteOAuth(code, state), cancellationToken).ConfigureAwait(false);
            await PersistRuntimeStateAsync(cancellationToken).ConfigureAwait(false);
            Publish(accountState, FirefoxSyncStatus.Idle, "Firefox Accounts sign-in completed");
            if (accountState == FirefoxAccountState.Connected)
                await SyncLockedAsync(FirefoxSyncReason.Startup, ignoreInterval: true, cancellationToken)
                    .ConfigureAwait(false);
            return Snapshot;
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task<FirefoxSyncHostSnapshot> SyncAsync(
        FirefoxSyncReason reason,
        CancellationToken cancellationToken = default)
    {
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await SyncLockedAsync(reason, ignoreInterval: false, cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            _operation.Release();
        }
    }

    public void NotifyLocalChange()
    {
        ThrowIfDisposed();
        _schedule = _schedule with { LocalChange = _clock() };
    }

    public async Task SetEngineEnabledAsync(
        FirefoxSyncEngine engine,
        bool enabled,
        CancellationToken cancellationToken = default)
    {
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            if (enabled) _enabledEngines.Add(engine);
            else _enabledEngines.Remove(engine);
            await _secrets.WriteAsync(
                FirefoxSyncSecret.EngineSelection,
                JsonSerializer.Serialize(_enabledEngines.Select(EngineName).Order(StringComparer.Ordinal)),
                cancellationToken).ConfigureAwait(false);
            Publish(Snapshot.AccountState, Snapshot.Status, Snapshot.Detail);
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task<bool> UnlockVaultAsync(CancellationToken cancellationToken = default)
    {
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            if (!await _secrets.VerifyUserPresenceAsync(
                    "Unlock passwords saved in Xanh Browser", cancellationToken).ConfigureAwait(false))
                return false;

            var key = await _secrets.ReadAsync(
                FirefoxSyncSecret.LoginsKey, cancellationToken).ConfigureAwait(false);
            var generated = key is null;
            if (generated)
            {
                DeleteUnreadableLoginsDatabase();
                key = await Task.Run(
                    _runtimeFactory.GenerateLocalLoginsKey, cancellationToken).ConfigureAwait(false);
            }
            try
            {
                var usableKey = key ?? throw new InvalidOperationException(
                    "The device-local password-vault key is unavailable.");
                await Task.Run(() => runtime.UnlockVault(usableKey), cancellationToken).ConfigureAwait(false);
                if (generated)
                    await _secrets.WriteAsync(
                        FirefoxSyncSecret.LoginsKey, usableKey, cancellationToken).ConfigureAwait(false);
            }
            catch
            {
                if (runtime.VaultUnlocked) runtime.LockVault();
                throw;
            }
            _vaultLastActivity = _clock();
            Publish(runtime.AccountState, Snapshot.Status, "Password vault unlocked for five minutes");
            return true;
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task LockVaultAsync(CancellationToken cancellationToken = default)
    {
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            await Task.Run(runtime.LockVault, cancellationToken).ConfigureAwait(false);
            _vaultLastActivity = null;
            Publish(runtime.AccountState, Snapshot.Status, "Password vault locked");
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task<bool> TouchVaultAsync(CancellationToken cancellationToken = default)
    {
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            var now = _clock();
            if (_runtime?.VaultUnlocked != true
                || _vaultLastActivity is not { } last
                || now - last >= FirefoxSyncVaultSession.IdleTimeout)
                return false;
            _vaultLastActivity = now;
            return true;
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task<bool> LockVaultIfIdleAsync(CancellationToken cancellationToken = default)
    {
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            if (_vaultLastActivity is not { } last
                || _clock() - last < FirefoxSyncVaultSession.IdleTimeout)
                return false;
            await Task.Run(runtime.LockVault, cancellationToken).ConfigureAwait(false);
            _vaultLastActivity = null;
            Publish(runtime.AccountState, Snapshot.Status, "Password vault locked");
            return true;
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task<IReadOnlyList<FirefoxRemoteTabsDevice>> RemoteTabsAsync(
        CancellationToken cancellationToken = default)
    {
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            var value = await Task.Run(
                runtime.RemoteTabsJson, cancellationToken).ConfigureAwait(false);
            var devices = ParseBoundedArray<FirefoxRemoteTabsDevice>(
                value,
                FirefoxRemoteTabsPolicy.MaximumJsonBytes,
                FirefoxRemoteTabsPolicy.MaximumDevices,
                device => device is not null && device.IsSafe,
                "remote-tabs");
            var totalTabs = 0;
            foreach (var device in devices)
                totalTabs = checked(totalTabs + device.Tabs.Length);
            if (totalTabs > FirefoxRemoteTabsPolicy.MaximumTabsTotal)
                throw new InvalidOperationException(
                    "Firefox Sync returned too many remote tabs.");
            return devices;
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task UpdateLocalTabsAsync(
        IReadOnlyList<FirefoxLocalTab> tabs,
        bool markLocalChange = true,
        CancellationToken cancellationToken = default)
    {
        if (tabs.Count > FirefoxPlacesPolicy.MaximumLocalTabs)
            throw new ArgumentException("Local tab payload exceeds 500 records.");
        var values = tabs.Select(tab =>
        {
            if (tab.UrlHistory.Count is < 1 or > 10
                || tab.UrlHistory.Any(uri => !FirefoxPlacesPolicy.IsAllowedWebUri(uri))
                || tab.IconUri is { } icon && !FirefoxPlacesPolicy.IsAllowedWebUri(icon)
                || tab.LastUsed.ToUnixTimeMilliseconds() < 0)
                throw new ArgumentException("Local tab payload is unsafe.");
            return new
            {
                title = FirefoxPlacesPolicy.SanitizeTitle(
                    tab.Title,
                    tab.UrlHistory[0].AbsoluteUri),
                url_history = tab.UrlHistory.Select(uri => uri.AbsoluteUri).ToArray(),
                icon_url = tab.IconUri?.AbsoluteUri,
                last_used_epoch_millis = tab.LastUsed.ToUnixTimeMilliseconds(),
                is_private = tab.IsPrivate,
                is_pinned = tab.IsPinned,
            };
        }).ToArray();
        var payload = JsonSerializer.Serialize(values, JsonOptions);
        if (Encoding.UTF8.GetByteCount(payload) > 4 * 1_024 * 1_024)
            throw new ArgumentException("Local tab payload exceeds 4 MiB.");

        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            var resultJson = await Task.Run(
                () => runtime.UpdateLocalTabs(payload), cancellationToken).ConfigureAwait(false);
            var result = JsonSerializer.Deserialize<LocalTabsUpdateResult>(resultJson, JsonOptions)
                ?? throw new InvalidOperationException("Firefox Sync returned no local-tab result.");
            var privateCount = values.Count(value => value.is_private);
            if (result.AcceptedCount + result.SkippedPrivateCount != values.Length
                || result.SkippedPrivateCount != privateCount)
                throw new InvalidOperationException("Firefox Sync returned an inconsistent local-tab result.");
            if (markLocalChange)
                await MarkLocalChangeLockedAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task<IReadOnlyList<FirefoxBookmarkRecord>> BookmarksAsync(
        FirefoxBookmarkRoot root = FirefoxBookmarkRoot.Mobile,
        CancellationToken cancellationToken = default)
    {
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            var value = await Task.Run(
                () => runtime.BookmarksJson((int)root), cancellationToken).ConfigureAwait(false);
            return ParseBoundedArray<FirefoxBookmarkRecord>(
                value,
                16 * 1_024 * 1_024,
                FirefoxPlacesPolicy.MaximumBookmarks,
                record => record.IsSafe,
                "bookmark");
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task<string> CreateBookmarkAsync(
        Uri url,
        string? title,
        FirefoxBookmarkRoot root = FirefoxBookmarkRoot.Mobile,
        bool isPrivate = false,
        CancellationToken cancellationToken = default)
    {
        if (isPrivate) throw new ArgumentException("Private tabs cannot create bookmarks.");
        if (!FirefoxPlacesPolicy.IsAllowedWebUri(url))
            throw new ArgumentException("Bookmark URL is unsafe.");
        var safeTitle = FirefoxPlacesPolicy.SanitizeTitle(title, url.AbsoluteUri);

        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            var parentGuid = runtime.BookmarkRootGuid((int)root);
            if (!FirefoxPlacesPolicy.IsGuid(parentGuid))
                throw new InvalidOperationException("Firefox Sync returned an invalid bookmark root.");
            var payload = JsonSerializer.Serialize(new
            {
                parent_guid = parentGuid,
                position = (uint?)null,
                kind = "bookmark",
                title = safeTitle,
                url = url.AbsoluteUri,
                date_added_epoch_millis = _clock().ToUnixTimeMilliseconds(),
                last_modified_epoch_millis = (long?)null,
                is_private = false,
            }, JsonOptions);
            var guid = await Task.Run(
                () => runtime.CreateBookmark(payload), cancellationToken).ConfigureAwait(false);
            if (!FirefoxPlacesPolicy.IsGuid(guid))
                throw new InvalidOperationException("Firefox Sync returned an invalid bookmark GUID.");
            await MarkLocalChangeLockedAsync(cancellationToken).ConfigureAwait(false);
            return guid;
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task RenameBookmarkAsync(
        string guid,
        string title,
        bool isPrivate = false,
        CancellationToken cancellationToken = default)
    {
        if (isPrivate) throw new ArgumentException("Private tabs cannot update bookmarks.");
        if (!FirefoxPlacesPolicy.IsGuid(guid))
            throw new ArgumentException("Bookmark GUID is invalid.");
        var safeTitle = FirefoxPlacesPolicy.SanitizeTitle(title, "Untitled");
        var payload = JsonSerializer.Serialize(new
        {
            guid,
            title = safeTitle,
            url = (string?)null,
            parent_guid = (string?)null,
            position = (uint?)null,
            is_private = false,
        }, JsonOptions);

        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            await Task.Run(() => runtime.UpdateBookmark(payload), cancellationToken).ConfigureAwait(false);
            await MarkLocalChangeLockedAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task<bool> DeleteBookmarkAsync(
        string guid,
        bool isPrivate = false,
        CancellationToken cancellationToken = default)
    {
        if (isPrivate) throw new ArgumentException("Private tabs cannot delete bookmarks.");
        if (!FirefoxPlacesPolicy.IsGuid(guid))
            throw new ArgumentException("Bookmark GUID is invalid.");

        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            var deleted = await Task.Run(
                () => runtime.DeleteBookmark(guid, false), cancellationToken).ConfigureAwait(false);
            if (deleted) await MarkLocalChangeLockedAsync(cancellationToken).ConfigureAwait(false);
            return deleted;
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task RecordHistoryAsync(
        Uri url,
        string? title,
        DateTimeOffset visitedAt,
        FirefoxHistoryTransition transition = FirefoxHistoryTransition.Link,
        bool isPrivate = false,
        CancellationToken cancellationToken = default)
    {
        if (!FirefoxPlacesPolicy.IsAllowedWebUri(url))
            throw new ArgumentException("History URL is unsafe.");
        if (visitedAt.ToUnixTimeMilliseconds() <= 0)
            throw new ArgumentException("History timestamp is invalid.");
        if (isPrivate) return;
        var payload = JsonSerializer.Serialize(new[]
        {
            new
            {
                url = url.AbsoluteUri,
                title = FirefoxPlacesPolicy.SanitizeTitle(title, url.AbsoluteUri),
                visited_at_epoch_millis = visitedAt.ToUnixTimeMilliseconds(),
                transition = FirefoxPlacesPolicy.TransitionName(transition),
                is_private = false,
            },
        }, JsonOptions);

        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            var resultJson = await Task.Run(
                () => runtime.RecordHistory(payload), cancellationToken).ConfigureAwait(false);
            var result = JsonSerializer.Deserialize<HistoryUpdateResult>(resultJson, JsonOptions)
                ?? throw new InvalidOperationException("Firefox Sync returned no history result.");
            if (result.AcceptedCount != 1 || result.SkippedPrivateCount != 0)
                throw new InvalidOperationException("Firefox Sync did not accept the history visit.");
            await MarkLocalChangeLockedAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task<IReadOnlyList<FirefoxHistoryVisitRecord>> RecentHistoryAsync(
        uint limit = FirefoxPlacesPolicy.MaximumHistoryResults,
        CancellationToken cancellationToken = default)
    {
        if (limit is 0 or > FirefoxPlacesPolicy.MaximumHistoryResults)
            throw new ArgumentOutOfRangeException(nameof(limit));
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            var value = await Task.Run(
                () => runtime.RecentHistoryJson(limit), cancellationToken).ConfigureAwait(false);
            return ParseBoundedArray<FirefoxHistoryVisitRecord>(
                value,
                8 * 1_024 * 1_024,
                checked((int)limit),
                record => record.IsSafe,
                "history");
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task DeleteHistoryVisitAsync(
        Uri url,
        long visitedAtEpochMillis,
        CancellationToken cancellationToken = default)
    {
        if (!FirefoxPlacesPolicy.IsAllowedWebUri(url)
            || !FirefoxPlacesPolicy.IsSafeTimestamp(visitedAtEpochMillis, allowZero: false))
            throw new ArgumentException("History visit identity is invalid.");
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            await Task.Run(
                () => runtime.DeleteHistoryVisit(url.AbsoluteUri, visitedAtEpochMillis),
                cancellationToken).ConfigureAwait(false);
            await MarkLocalChangeLockedAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task ClearHistoryAsync(CancellationToken cancellationToken = default)
    {
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            await Task.Run(runtime.ClearHistory, cancellationToken).ConfigureAwait(false);
            await MarkLocalChangeLockedAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task<IReadOnlyList<FirefoxCredentialRecord>> CredentialsAsync(
        CredentialAccessContext context,
        CancellationToken cancellationToken = default)
    {
        if (!context.IsAllowed) throw new ArgumentException("Credential context is not allowed.");
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            RequireUsableVault(runtime);
            var contextJson = context.ToNativeJson();
            var value = await Task.Run(
                () => runtime.CredentialsJson(contextJson), cancellationToken).ConfigureAwait(false);
            if (Encoding.UTF8.GetByteCount(value) > FirefoxCredentialPolicy.MaximumOutputJsonBytes)
                throw new InvalidOperationException("Firefox Sync credential result is too large.");
            var records = JsonSerializer.Deserialize<FirefoxCredentialRecord[]>(value, JsonOptions)
                ?? throw new InvalidOperationException("Firefox Sync returned an empty credential result.");
            if (records.Length > FirefoxCredentialPolicy.MaximumResults
                || records.Any(record => !record.IsAllowedFor(context)))
                throw new InvalidOperationException("Firefox Sync returned an unsafe credential result.");
            _vaultLastActivity = _clock();
            return records;
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task<FirefoxCredentialRecord> AddCredentialAsync(
        CredentialAccessContext context,
        FirefoxCredentialDraft draft,
        CancellationToken cancellationToken = default)
    {
        if (!draft.IsAllowedFor(context))
            throw new ArgumentException("Credential draft or context is not allowed.");
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            RequireUsableVault(runtime);
            var payload = SerializeCredentialMutation(context, draft);
            var value = await Task.Run(
                () => runtime.AddCredential(payload), cancellationToken).ConfigureAwait(false);
            var record = ParseCredentialMutationResult(value, context);
            _vaultLastActivity = _clock();
            await MarkLocalChangeLockedAsync(cancellationToken).ConfigureAwait(false);
            return record;
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task<FirefoxCredentialRecord> UpdateCredentialAsync(
        string id,
        CredentialAccessContext context,
        FirefoxCredentialDraft draft,
        CancellationToken cancellationToken = default)
    {
        if (!FirefoxCredentialPolicy.IsValidId(id) || !draft.IsAllowedFor(context))
            throw new ArgumentException("Credential ID, draft or context is not allowed.");
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            RequireUsableVault(runtime);
            var payload = SerializeCredentialMutation(context, draft, id);
            var value = await Task.Run(
                () => runtime.UpdateCredential(payload), cancellationToken).ConfigureAwait(false);
            var record = ParseCredentialMutationResult(value, context);
            if (!record.Id.Equals(id, StringComparison.Ordinal))
                throw new InvalidOperationException("Firefox Sync changed the selected credential ID.");
            _vaultLastActivity = _clock();
            await MarkLocalChangeLockedAsync(cancellationToken).ConfigureAwait(false);
            return record;
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task<bool> DeleteCredentialAsync(
        string id,
        CredentialAccessContext context,
        CancellationToken cancellationToken = default)
    {
        if (!FirefoxCredentialPolicy.IsValidId(id) || !context.IsAllowed)
            throw new ArgumentException("Credential ID or context is not allowed.");
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            RequireUsableVault(runtime);
            var contextJson = context.ToNativeJson();
            var deleted = await Task.Run(
                () => runtime.DeleteCredential(id, contextJson), cancellationToken)
                .ConfigureAwait(false);
            _vaultLastActivity = _clock();
            if (deleted) await MarkLocalChangeLockedAsync(cancellationToken).ConfigureAwait(false);
            return deleted;
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task TouchCredentialAsync(
        string id,
        CredentialAccessContext context,
        CancellationToken cancellationToken = default)
    {
        if (!FirefoxCredentialPolicy.IsValidId(id) || !context.IsAllowed)
            throw new ArgumentException("Credential ID or context is not allowed.");
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var runtime = RequireRuntime();
            RequireUsableVault(runtime);
            var contextJson = context.ToNativeJson();
            await Task.Run(
                () => runtime.TouchCredential(id, contextJson), cancellationToken).ConfigureAwait(false);
            _vaultLastActivity = _clock();
        }
        finally
        {
            _operation.Release();
        }
    }

    public async Task DisconnectAsync(
        bool deleteLocal,
        CancellationToken cancellationToken = default)
    {
        await _operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await DisconnectLockedAsync(deleteLocal, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _operation.Release();
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _runtime?.Dispose();
        _runtime = null;
        _operation.Dispose();
    }

    public static (string Code, string State) ParseOAuthCallback(string expectedRedirect, Uri callback)
    {
        if (!Uri.TryCreate(expectedRedirect, UriKind.Absolute, out var expected)
            || !SameCallbackEndpoint(expected, callback)
            || !string.IsNullOrEmpty(callback.Fragment)
            || !string.IsNullOrEmpty(callback.UserInfo))
            throw new ArgumentException("OAuth callback does not match the registered redirect URI.");

        var parameters = new Dictionary<string, string>(StringComparer.Ordinal);
        var query = callback.Query.StartsWith('?') ? callback.Query[1..] : callback.Query;
        foreach (var pair in query.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = pair.IndexOf('=');
            if (separator <= 0)
                throw new ArgumentException("OAuth callback query is malformed.");
            var name = Uri.UnescapeDataString(pair[..separator]);
            var value = Uri.UnescapeDataString(pair[(separator + 1)..]);
            if (name is not ("code" or "state") || string.IsNullOrEmpty(value)
                || !parameters.TryAdd(name, value))
                throw new ArgumentException("OAuth callback query is ambiguous.");
        }
        if (parameters.Count != 2
            || !parameters.TryGetValue("code", out var code)
            || !parameters.TryGetValue("state", out var state))
            throw new ArgumentException("OAuth callback is missing code or state.");
        return (code, state);
    }

    private async Task<FirefoxSyncHostSnapshot> SyncLockedAsync(
        FirefoxSyncReason reason,
        bool ignoreInterval,
        CancellationToken cancellationToken)
    {
        var runtime = RequireRuntime();
        var now = _clock();
        if (Snapshot.AccountState != FirefoxAccountState.Connected)
            throw new InvalidOperationException("Firefox Accounts sign-in is required.");
        if (_schedule.NextAllowed is { } next && now < next)
        {
            Publish(Snapshot.AccountState, FirefoxSyncStatus.BackedOff,
                $"Server backoff is active until {next:O}");
            return Snapshot;
        }
        if (!ignoreInterval && !_schedule.IsDue(reason, now)) return Snapshot;

        Publish(Snapshot.AccountState, FirefoxSyncStatus.Running, "Firefox Sync is running");
        var enginesJson = JsonSerializer.Serialize(
            _enabledEngines.Select(EngineName).Order(StringComparer.Ordinal));
        var resultJson = await Task.Run(
            () => runtime.Sync(reason, enginesJson), cancellationToken).ConfigureAwait(false);
        var result = JsonSerializer.Deserialize<SyncWireResult>(resultJson, JsonOptions)
            ?? throw new InvalidOperationException("Firefox Sync returned an empty result.");
        var status = ParseStatus(result.Status);
        DateTimeOffset? nextAllowed = result.NextSyncAllowedEpochSeconds is { } epoch
            ? DateTimeOffset.FromUnixTimeSeconds(checked((long)epoch))
            : null;
        _schedule = _schedule with
        {
            LastSync = status is FirefoxSyncStatus.Success or FirefoxSyncStatus.Partial ? now : _schedule.LastSync,
            NextAllowed = nextAllowed,
            LocalChange = status is FirefoxSyncStatus.Success or FirefoxSyncStatus.Partial
                ? null
                : _schedule.LocalChange,
        };
        await PersistRuntimeStateAsync(cancellationToken).ConfigureAwait(false);
        await PersistScheduleAsync(cancellationToken).ConfigureAwait(false);
        Publish(runtime.AccountState, status, StatusDetail(status));
        return Snapshot;
    }

    private async Task DisconnectLockedAsync(bool deleteLocal, CancellationToken cancellationToken)
    {
        var runtime = RequireRuntime();
        if (_pendingDisconnectDeleteLocal is { } pending && pending != deleteLocal)
            throw new InvalidOperationException(
                "A disconnect retry must keep the original local-data choice.");
        if (_pendingDisconnectDeleteLocal is null)
        {
            await _secrets.WriteAsync(
                FirefoxSyncSecret.DisconnectIntent,
                deleteLocal ? "delete-local" : "keep-local",
                cancellationToken).ConfigureAwait(false);
            _pendingDisconnectDeleteLocal = deleteLocal;
        }
        if (!_nativeDisconnectCompleted)
        {
            await Task.Run(() => runtime.Disconnect(deleteLocal), cancellationToken).ConfigureAwait(false);
            _nativeDisconnectCompleted = true;
        }

        var secrets = deleteLocal
            ? new[]
            {
                FirefoxSyncSecret.AccountState,
                FirefoxSyncSecret.SyncState,
                FirefoxSyncSecret.LoginsKey,
                FirefoxSyncSecret.Schedule,
                FirefoxSyncSecret.EngineSelection,
            }
            : new[]
            {
                FirefoxSyncSecret.AccountState,
                FirefoxSyncSecret.SyncState,
                FirefoxSyncSecret.Schedule,
            };
        foreach (var secret in secrets)
            await _secrets.DeleteAsync(secret, cancellationToken).ConfigureAwait(false);
        await _secrets.DeleteAsync(
            FirefoxSyncSecret.DisconnectIntent, cancellationToken).ConfigureAwait(false);

        _schedule = new();
        _vaultLastActivity = null;
        _pendingDisconnectDeleteLocal = null;
        _nativeDisconnectCompleted = false;
        Publish(FirefoxAccountState.Disconnected, FirefoxSyncStatus.Idle,
            deleteLocal ? "Firefox Sync data was removed from this device" : "Firefox Sync disconnected; local data was kept");
    }

    private async Task PersistRuntimeStateAsync(CancellationToken cancellationToken)
    {
        var runtime = RequireRuntime();
        var account = await Task.Run(runtime.AccountJson, cancellationToken).ConfigureAwait(false);
        await _secrets.WriteAsync(
            FirefoxSyncSecret.AccountState, account, cancellationToken).ConfigureAwait(false);
        var state = runtime.PersistedState();
        if (state is null)
            await _secrets.DeleteAsync(FirefoxSyncSecret.SyncState, cancellationToken).ConfigureAwait(false);
        else
            await _secrets.WriteAsync(
                FirefoxSyncSecret.SyncState, state, cancellationToken).ConfigureAwait(false);
    }

    private async Task MarkLocalChangeLockedAsync(CancellationToken cancellationToken)
    {
        _schedule = _schedule with { LocalChange = _clock() };
        await PersistScheduleAsync(cancellationToken).ConfigureAwait(false);
    }

    private static IReadOnlyList<T> ParseBoundedArray<T>(
        string value,
        int maximumBytes,
        int maximumItems,
        Func<T, bool> isSafe,
        string label)
    {
        if (Encoding.UTF8.GetByteCount(value) > maximumBytes)
            throw new InvalidOperationException($"Firefox Sync {label} result is too large.");
        T[] records;
        try
        {
            records = JsonSerializer.Deserialize<T[]>(value, JsonOptions)
                ?? throw new InvalidOperationException($"Firefox Sync returned no {label} result.");
        }
        catch (JsonException error)
        {
            throw new InvalidOperationException($"Firefox Sync returned malformed {label} data.", error);
        }
        if (records.Length > maximumItems || records.Any(record => !isSafe(record)))
            throw new InvalidOperationException($"Firefox Sync returned unsafe {label} data.");
        return records;
    }

    private static string SerializeCredentialMutation(
        CredentialAccessContext context,
        FirefoxCredentialDraft draft,
        string? id = null)
    {
        object payload = id is null
            ? new
            {
                Context = context.ToNativeValue(),
                draft.UsernameField,
                draft.PasswordField,
                draft.Username,
                draft.Password,
            }
            : new
            {
                Id = id,
                Context = context.ToNativeValue(),
                draft.UsernameField,
                draft.PasswordField,
                draft.Username,
                draft.Password,
            };
        var value = JsonSerializer.Serialize(payload, JsonOptions);
        if (Encoding.UTF8.GetByteCount(value) > FirefoxCredentialPolicy.MaximumInputJsonBytes)
            throw new ArgumentException("Credential input is too large.");
        return value;
    }

    private static FirefoxCredentialRecord ParseCredentialMutationResult(
        string value,
        CredentialAccessContext context)
    {
        if (Encoding.UTF8.GetByteCount(value) > FirefoxCredentialPolicy.MaximumOutputJsonBytes)
            throw new InvalidOperationException("Firefox Sync credential result is too large.");
        FirefoxCredentialRecord record;
        try
        {
            record = JsonSerializer.Deserialize<FirefoxCredentialRecord>(value, JsonOptions)
                ?? throw new InvalidOperationException(
                    "Firefox Sync returned no credential mutation result.");
        }
        catch (JsonException error)
        {
            throw new InvalidOperationException(
                "Firefox Sync returned malformed credential data.",
                error);
        }
        if (!record.IsAllowedFor(context))
            throw new InvalidOperationException("Firefox Sync returned an unsafe credential result.");
        return record;
    }

    private Task PersistScheduleAsync(CancellationToken cancellationToken) =>
        _secrets.WriteAsync(
            FirefoxSyncSecret.Schedule,
            JsonSerializer.Serialize(_schedule, JsonOptions),
            cancellationToken);

    private IFirefoxSyncRuntime RequireRuntime()
    {
        ThrowIfDisposed();
        return _runtime ?? throw new InvalidOperationException("Firefox Sync is not initialized.");
    }

    private void RequireUsableVault(IFirefoxSyncRuntime runtime)
    {
        var currentTime = _clock();
        if (!runtime.VaultUnlocked
            || _vaultLastActivity is not { } last
            || currentTime - last >= FirefoxSyncVaultSession.IdleTimeout)
        {
            if (runtime.VaultUnlocked) runtime.LockVault();
            _vaultLastActivity = null;
            Publish(runtime.AccountState, Snapshot.Status, "Password vault locked");
            throw new InvalidOperationException("The password vault is locked.");
        }
    }

    private void Publish(FirefoxAccountState accountState, FirefoxSyncStatus status, string detail)
    {
        var runtime = _runtime;
        Snapshot = new(
            accountState,
            status,
            new HashSet<FirefoxSyncEngine>(_enabledEngines),
            runtime?.VaultUnlocked ?? false,
            _schedule.LastSync,
            _schedule.NextAllowed,
            detail);
        SnapshotChanged?.Invoke(this, Snapshot);
    }

    private void DeleteUnreadableLoginsDatabase()
    {
        foreach (var suffix in new[] { "", "-wal", "-shm", "-journal" })
        {
            var path = Path.Combine(_profileDirectory, $"logins.sqlite{suffix}");
            if (File.Exists(path)) File.Delete(path);
        }
    }

    private static FirefoxSyncSchedule ParseSchedule(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return new();
        try
        {
            return JsonSerializer.Deserialize<FirefoxSyncSchedule>(value, JsonOptions) ?? new();
        }
        catch (JsonException)
        {
            return new();
        }
    }

    private void RestoreEngineSelection(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        try
        {
            var names = JsonSerializer.Deserialize<string[]>(value);
            if (names is null) return;
            var restored = names.Select(ParseEngineName).ToHashSet();
            _enabledEngines.Clear();
            _enabledEngines.UnionWith(restored);
        }
        catch (JsonException)
        {
            _enabledEngines.Clear();
            _enabledEngines.UnionWith(AllEngines);
        }
    }

    private static bool? ParseDisconnectIntent(string? value) => value switch
    {
        null => null,
        "delete-local" => true,
        "keep-local" => false,
        _ => throw new InvalidOperationException("Stored Firefox Sync disconnect intent is invalid."),
    };

    private static bool SameCallbackEndpoint(Uri expected, Uri callback) =>
        expected.Scheme.Equals(callback.Scheme, StringComparison.OrdinalIgnoreCase)
        && expected.IdnHost.Equals(callback.IdnHost, StringComparison.OrdinalIgnoreCase)
        && expected.Port == callback.Port
        && expected.AbsolutePath.Equals(callback.AbsolutePath, StringComparison.Ordinal)
        && string.IsNullOrEmpty(expected.Query);

    private static string EngineName(FirefoxSyncEngine engine) => engine switch
    {
        FirefoxSyncEngine.Bookmarks => "bookmarks",
        FirefoxSyncEngine.History => "history",
        FirefoxSyncEngine.Tabs => "tabs",
        FirefoxSyncEngine.Passwords => "passwords",
        _ => throw new ArgumentOutOfRangeException(nameof(engine)),
    };

    private static FirefoxSyncEngine ParseEngineName(string value) => value switch
    {
        "bookmarks" => FirefoxSyncEngine.Bookmarks,
        "history" => FirefoxSyncEngine.History,
        "tabs" => FirefoxSyncEngine.Tabs,
        "passwords" => FirefoxSyncEngine.Passwords,
        _ => throw new JsonException("Stored Firefox Sync engine selection is invalid."),
    };

    private static FirefoxSyncStatus ParseStatus(string value) => value switch
    {
        "success" => FirefoxSyncStatus.Success,
        "partial" => FirefoxSyncStatus.Partial,
        "network-error" => FirefoxSyncStatus.NetworkError,
        "auth-error" => FirefoxSyncStatus.AuthError,
        "backed-off" => FirefoxSyncStatus.BackedOff,
        _ => throw new InvalidOperationException("Firefox Sync returned an unknown status."),
    };

    private static string StatusDetail(FirefoxSyncStatus status) => status switch
    {
        FirefoxSyncStatus.Success => "Firefox Sync completed",
        FirefoxSyncStatus.Partial => "Firefox Sync completed with partial engine failures",
        FirefoxSyncStatus.NetworkError => "Firefox Sync could not reach the server",
        FirefoxSyncStatus.AuthError => "Firefox Accounts needs attention",
        FirefoxSyncStatus.BackedOff => "Firefox Sync is waiting for server backoff",
        _ => "Firefox Sync is idle",
    };

    private void ThrowIfDisposed()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(FirefoxSyncCoordinator));
    }

    private sealed record SyncWireResult(
        [property: JsonPropertyName("status")] string Status,
        [property: JsonPropertyName("next_sync_allowed_epoch_seconds")] ulong? NextSyncAllowedEpochSeconds);

    private sealed record LocalTabsUpdateResult(
        [property: JsonPropertyName("accepted_count")] int AcceptedCount,
        [property: JsonPropertyName("skipped_private_count")] int SkippedPrivateCount);

    private sealed record HistoryUpdateResult(
        [property: JsonPropertyName("accepted_count")] int AcceptedCount,
        [property: JsonPropertyName("skipped_private_count")] int SkippedPrivateCount);
}
