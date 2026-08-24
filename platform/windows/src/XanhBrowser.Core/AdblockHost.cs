using System.Runtime.InteropServices;
using System.Text;

namespace XanhBrowser.Core;

public static class AdblockPreference
{
    public const string StorageKey = "XanhAdblockEnabled";

    public static bool Resolve(object? storedValue) => storedValue is bool enabled ? enabled : true;
}

public static class AdblockNativeContract
{
    public const string ExpectedVersion = "1.0.0-alpha.1";

    public static bool AcceptsVersion(string? value) =>
        value is not null && value.Equals(ExpectedVersion, StringComparison.Ordinal);
}

public sealed class AdblockRequest
{
    public const int MaximumUrlBytes = 8 * 1024;
    public const int MaximumRequestTypeBytes = 32;
    public const int MaximumMethodBytes = 16;

    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    private AdblockRequest(string url, string sourceUrl, string requestType, string method)
    {
        Url = url;
        SourceUrl = sourceUrl;
        RequestType = requestType;
        Method = method;
    }

    public string Url { get; }
    public string SourceUrl { get; }
    public string RequestType { get; }
    public string Method { get; }

    public static AdblockRequest? TryCreate(
        string? url,
        string? sourceUrl,
        string? requestType,
        string? method)
    {
        if (!TryNormalizeWebUrl(url, out var normalizedUrl)
            || !TryNormalizeWebUrl(sourceUrl, out var normalizedSourceUrl)
            || !IsBoundedToken(requestType, MaximumRequestTypeBytes)
            || !IsBoundedToken(method, MaximumMethodBytes))
        {
            return null;
        }

        return new AdblockRequest(
            normalizedUrl,
            normalizedSourceUrl,
            requestType!.ToLowerInvariant(),
            method!.ToUpperInvariant());
    }

    private static bool TryNormalizeWebUrl(string? value, out string normalized)
    {
        normalized = "";
        if (!IsBoundedText(value, MaximumUrlBytes)
            || !Uri.TryCreate(value, UriKind.Absolute, out var uri)
            || !(uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
                || uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            || !AddressResolver.IsAllowedWebUri(uri))
        {
            return false;
        }

        normalized = uri.AbsoluteUri;
        return IsBoundedText(normalized, MaximumUrlBytes);
    }

    private static bool IsBoundedToken(string? value, int maximumBytes)
    {
        if (!IsBoundedText(value, maximumBytes))
        {
            return false;
        }

        return value!.All(character => character is >= '!' and <= '~');
    }

    private static bool IsBoundedText(string? value, int maximumBytes)
    {
        if (string.IsNullOrEmpty(value)
            || value.Length > maximumBytes
            || value.IndexOf('\0') >= 0
            || value.Any(char.IsControl))
        {
            return false;
        }

        try
        {
            return StrictUtf8.GetByteCount(value) <= maximumBytes;
        }
        catch (EncoderFallbackException)
        {
            return false;
        }
    }
}

public interface IAdblockEngine : IDisposable
{
    bool ShouldBlock(AdblockRequest request);
}

/// Small immutable fallback used by developer builds or if a packaged native core is rejected.
public sealed class BaselineAdblockEngine : IAdblockEngine
{
    private static readonly string[] BlockedDomains =
    [
        "doubleclick.net",
        "googlesyndication.com",
        "google-analytics.com",
        "adservice.google.com",
        "amazon-adsystem.com",
        "scorecardresearch.com",
    ];

    public static BaselineAdblockEngine Instance { get; } = new();

    private BaselineAdblockEngine() { }

    public bool ShouldBlock(AdblockRequest request)
    {
        if (!Uri.TryCreate(request.Url, UriKind.Absolute, out var uri)) return false;
        var host = uri.IdnHost.TrimEnd('.').ToLowerInvariant();
        return BlockedDomains.Any(
            domain => host.Equals(domain, StringComparison.Ordinal)
                || host.EndsWith('.' + domain, StringComparison.Ordinal));
    }

