using Microsoft.VisualStudio.TestTools.UnitTesting;
using XanhBrowser.Core;

namespace XanhBrowser.Core.Tests;

[TestClass]
public sealed class AdblockHostTests
{
    [TestMethod]
    public void ManagedBaselineBlocksKnownHostsWithoutSubstringMatches()
    {
        var source = "https://publisher.example/";
        var blocked = AdblockRequest.TryCreate(
            "https://securepubads.g.doubleclick.net/tag.js", source, "script", "GET");
        var allowed = AdblockRequest.TryCreate(
            "https://notdoubleclick.net/tag.js", source, "script", "GET");

        Assert.IsNotNull(blocked);
        Assert.IsNotNull(allowed);
        Assert.IsTrue(BaselineAdblockEngine.Instance.ShouldBlock(blocked));
        Assert.IsFalse(BaselineAdblockEngine.Instance.ShouldBlock(allowed));
    }

    [TestMethod]
    public void PreferenceDefaultsOn()
    {
        Assert.IsTrue(AdblockPreference.Resolve(null));
        Assert.IsTrue(AdblockPreference.Resolve(true));
        Assert.IsFalse(AdblockPreference.Resolve(false));
        Assert.IsTrue(AdblockPreference.Resolve("false"));
    }

    [TestMethod]
    public void OnlyExpectedNativeVersionIsAccepted()
    {
        Assert.IsTrue(AdblockNativeContract.AcceptsVersion(AdblockNativeContract.ExpectedVersion));
        Assert.IsFalse(AdblockNativeContract.AcceptsVersion(null));
        Assert.IsFalse(AdblockNativeContract.AcceptsVersion("1.0.0-alpha.0"));
        Assert.IsFalse(AdblockNativeContract.AcceptsVersion("1.0.0"));
    }

    [TestMethod]
    public void RequestValidationNormalizesBoundedValues()
    {
        var request = AdblockRequest.TryCreate(
            "HTTPS://ads.example/banner.js",
            "https://news.example/article",
            "SCRIPT",
            "get");

        Assert.IsNotNull(request);
        Assert.AreEqual("https://ads.example/banner.js", request.Url);
        Assert.AreEqual("script", request.RequestType);
        Assert.AreEqual("GET", request.Method);
    }

    [TestMethod]
    public void RequestValidationRejectsUnsafeOrOversizedValues()
    {
        Assert.IsNull(AdblockRequest.TryCreate(
            "file:///tmp/advert.js",
            "https://news.example/",
            "script",
            "GET"));
        Assert.IsNull(AdblockRequest.TryCreate(
            "https://ads.example/",
            "https://user:secret@news.example/",
            "script",
            "GET"));
        Assert.IsNull(AdblockRequest.TryCreate(
            "https://ads.example/" + new string('x', AdblockRequest.MaximumUrlBytes),
            "https://news.example/",
            "script",
            "GET"));
        Assert.IsNull(AdblockRequest.TryCreate(
            "https://ads.example/",
            "https://news.example/",
            "script\0other",
            "GET"));
    }

    [TestMethod]
    public void MissingNativeLibraryFailsOpen()
    {
        var missingDirectory = Path.Combine(
            Path.GetTempPath(),
            "xanh-adblock-missing-" + Guid.NewGuid().ToString("N"));

        Assert.IsNull(NativeAdblockEngine.TryCreate(missingDirectory));
    }

    [TestMethod]
    public void BuiltNativeArtifactLoadsAndBlocksBaselineWhenProvided()
    {
        var sourceLibrary = Environment.GetEnvironmentVariable("XANH_ADBLOCK_TEST_NATIVE_DLL");
        if (string.IsNullOrWhiteSpace(sourceLibrary))
        {
            // Ordinary developer/unit runs do not build a native DLL. The Windows workflow
            // provides this path for the architecture it can execute on the runner.
            return;
        }

        Assert.IsTrue(File.Exists(sourceLibrary), "The workflow native DLL is missing.");
        var directory = Path.Combine(
            Path.GetTempPath(),
            "xanh-adblock-native-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            File.Copy(
                sourceLibrary,
                Path.Combine(directory, NativeAdblockEngine.LibraryFileName));
            using var engine = NativeAdblockEngine.TryCreate(directory);
            Assert.IsNotNull(engine, "The built DLL failed the exact ABI/runtime load contract.");

            var blocked = AdblockRequest.TryCreate(
                "https://securepubads.g.doubleclick.net/tag.js",
                "https://publisher.example/",
                "script",
                "GET");
            var allowed = AdblockRequest.TryCreate(
                "https://publisher.example/app.js",
                "https://publisher.example/",
                "script",
                "GET");
            Assert.IsNotNull(blocked);
            Assert.IsNotNull(allowed);
            Assert.IsTrue(engine.ShouldBlock(blocked));
            Assert.IsFalse(engine.ShouldBlock(allowed));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
