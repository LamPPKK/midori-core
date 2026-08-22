using Microsoft.VisualStudio.TestTools.UnitTesting;
using XanhBrowser.Core;

namespace XanhBrowser.Core.Tests;

[TestClass]
public sealed class AddressResolverTests
{
    [TestMethod]
    public void AcceptsHttpsAddress()
    {
        Assert.AreEqual(
            new NavigationTarget(NavigationTargetKind.Web, new Uri("https://example.com/path")),
            AddressResolver.Resolve("https://example.com/path"));
    }

    [TestMethod]
    public void UpgradesBareHostToHttps()
    {
        Assert.AreEqual(
            new NavigationTarget(NavigationTargetKind.Web, new Uri("https://example.com/docs")),
            AddressResolver.Resolve("example.com/docs"));
    }

    [TestMethod]
    public void ConvertsTextToSearch()
    {
        var target = AddressResolver.Resolve("xanh browser privacy");

        Assert.IsNotNull(target);
        Assert.AreEqual(NavigationTargetKind.Web, target.Kind);
        Assert.AreEqual("duckduckgo.com", target.Uri.Host);
        Assert.AreEqual("?q=xanh%20browser%20privacy", target.Uri.Query);
    }

    [TestMethod]
    public void AllowsSupportedExternalScheme()
    {
        var uri = new Uri("mailto:hello@example.com");
        Assert.AreEqual(
            new NavigationTarget(NavigationTargetKind.External, uri),
            AddressResolver.Resolve(uri.AbsoluteUri));
    }

    [DataTestMethod]
    [DataRow("javascript:alert(1)")]
    [DataRow("file:///C:/Windows/System32/drivers/etc/hosts")]
    [DataRow("https:///missing-host")]
    [DataRow("https://user:secret@example.com/")]
    [DataRow("https://foo_bar.example/")]
    [DataRow("https://example.com:70000/")]
    [DataRow("data:text/html,hello")]
    public void RejectsUnsafeAddress(string address)
    {
        Assert.IsNull(AddressResolver.Resolve(address));
    }

    [TestMethod]
    public void AcceptsCanonicalIdnAndIpHosts()
    {
        Assert.IsTrue(AddressResolver.IsAllowedWebUri(new Uri("https://bücher.example/")));
        Assert.IsTrue(AddressResolver.IsAllowedWebUri(new Uri("https://127.0.0.1/")));
        Assert.IsTrue(AddressResolver.IsAllowedWebUri(new Uri("https://[::1]/")));
        Assert.IsTrue(AddressResolver.IsAllowedWebUri(new Uri("http://localhost:8080/")));
    }

    [TestMethod]
    public void RejectsOversizedWebInputAndSearchOutput()
    {
        Assert.IsNull(AddressResolver.Resolve("https://example.com/" + new string('a', 8_193)));
        Assert.IsNull(AddressResolver.Resolve(new string('語', 3_000)));
    }

    [DataTestMethod]
    [DataRow("mailto:hello@example.com?subject=x%0d%0aBcc:test@example.com")]
    [DataRow("tel:%00+84123456789")]
    [DataRow("mailto:hello example@example.com")]
    public void RejectsUnsafeExternalAddress(string address)
    {
        Assert.IsFalse(AddressResolver.IsAllowedExternalUri(new Uri(address)));
    }

    [TestMethod]
    public void RejectsOversizedExternalAddress()
    {
        var uri = new Uri("mailto:user@example.com?subject=" + new string('a', 2_049));
        Assert.IsFalse(AddressResolver.IsAllowedExternalUri(uri));
    }
}
