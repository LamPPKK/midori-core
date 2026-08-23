using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using XanhBrowser.Core;

namespace XanhBrowser.Core.Tests;

[TestClass]
public sealed class FirefoxSyncContractTests
{
    [TestMethod]
    public void SelfHostedEndpointsRequireHttps()
    {
        var config = new FirefoxSyncConfiguration(
            new Uri("http://accounts.example"),
            new Uri("https://sync.example/token"),
            "client",
            "xanh-browser://accounts/oauth",
            "Xanh Browser");
        Assert.ThrowsException<ArgumentException>(config.Validate);
    }

    [TestMethod]
    public void OAuthRedirectRejectsAmbiguousCallbacks()
    {
        FirefoxSyncConfiguration Config(string redirect) => new(
            new Uri("https://accounts.firefox.com"),
            null,
            "client",
            redirect,
            "Xanh Browser");

        Config("xanh-browser://accounts/oauth").Validate();
        foreach (var redirect in new[]
        {
            "http://example.test/oauth",
            "javascript:alert(1)",
            "xanh-browser://user@accounts/oauth",
            "xanh-browser://accounts/oauth?code=preset",
            "xanh-browser://accounts/oauth#secret",
        })
        {
            Assert.ThrowsException<ArgumentException>(() => Config(redirect).Validate(), redirect);
        }
    }

