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
}
