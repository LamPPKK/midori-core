using Microsoft.VisualStudio.TestTools.UnitTesting;
using XanhBrowser.Core;

namespace XanhBrowser.Core.Tests;

[TestClass]
public sealed class PortableBackupTests
{
    private const string GoldenBase64 =
        "WEFOSEJLMQAAAAABAAM0UAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhsAAABrGe+1+LCSaxIIZoTehQCW/YIh3t1cWKdtm2ZRhz5KDI1ss8rhvNIL709BNuA0TcxI/6UIxeKecxM6+ofiMw3m0Ij51SZIl9KKSASqMcyXCRVDgSnVBCrcAKURj7URBqlSOW181AoYQXA+Aiw=";

    private static readonly PortableBackupPayload Payload = new(
        1_700_000_000_000,
        "windows-webview2",
        ["https://example.com/", "https://webkit.org/"],
        1,
        false);

    [TestMethod]
    public void EncryptedBackupRoundTrips()
    {
        var encoded = PortableBackup.Encode(Payload, "correct horse battery staple");
        var decoded = PortableBackup.Decode(encoded, "correct horse battery staple");
        Assert.AreEqual(Payload.CreatedAtEpochMilliseconds, decoded.CreatedAtEpochMilliseconds);
        Assert.AreEqual(Payload.SourceEdition, decoded.SourceEdition);
        Assert.AreEqual(Payload.SelectedIndex, decoded.SelectedIndex);
        Assert.AreEqual(Payload.DesktopSite, decoded.DesktopSite);
        CollectionAssert.AreEqual(Payload.Urls.ToArray(), decoded.Urls.ToArray());
    }

    [TestMethod]
    public void EncodesAndroidGoldenVector()
    {
        var androidPayload = new PortableBackupPayload(
            1_700_000_000_000,
            "android-lite-webkit",
            ["https://example.com/", "https://webkit.org/"],
            1,
            true);
        var encoded = PortableBackup.Encode(
            androidPayload,
            "correct horse battery staple",
            Enumerable.Range(0, 16).Select(value => (byte)value).ToArray(),
            Enumerable.Range(16, 12).Select(value => (byte)value).ToArray());

        Assert.AreEqual(GoldenBase64, Convert.ToBase64String(encoded));
    }

    [TestMethod]
    public void EncodesUnicodePasswordGoldenVector()
    {
        var androidPayload = new PortableBackupPayload(
            1_700_000_000_000,
            "android-lite-webkit",
            ["https://example.com/", "https://webkit.org/"],
            1,
            true);
        var encoded = PortableBackup.Encode(
            androidPayload,
            "mật-khẩu-Xanh-🔒",
            Enumerable.Range(0, 16).Select(value => (byte)value).ToArray(),
            Enumerable.Range(16, 12).Select(value => (byte)value).ToArray());

        Assert.AreEqual(
            "WEFOSEJLMQAAAAABAAM0UAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhsAAABrfjICD8Mjv9vFJ0zWrTRPQSUTvi8TnvUo1avIYeQ5ehuR/ZrSJ6l/mE8DpJJ/RyRFfKbZF6I+GbB2zRIFF8M//fuYuJSK/3/0K0dBM0CnXITV+mXV4Z6zOoIAxLCvs/QXPJTSiUKgBg/XtVE=",
            Convert.ToBase64String(encoded));
    }

    [TestMethod]
    public void DecodesAndroidGoldenVector()
    {
        var encoded = Convert.FromBase64String(GoldenBase64);
        var decoded = PortableBackup.Decode(encoded, "correct horse battery staple");

        Assert.AreEqual(1_700_000_000_000, decoded.CreatedAtEpochMilliseconds);
        Assert.AreEqual("android-lite-webkit", decoded.SourceEdition);
        Assert.AreEqual(1, decoded.SelectedIndex);
        Assert.IsTrue(decoded.DesktopSite);
        CollectionAssert.AreEqual(
            new[] { "https://example.com/", "https://webkit.org/" },
            decoded.Urls.ToArray());
    }

    [TestMethod]
    public void RejectsWrongPasswordAndTampering()
    {
        var encoded = PortableBackup.Encode(Payload, "correct password");
        Assert.ThrowsException<InvalidDataException>(() =>
            PortableBackup.Decode(encoded, "wrong password"));

        encoded[^1] ^= 1;
        Assert.ThrowsException<InvalidDataException>(() =>
            PortableBackup.Decode(encoded, "correct password"));
    }

    [TestMethod]
    public void RejectsUnsafeUrls()
    {
        foreach (var unsafeUrl in new[] { "file:///C:/private.txt", "https://user:secret@example.com/", "https://foo_bar.example/" })
        {
            var unsafePayload = Payload with
            {
                Urls = [unsafeUrl],
                SelectedIndex = 0,
            };
            Assert.ThrowsException<InvalidDataException>(() =>
                PortableBackup.Encode(unsafePayload, "correct password"));
        }
    }

    [TestMethod]
    public void CanonicalizesIdnHostsForCrossEngineBackups()
    {
        var idnPayload = Payload with
        {
            Urls = ["https://bücher.example/catalogue"],
            SelectedIndex = 0,
        };

        var encoded = PortableBackup.Encode(idnPayload, "correct password");
        var decoded = PortableBackup.Decode(encoded, "correct password");

        CollectionAssert.AreEqual(
            new[] { "https://xn--bcher-kva.example/catalogue" },
            decoded.Urls.ToArray());
    }
}
