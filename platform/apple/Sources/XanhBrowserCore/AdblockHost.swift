import Darwin
import Foundation

public enum AdblockHostPolicy {
    public static let preferenceKey = "XanhAdblockEnabled"
    public static let expectedNativeVersion = "1.0.0-alpha.1"
    public static let maximumCompiledRuleListBytes = 64 * 1024 * 1024

    public static func isEnabled(storedValue: Any?) -> Bool {
        (storedValue as? Bool) ?? true
    }

    public static func nativeLibraryCandidates(
        resourceURL: URL?,
        privateFrameworksURL: URL?,
        executableURL: URL?
    ) -> [URL] {
        var candidates: [URL] = []
        if let privateFrameworksURL {
            candidates.append(
                privateFrameworksURL
                    .appendingPathComponent("xanh_adblock_core.framework", isDirectory: true)
                    .appendingPathComponent("xanh_adblock_core", isDirectory: false)
            )
        }
        if let resourceURL {
            candidates.append(
                resourceURL.appendingPathComponent("libxanh_adblock_core.dylib", isDirectory: false)
            )
        }
        if let executableURL {
            candidates.append(
                executableURL.deletingLastPathComponent()
                    .appendingPathComponent("libxanh_adblock_core.dylib", isDirectory: false)
            )
        }
        return candidates
    }

    public static func acceptsCompiledRuleList(_ value: String) -> Bool {
        guard acceptsCompiledRuleList(
            byteCount: value.utf8.count,
            containsNUL: value.utf8.contains(0)
        ), let data = value.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data),
        let rules = json as? [[String: Any]] else { return false }
        return !rules.isEmpty
    }

    static func acceptsCompiledRuleList(byteCount: Int, containsNUL: Bool) -> Bool {
        byteCount > 0 && byteCount <= maximumCompiledRuleListBytes && !containsNUL
    }

    public static func acceptsNativeVersion(_ value: String?) -> Bool {
        value == expectedNativeVersion
    }
}

/// Optional bridge to the Xanh ad-blocking C ABI. Missing or invalid native artifacts fail open.
public enum NativeAdblockCompiler {
    private typealias CompileDefault = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias CoreVersion = @convention(c) () -> UnsafePointer<CChar>?
    private typealias FreeString = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    public static func compileDefaultWebKitRuleList(libraryPaths: [String]) -> String? {
        if let handle = dlopen(nil, RTLD_NOW | RTLD_LOCAL) {
            defer { dlclose(handle) }
            if let result = compile(using: handle) {
                return result
            }
        }

        for path in libraryPaths where !path.isEmpty {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
            defer { dlclose(handle) }
            if let result = compile(using: handle) {
                return result
            }
        }
        return nil
    }

    private static func compile(using handle: UnsafeMutableRawPointer) -> String? {
        guard let versionSymbol = dlsym(handle, "xanh_adblock_core_version"),
              let compileSymbol = dlsym(handle, "xanh_adblock_compile_webkit_default_json"),
              let freeSymbol = dlsym(handle, "xanh_adblock_string_free") else { return nil }
        let coreVersion = unsafeBitCast(versionSymbol, to: CoreVersion.self)
        guard let versionPointer = coreVersion() else { return nil }
        let versionLength = strnlen(versionPointer, 64)
        guard versionLength > 0, versionLength < 64,
              let version = String(
                data: Data(bytes: versionPointer, count: versionLength),
                encoding: .utf8
              ),
              AdblockHostPolicy.acceptsNativeVersion(version) else { return nil }
        let compile = unsafeBitCast(compileSymbol, to: CompileDefault.self)
        let freeString = unsafeBitCast(freeSymbol, to: FreeString.self)
        guard let output = compile() else { return nil }
        defer { freeString(output) }

        let maximum = AdblockHostPolicy.maximumCompiledRuleListBytes
        let length = strnlen(output, maximum + 1)
        guard length > 0, length <= maximum else { return nil }
        let data = Data(bytes: output, count: length)
        guard let value = String(data: data, encoding: .utf8),
              AdblockHostPolicy.acceptsCompiledRuleList(value) else { return nil }
        return value
    }
}
