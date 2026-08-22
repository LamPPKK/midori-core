using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace XanhBrowser.Core;

public sealed record PortableBackupPayload(
    long CreatedAtEpochMilliseconds,
    string SourceEdition,
    IReadOnlyList<string> Urls,
    int SelectedIndex,
    bool DesktopSite);

public static class PortableBackup
{
    public const string FileExtension = ".xanhbackup";
    public const int MaxEncodedBytes = 1_048_576;

    private static readonly byte[] Magic = [0x58, 0x41, 0x4E, 0x48, 0x42, 0x4B, 0x31, 0x00];
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private const int FormatVersion = 1;
    private const int PayloadVersion = 1;
    private const int Iterations = 210_000;
    private const int SaltBytes = 16;
    private const int NonceBytes = 12;
    private const int TagBytes = 16;
    private const int KeyBytes = 32;
    private const int MaxUrls = 50;
    private const int MaxStringBytes = 4_096;
    private static readonly IdnMapping StrictIdn = new() { UseStd3AsciiRules = true };

    public static byte[] Encode(PortableBackupPayload payload, string passphrase)
    {
        ValidatePassphrase(passphrase);
        var salt = RandomNumberGenerator.GetBytes(SaltBytes);
        var nonce = RandomNumberGenerator.GetBytes(NonceBytes);
        return Encode(payload, passphrase, salt, nonce);
    }

    internal static byte[] Encode(
        PortableBackupPayload payload,
        string passphrase,
        byte[] salt,
        byte[] nonce)
    {
        ValidatePassphrase(passphrase);
        if (salt.Length != SaltBytes || nonce.Length != NonceBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(salt), "Invalid backup salt or nonce.");
        }

        var plaintext = EncodePayload(payload);
        var key = Rfc2898DeriveBytes.Pbkdf2(
            passphrase,
            salt,
            Iterations,
            HashAlgorithmName.SHA256,
            KeyBytes);
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[TagBytes];
        try
        {
            using var aes = new AesGcm(key, TagBytes);
            aes.Encrypt(nonce, plaintext, ciphertext, tag);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
            CryptographicOperations.ZeroMemory(plaintext);
        }