    [TestMethod]
    public void ScheduleDebouncesAndHonorsBackoff()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(100);
        var schedule = new FirefoxSyncSchedule(LocalChange: now);
        Assert.IsFalse(schedule.IsDue(FirefoxSyncReason.LocalChange, now.AddSeconds(29)));
        Assert.IsTrue(schedule.IsDue(FirefoxSyncReason.LocalChange, now.AddSeconds(30)));
        schedule = schedule with { NextAllowed = now.AddSeconds(200) };
        Assert.IsFalse(schedule.IsDue(FirefoxSyncReason.Manual, now.AddSeconds(199)));
    }

    [TestMethod]
    public void CredentialPolicyRejectsPrivateAndCrossOriginFrames()
    {
        var valid = new CredentialAccessContext(
            new Uri("https://example.org/login"),
            new Uri("https://example.org"),
            new Uri("https://example.org"),
            false,
            true);
        Assert.IsTrue(valid.IsAllowed);
        Assert.IsFalse((valid with { IsPrivate = true }).IsAllowed);
        Assert.IsFalse((valid with { FrameOrigin = new Uri("https://evil.example") }).IsAllowed);
        Assert.IsFalse((valid with { TopFrameOrigin = new Uri("https://user@example.org") }).IsAllowed);
        Assert.IsFalse((valid with { FrameOrigin = new Uri("https://example.org/path") }).IsAllowed);
        Assert.IsFalse((valid with { FrameOrigin = new Uri("relative", UriKind.Relative) }).IsAllowed);
        Assert.IsTrue((valid with { TopFrameOrigin = new Uri("https://example.org:443") }).IsAllowed);
        Assert.IsFalse((valid with
        {
            DocumentUri = new Uri($"https://example.org/{new string('x', 8_192)}"),
        }).IsAllowed);
        using var native = System.Text.Json.JsonDocument.Parse(valid.ToNativeJson());
        Assert.AreEqual(
            "https://example.org",
            native.RootElement.GetProperty("top_frame_origin").GetString());
    }

    [TestMethod]
    public void CredentialRecordRequiresBoundedExactOriginFormMetadata()
    {
        var context = new CredentialAccessContext(
            new Uri("https://example.org/login"),
            new Uri("https://example.org"),
            new Uri("https://example.org"),
            false,
            true);
        var valid = new FirefoxCredentialRecord(
            "credential-id", "https://example.org", "https://example.org",
            "username", "password", "person@example.org", "secret", 1, 1, 1, 1);
        Assert.IsTrue(valid.IsAllowedFor(context));
        Assert.IsFalse((valid with { Origin = "https://evil.example" }).IsAllowedFor(context));
        Assert.IsFalse((valid with { Id = "tài-khoản" }).IsAllowedFor(context));
        Assert.IsFalse((valid with { Password = "" }).IsAllowedFor(context));
        Assert.IsFalse((valid with { Password = new string('x', 4_097) }).IsAllowedFor(context));
        Assert.IsFalse((valid with { TimesUsed = -1 }).IsAllowedFor(context));
    }

    [TestMethod]
    public void CredentialMutationRequiresExplicitExactHttpsContextAndBoundedDraft()
    {
        var document = new Uri("https://bücher.example:443/login?next=%2F");
        var context = CredentialAccessContext.ExactTopLevel(
            document,
            isPrivate: false,
            userSelected: true);
        Assert.IsNotNull(context);
        Assert.AreEqual("https://xn--bcher-kva.example", context.CanonicalTopFrameOrigin);
        var valid = new FirefoxCredentialDraft(
            "person@example.org",
            "secret",
            "username",
            "password");
        Assert.IsTrue(valid.IsAllowedFor(context));
        Assert.IsFalse((valid with
        {
            Username = new string('u', FirefoxCredentialPolicy.MaximumUsernameBytes + 1),
        }).IsAllowedFor(context));
        Assert.IsFalse((valid with { Password = "secret\0tail" }).IsAllowedFor(context));
        Assert.IsNull(CredentialAccessContext.ExactTopLevel(
            document,
            isPrivate: true,
            userSelected: true));
        Assert.IsNull(CredentialAccessContext.ExactTopLevel(
            new Uri("http://example.org/login"),
            isPrivate: false,
            userSelected: true));
    }

    [TestMethod]
    public void VaultLocksAfterFiveMinutesAndOnDemand()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(100);
        var vault = new FirefoxSyncVaultSession();
        vault.Unlock(now);
        Assert.IsTrue(vault.IsUnlocked(now.AddSeconds(299)));
        Assert.IsFalse(vault.IsUnlocked(now.AddSeconds(300)));
        vault.Unlock(now);
        vault.Lock();
        Assert.IsFalse(vault.IsUnlocked(now));
    }

    [TestMethod]
    public void NativeTabsBridgeUsesTheReviewedCAbiSymbols()
    {
        string? EntryPoint(string method) => typeof(NativeMethods)
            .GetMethod(method, BindingFlags.Static | BindingFlags.NonPublic)
            ?.GetCustomAttribute<DllImportAttribute>()
            ?.EntryPoint;

        Assert.AreEqual(
            "xanh_sync_runtime_update_local_tabs",
            EntryPoint(nameof(NativeMethods.UpdateLocalTabs)));
        Assert.AreEqual(
            "xanh_sync_runtime_remote_tabs_json",
            EntryPoint(nameof(NativeMethods.RemoteTabsJson)));
    }

    [TestMethod]
    public void NativePlacesBridgeUsesTheReviewedCAbiSymbols()
    {
        string? EntryPoint(string method) => typeof(NativeMethods)
            .GetMethod(method, BindingFlags.Static | BindingFlags.NonPublic)
            ?.GetCustomAttribute<DllImportAttribute>()
            ?.EntryPoint;

        var expected = new Dictionary<string, string>
        {
            [nameof(NativeMethods.BookmarkRootGuid)] = "xanh_sync_bookmark_root_guid",
            [nameof(NativeMethods.CreateBookmark)] = "xanh_sync_runtime_create_bookmark",
            [nameof(NativeMethods.BookmarksJson)] = "xanh_sync_runtime_bookmarks_json",
            [nameof(NativeMethods.UpdateBookmark)] = "xanh_sync_runtime_update_bookmark",
            [nameof(NativeMethods.DeleteBookmark)] = "xanh_sync_runtime_delete_bookmark",
            [nameof(NativeMethods.RecordHistory)] = "xanh_sync_runtime_record_history",
            [nameof(NativeMethods.RecentHistoryJson)] = "xanh_sync_runtime_recent_history_json",
            [nameof(NativeMethods.DeleteHistoryVisit)] = "xanh_sync_runtime_delete_history_visit",
            [nameof(NativeMethods.ClearHistory)] = "xanh_sync_runtime_clear_history",
        };
        foreach (var pair in expected)
            Assert.AreEqual(pair.Value, EntryPoint(pair.Key), pair.Key);

        var delete = typeof(NativeMethods).GetMethod(
            nameof(NativeMethods.DeleteBookmark),
            BindingFlags.Static | BindingFlags.NonPublic)!;
        var privateFlag = delete.GetParameters()[2];
        Assert.AreEqual(typeof(bool), privateFlag.ParameterType);
        Assert.AreEqual(
            UnmanagedType.I1,
            privateFlag.GetCustomAttribute<MarshalAsAttribute>()?.Value);
    }

    [TestMethod]
    public void PlacesPolicyBoundsTitlesAndExactMutationIdentities()
    {
        Assert.IsTrue(FirefoxPlacesPolicy.IsGuid("bookmark1234"));
        Assert.IsFalse(FirefoxPlacesPolicy.IsGuid("bookmark1234-extra"));
        Assert.IsFalse(FirefoxPlacesPolicy.IsGuid("bookmark12\n4"));
        Assert.AreEqual(
            FirefoxPlacesPolicy.MaximumTitleBytes,
            System.Text.Encoding.UTF8.GetByteCount(
                FirefoxPlacesPolicy.SanitizeTitle(string.Concat(
                    Enumerable.Repeat("😀", 2_000)), "fallback")));
        Assert.AreEqual("before after", FirefoxPlacesPolicy.SanitizeTitle("before\nafter", "fallback"));

        var bookmark = new FirefoxBookmarkRecord(
            "bookmark1234", "mobile______", 0, "bookmark", "Example",
            "https://example.org/path", true, 1, 2);
        Assert.IsTrue(bookmark.IsSafe);
        Assert.IsNotNull(bookmark.OpenableUri);
        Assert.IsFalse((bookmark with { Guid = "bad-guid" }).IsSafe);
        Assert.IsFalse((bookmark with { Url = "javascript:alert(1)", IsOpenable = true }).IsSafe);

        var visit = new FirefoxHistoryVisitRecord(
            "https://example.org/path", "Example", 1, "link", false);
        Assert.IsTrue(visit.IsSafe);
        Assert.IsFalse((visit with { VisitedAtEpochMillis = 0 }).IsSafe);
        Assert.IsFalse((visit with { Transition = "unknown" }).IsSafe);
    }

    [TestMethod]
    public void RemoteTabsPolicyBoundsRecordsAndSanitizesDisplayLabels()
    {
        var tab = new FirefoxRemoteTab(
            "Visible\u202e\nTitle",
            ["https://example.org/current", "https://example.org/previous"],
            "https://example.org/icon.png",
            1_700_000_000_000,
            true);
        var device = new FirefoxRemoteTabsDevice(
            "device-id",
            "Work\u202d\nDesktop",
            "desktop",
            1_700_000_000_001,
            [tab]);

        Assert.IsTrue(tab.IsSafe);
        Assert.AreEqual("https://example.org/current", tab.PrimaryUri?.AbsoluteUri);
        Assert.AreEqual("Visible Title", tab.DisplayTitle);
        Assert.IsTrue(device.IsSafe);
        Assert.AreEqual(FirefoxRemoteDeviceKind.Desktop, device.Kind);
        Assert.AreEqual("Work Desktop", device.DisplayName);
        Assert.IsFalse((tab with { UrlHistory = ["javascript:alert(1)"] }).IsSafe);
        Assert.IsFalse((tab with
        {
            UrlHistory = Enumerable.Repeat(
                "https://example.org/", FirefoxRemoteTabsPolicy.MaximumUrlHistory + 1).ToArray(),
        }).IsSafe);
        Assert.IsFalse((tab with { IconUrl = "data:image/png;base64,AAAA" }).IsSafe);
        Assert.IsFalse((tab with { LastUsedEpochMillis = long.MaxValue }).IsSafe);
        Assert.IsFalse((device with { DeviceKind = "watch" }).IsSafe);
        Assert.IsFalse((device with
        {
            DeviceId = new string('x', FirefoxRemoteTabsPolicy.MaximumDeviceIdBytes + 1),
        }).IsSafe);
    }

    [TestMethod]
    public void NativeLoginsBridgeUsesTheReviewedCAbiSymbols()
    {
        string? EntryPoint(string method) => typeof(NativeMethods)
            .GetMethod(method, BindingFlags.Static | BindingFlags.NonPublic)
            ?.GetCustomAttribute<DllImportAttribute>()
            ?.EntryPoint;

        var expected = new Dictionary<string, string>
        {
            [nameof(NativeMethods.CredentialsJson)] = "xanh_sync_runtime_credentials_json",
            [nameof(NativeMethods.AddCredential)] = "xanh_sync_runtime_add_credential",
            [nameof(NativeMethods.UpdateCredential)] = "xanh_sync_runtime_update_credential",
            [nameof(NativeMethods.DeleteCredential)] = "xanh_sync_runtime_delete_credential",
            [nameof(NativeMethods.TouchCredential)] = "xanh_sync_runtime_touch_credential",
        };
        foreach (var pair in expected)
            Assert.AreEqual(pair.Value, EntryPoint(pair.Key), pair.Key);
    }
}