    public void Dispose() { }
}

/// Loads only an architecture-matched DLL packaged beside the application executable.
public sealed class NativeAdblockEngine : IAdblockEngine
{
    public const string LibraryFileName = "xanh_adblock_core.dll";

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate nint EngineCreateDefaultDelegate();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate nint CoreVersionDelegate();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void EngineFreeDelegate(nint engine);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int EngineShouldBlockDelegate(
        nint engine,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string url,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string sourceUrl,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string requestType,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string method);

    private readonly object _gate = new();
    private readonly EngineFreeDelegate _free;
    private readonly EngineShouldBlockDelegate _shouldBlock;
    private nint _library;
    private nint _engine;

    private NativeAdblockEngine(
        nint library,
        nint engine,
        EngineFreeDelegate free,
        EngineShouldBlockDelegate shouldBlock)
    {
        _library = library;
        _engine = engine;
        _free = free;
        _shouldBlock = shouldBlock;
    }

    public static NativeAdblockEngine? TryCreate(string applicationBaseDirectory)
    {
        nint library = 0;
        nint engine = 0;
        EngineFreeDelegate? free = null;
        try
        {
            var baseDirectory = Path.GetFullPath(applicationBaseDirectory);
            var libraryPath = Path.GetFullPath(Path.Combine(baseDirectory, LibraryFileName));
            if (!Path.GetDirectoryName(libraryPath)!.Equals(
                    baseDirectory.TrimEnd(Path.DirectorySeparatorChar),
                    StringComparison.OrdinalIgnoreCase)
                || !NativeLibrary.TryLoad(libraryPath, out library)
                || !TryGetDelegate(library, "xanh_adblock_core_version", out CoreVersionDelegate? version)
                || !HasExpectedVersion(version!())
                || !TryGetDelegate(library, "xanh_adblock_engine_create_default", out EngineCreateDefaultDelegate? create)
                || !TryGetDelegate(library, "xanh_adblock_engine_free", out free)
                || !TryGetDelegate(library, "xanh_adblock_engine_should_block", out EngineShouldBlockDelegate? shouldBlock))
            {
                return null;
            }

            engine = create!();
            return engine == 0 ? null : new NativeAdblockEngine(library, engine, free!, shouldBlock!);
        }
        catch (Exception)
        {
            return null;
        }
        finally
        {
            if (engine == 0)
            {
                if (library != 0)
                {
                    try { NativeLibrary.Free(library); }
                    catch (Exception) { }
                }
            }
        }
    }

    public bool ShouldBlock(AdblockRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        lock (_gate)
        {
            if (_engine == 0)
            {
                return false;
            }

            try
            {
                var decision = _shouldBlock(
                    _engine,
                    request.Url,
                    request.SourceUrl,
                    request.RequestType,
                    request.Method);
                return decision < 0
                    ? BaselineAdblockEngine.Instance.ShouldBlock(request)
                    : decision == 1;
            }
            catch (Exception)
            {
                return BaselineAdblockEngine.Instance.ShouldBlock(request);
            }
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_engine != 0)
            {
                try { _free(_engine); }
                catch (Exception) { }
                _engine = 0;
            }
            if (_library != 0)
            {
                try { NativeLibrary.Free(_library); }
                catch (Exception) { }
                _library = 0;
            }
        }
        GC.SuppressFinalize(this);
    }

    private static bool TryGetDelegate<T>(nint library, string name, out T? function)
        where T : Delegate
    {
        function = null;
        if (!NativeLibrary.TryGetExport(library, name, out var address))
        {
            return false;
        }

        function = Marshal.GetDelegateForFunctionPointer<T>(address);
        return true;
    }

    private static bool HasExpectedVersion(nint value)
    {
        if (value == 0)
        {
            return false;
        }

        var expected = Encoding.UTF8.GetBytes(AdblockNativeContract.ExpectedVersion);
        for (var index = 0; index < expected.Length; index++)
        {
            if (Marshal.ReadByte(value, index) != expected[index])
            {
                return false;
            }
        }
        return Marshal.ReadByte(value, expected.Length) == 0;
    }
}