        using var output = new MemoryStream();
        output.Write(Magic);
        WriteInt32(output, FormatVersion);
        WriteInt32(output, Iterations);
        output.Write(salt);
        output.Write(nonce);
        WriteInt32(output, ciphertext.Length + tag.Length);
        output.Write(ciphertext);
        output.Write(tag);
        var result = output.ToArray();
        if (result.Length > MaxEncodedBytes)
        {
            throw new InvalidDataException("Backup is too large.");
        }
        return result;
    }

    public static PortableBackupPayload Decode(byte[] encoded, string passphrase)
    {
        ValidatePassphrase(passphrase);
        if (encoded.Length is < 64 or > MaxEncodedBytes)
        {
            throw new InvalidDataException("Invalid backup size.");
        }

        var input = new BackupReader(encoded);
        if (!input.ReadBytes(Magic.Length).SequenceEqual(Magic))
        {
            throw new InvalidDataException("Not a Xanh Browser backup.");
        }
        if (input.ReadInt32() != FormatVersion)
        {
            throw new InvalidDataException("Unsupported backup version.");
        }
        var iterations = input.ReadInt32();
        if (iterations is < 100_000 or > 1_000_000)
        {
            throw new InvalidDataException("Invalid backup key settings.");
        }
        var salt = input.ReadBytes(SaltBytes).ToArray();
        var nonce = input.ReadBytes(NonceBytes).ToArray();
        var encryptedSize = input.ReadInt32();
        if (encryptedSize < TagBytes || encryptedSize != input.Remaining)
        {
            throw new InvalidDataException("Invalid backup payload size.");
        }
        var encrypted = input.ReadBytes(encryptedSize);
        var ciphertext = encrypted[..^TagBytes];
        var tag = encrypted[^TagBytes..];
        var plaintext = new byte[ciphertext.Length];
        var key = Rfc2898DeriveBytes.Pbkdf2(
            passphrase,
            salt,
            iterations,
            HashAlgorithmName.SHA256,
            KeyBytes);
        try
        {
            using var aes = new AesGcm(key, TagBytes);
            aes.Decrypt(nonce, ciphertext, tag, plaintext);
            return DecodePayload(plaintext);
        }
        catch (AuthenticationTagMismatchException error)
        {
            throw new InvalidDataException("Wrong password or damaged backup.", error);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    private static byte[] EncodePayload(PortableBackupPayload payload)
    {
        if (payload.CreatedAtEpochMilliseconds < 0
            || string.IsNullOrWhiteSpace(payload.SourceEdition)
            || payload.Urls.Count is < 1 or > MaxUrls
            || payload.SelectedIndex < 0
            || payload.SelectedIndex >= payload.Urls.Count)
        {
            throw new InvalidDataException("Invalid backup payload.");
        }
        var canonicalUrls = new string[payload.Urls.Count];
        for (var index = 0; index < payload.Urls.Count; index++)
        {
            if (!TryCanonicalizeSupportedWebUrl(payload.Urls[index], out canonicalUrls[index]))
            {
                throw new InvalidDataException("Backup contains an unsafe URL.");
            }
        }

        using var output = new MemoryStream();
        WriteInt32(output, PayloadVersion);
        WriteInt64(output, payload.CreatedAtEpochMilliseconds);
        WriteString(output, payload.SourceEdition);
        WriteInt32(output, payload.SelectedIndex);
        output.WriteByte(payload.DesktopSite ? (byte)1 : (byte)0);
        WriteInt32(output, payload.Urls.Count);
        foreach (var url in canonicalUrls)
        {
            WriteString(output, url);
        }
        return output.ToArray();
    }

    private static PortableBackupPayload DecodePayload(byte[] plaintext)
    {
        var input = new BackupReader(plaintext);
        if (input.ReadInt32() != PayloadVersion)
        {
            throw new InvalidDataException("Unsupported backup payload.");
        }
        var createdAt = input.ReadInt64();
        var source = input.ReadString();
        var selectedIndex = input.ReadInt32();
        var flags = input.ReadByte();
        var count = input.ReadInt32();
        if (createdAt < 0
            || string.IsNullOrWhiteSpace(source)
            || (flags & 0xFE) != 0
            || count is < 1 or > MaxUrls)
        {
            throw new InvalidDataException("Invalid backup payload.");
        }

        var urls = new List<string>(count);
        for (var index = 0; index < count; index++)
        {
            var url = input.ReadString();
            if (!TryCanonicalizeSupportedWebUrl(url, out var canonicalUrl))
            {
                throw new InvalidDataException("Backup contains an unsafe URL.");
            }
            urls.Add(canonicalUrl);
        }
        if (selectedIndex < 0 || selectedIndex >= urls.Count || input.Remaining != 0)
        {
            throw new InvalidDataException("Invalid selected tab or trailing data.");
        }
        return new PortableBackupPayload(createdAt, source, urls, selectedIndex, (flags & 1) != 0);
    }

    private static void WriteString(Stream output, string value)
    {
        var bytes = StrictUtf8.GetBytes(value);
        if (bytes.Length is < 1 or > MaxStringBytes)
        {
            throw new InvalidDataException("Invalid backup text.");
        }
        WriteInt32(output, bytes.Length);
        output.Write(bytes);
    }

    private static void WriteInt32(Stream output, int value)
    {
        Span<byte> buffer = stackalloc byte[sizeof(int)];
        BinaryPrimitives.WriteInt32BigEndian(buffer, value);
        output.Write(buffer);
    }

    private static void WriteInt64(Stream output, long value)
    {
        Span<byte> buffer = stackalloc byte[sizeof(long)];
        BinaryPrimitives.WriteInt64BigEndian(buffer, value);
        output.Write(buffer);
    }

    private static void ValidatePassphrase(string passphrase)
    {
        if (passphrase.Length is < 8 or > 1_024)
        {
            throw new ArgumentException("Backup password must contain at least 8 characters.", nameof(passphrase));
        }
    }

    public static bool IsSupportedWebUrl(string value) =>
        TryCanonicalizeSupportedWebUrl(value, out _);

    private static bool TryCanonicalizeSupportedWebUrl(string value, out string canonical)
    {
        canonical = string.Empty;
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)
            || (!uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
                && !uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            || string.IsNullOrWhiteSpace(uri.Host)
            || !string.IsNullOrEmpty(uri.UserInfo))
        {
            return false;
        }

        try
        {
            var canonicalHost = uri.HostNameType switch
            {
                UriHostNameType.Dns => StrictIdn.GetAscii(uri.DnsSafeHost),
                UriHostNameType.IPv4 or UriHostNameType.IPv6 => uri.Host,
                _ => string.Empty,
            };
            if (string.IsNullOrEmpty(canonicalHost))
            {
                return false;
            }
            canonical = new UriBuilder(uri) { Host = canonicalHost }.Uri.AbsoluteUri;
            return Encoding.UTF8.GetByteCount(canonical) is > 0 and <= MaxStringBytes;
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (UriFormatException)
        {
            return false;
        }
    }

    private ref struct BackupReader
    {
        private readonly ReadOnlySpan<byte> _bytes;
        private int _position;

        public BackupReader(ReadOnlySpan<byte> bytes) => _bytes = bytes;

        public int Remaining => _bytes.Length - _position;

        public byte ReadByte()
        {
            EnsureAvailable(1);
            return _bytes[_position++];
        }

        public int ReadInt32()
        {
            var bytes = ReadBytes(sizeof(int));
            return BinaryPrimitives.ReadInt32BigEndian(bytes);
        }

        public long ReadInt64()
        {
            var bytes = ReadBytes(sizeof(long));
            return BinaryPrimitives.ReadInt64BigEndian(bytes);
        }

        public string ReadString()
        {
            var length = ReadInt32();
            if (length is < 1 or > MaxStringBytes)
            {
                throw new InvalidDataException("Invalid backup text.");
            }
            return StrictUtf8.GetString(ReadBytes(length));
        }

        public ReadOnlySpan<byte> ReadBytes(int count)
        {
            EnsureAvailable(count);
            var result = _bytes.Slice(_position, count);
            _position += count;
            return result;
        }

        private void EnsureAvailable(int count)
        {
            if (count < 0 || count > Remaining)
            {
                throw new InvalidDataException("Truncated backup.");
            }
        }
    }
}
