#pragma once

#include <memory>
#include <string>
#include <string_view>

class XanhNativeSyncRuntime;

class XanhNativeSyncLibrary {
public:
    static constexpr std::string_view expectedCoreVersion = "1.0.0-alpha.1";

    // Production loads only an exact xanh_sync_core.dll beside the executable.
    // No PATH/current-directory search or alternate filename is permitted.
    static std::unique_ptr<XanhNativeSyncLibrary> loadFromApplicationDirectory();
#ifdef XANH_NATIVE_SYNC_TESTING
    static std::unique_ptr<XanhNativeSyncLibrary> loadUnsignedFromPathForTesting(std::wstring absolutePath);
    static std::unique_ptr<XanhNativeSyncLibrary> loadSignedFromPathForTesting(std::wstring absolutePath);
#endif

    ~XanhNativeSyncLibrary();

    XanhNativeSyncLibrary(const XanhNativeSyncLibrary&) = delete;
    XanhNativeSyncLibrary& operator=(const XanhNativeSyncLibrary&) = delete;

    const std::string& version() const;

private:
    friend class XanhNativeSyncRuntime;
    struct Impl;

    explicit XanhNativeSyncLibrary(std::unique_ptr<Impl>);
    static std::unique_ptr<XanhNativeSyncLibrary> loadFromPath(std::wstring, bool requireTrustedSignature);
    void* moduleHandleForRuntime() const;

    std::unique_ptr<Impl> m_impl;
};
