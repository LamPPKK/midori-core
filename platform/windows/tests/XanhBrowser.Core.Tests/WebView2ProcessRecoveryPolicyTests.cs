using Microsoft.VisualStudio.TestTools.UnitTesting;
using XanhBrowser.Core;

namespace XanhBrowser.Core.Tests;

[TestClass]
public sealed class WebView2ProcessRecoveryPolicyTests
{
    [DataTestMethod]
    [DataRow("https://example.com/path?query=value#fragment")]
    [DataRow("http://localhost:8080/")]
    [DataRow("about:blank")]
    public void SelectsValidatedTargetForFirstAutomaticRecovery(string address)
    {
        var current = new Uri(address);

        Assert.AreEqual(
            current,
            WebView2ProcessRecoveryPolicy.SelectAutomaticTarget(
                current,
                automaticRecoveryUsed: false));
    }

    [TestMethod]
    public void RejectsSecondAutomaticRecovery()
    {
        Assert.IsNull(WebView2ProcessRecoveryPolicy.SelectAutomaticTarget(
            new Uri("https://example.com/"),
            automaticRecoveryUsed: true));
    }

    [DataTestMethod]
    [DataRow("https://user:secret@example.com/")]
    [DataRow("file:///C:/Windows/System32/drivers/etc/hosts")]
    [DataRow("mailto:hello@example.com")]
    public void RejectsUnsafeRecoveryTarget(string address)
    {
        Assert.IsNull(WebView2ProcessRecoveryPolicy.SelectAutomaticTarget(
            new Uri(address),
            automaticRecoveryUsed: false));
    }

    [TestMethod]
    public void RejectsMissingRecoveryTarget()
    {
        Assert.IsNull(WebView2ProcessRecoveryPolicy.SelectAutomaticTarget(
            currentUri: null,
            automaticRecoveryUsed: false));
    }
}
