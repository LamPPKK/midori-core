using Microsoft.VisualStudio.TestTools.UnitTesting;
using XanhBrowser.Core;

namespace XanhBrowser.Core.Tests;

[TestClass]
public sealed class WebView2RuntimePolicyTests
{
    [DataTestMethod]
    [DataRow("151.0.4129.50")]
    [DataRow("151.0.4129.51")]
    [DataRow("151.1.0.0")]
    [DataRow("152.0.0.0")]
    public void AcceptsMinimumOrNewerStableRuntime(string version)
    {
        Assert.IsTrue(WebView2RuntimePolicy.IsSupported(version));
    }

    [DataTestMethod]
    [DataRow(null)]
    [DataRow("")]
    [DataRow("150.0.4129.50")]
    [DataRow("151.0.4129.49")]
    [DataRow("151.0.4129")]
    [DataRow("151.0.4129.50 beta")]
    [DataRow("151.0.4129.50 dev")]
    [DataRow("151.0.4129.50 canary")]
    [DataRow("151.00.4129.50")]
    [DataRow("151.0.4129.-1")]
    [DataRow("151.0.4129.2147483648")]
    [DataRow(" 151.0.4129.50")]
    public void RejectsOldNonStableOrMalformedRuntime(string? version)
    {
        Assert.IsFalse(WebView2RuntimePolicy.IsSupported(version));
    }

    [TestMethod]
    public void MinimumVersionMatchesReleaseBaseline()
    {
        Assert.AreEqual("151.0.4129.50", WebView2RuntimePolicy.MinimumVersion);
    }
}
