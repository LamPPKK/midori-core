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
    [DataRow("data:text/html,hello")]
    public void RejectsUnsafeAddress(string address)
    {
        Assert.IsNull(AddressResolver.Resolve(address));
    }
}
