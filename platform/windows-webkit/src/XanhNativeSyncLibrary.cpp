#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include "XanhNativeSyncLibrary.h"

#include <windows.h>
#include <softpub.h>
#include <wintrust.h>
#include "xanh_sync.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <filesystem>
#include <optional>
#include <utility>

namespace {

constexpr wchar_t nativeLibraryName[] = L"xanh_sync_core.dll";
constexpr std::size_t maximumVersionBytes = 128;
constexpr std::size_t maximumGeneratedKeyBytes = 4096;

using CoreVersion = decltype(&xanh_sync_core_version);
using StringFree = decltype(&xanh_sync_string_free);
using GenerateLocalLoginsKey = decltype(&xanh_sync_generate_local_logins_key);

constexpr std::array requiredExports {
    "xanh_sync_core_version",
    "xanh_sync_string_free",
    "xanh_sync_credential_access_allowed",
    "xanh_sync_last_error",
    "xanh_sync_generate_local_logins_key",
    "xanh_sync_runtime_open",
    "xanh_sync_runtime_free",
    "xanh_sync_runtime_initialize",
    "xanh_sync_runtime_account_state",
    "xanh_sync_runtime_begin_oauth",
    "xanh_sync_runtime_complete_oauth",
    "xanh_sync_runtime_account_json",
    "xanh_sync_runtime_persisted_state",
    "xanh_sync_runtime_unlock_vault",
    "xanh_sync_runtime_lock_vault",
    "xanh_sync_runtime_vault_unlocked",
    "xanh_sync_runtime_sync",
    "xanh_sync_runtime_update_local_tabs",
    "xanh_sync_runtime_remote_tabs_json",
    "xanh_sync_bookmark_root_guid",
    "xanh_sync_runtime_create_bookmark",
    "xanh_sync_runtime_import_legacy_bookmarks",
    "xanh_sync_runtime_bookmarks_json",
    "xanh_sync_runtime_update_bookmark",
    "xanh_sync_runtime_delete_bookmark",
    "xanh_sync_runtime_record_history",
    "xanh_sync_runtime_recent_history_json",
    "xanh_sync_runtime_delete_history_visit",
    "xanh_sync_runtime_clear_history",
    "xanh_sync_runtime_credentials_json",
    "xanh_sync_runtime_add_credential",
    "xanh_sync_runtime_update_credential",
    "xanh_sync_runtime_delete_credential",
    "xanh_sync_runtime_touch_credential",
    "xanh_sync_runtime_disconnect",
};

class Handle {
public:
    explicit Handle(HANDLE value = INVALID_HANDLE_VALUE)
        : m_value(value)
    {
    }

    ~Handle()
    {
        if (m_value && m_value != INVALID_HANDLE_VALUE)
            CloseHandle(m_value);
    }

    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;

    explicit operator bool() const { return m_value && m_value != INVALID_HANDLE_VALUE; }
    HANDLE get() const { return m_value; }

private:
    HANDLE m_value;
};

std::optional<std::filesystem::path> normalizedLibraryPath(std::wstring_view value)
{
    if (value.empty())
        return std::nullopt;
    std::filesystem::path path(value);
    if (!path.is_absolute())
        return std::nullopt;
    for (const auto& component : path) {
        if (component == L"..")
            return std::nullopt;
    }
    path = path.lexically_normal();
    if (_wcsicmp(path.filename().c_str(), nativeLibraryName))
        return std::nullopt;
    return path;
}

bool isRegularNonReparseFile(const std::filesystem::path& path)
{
    Handle file(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (!file)
        return false;
    FILE_ATTRIBUTE_TAG_INFO attributes { };
    return GetFileInformationByHandleEx(file.get(), FileAttributeTagInfo, &attributes, sizeof(attributes))
        && !(attributes.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT));
}

bool hasTrustedAuthenticodeSignature(const std::filesystem::path& path)
{
    WINTRUST_FILE_INFO fileInfo { };
    fileInfo.cbStruct = sizeof(fileInfo);
    fileInfo.pcwszFilePath = path.c_str();

    WINTRUST_DATA trustData { };
    trustData.cbStruct = sizeof(trustData);
    trustData.dwUIChoice = WTD_UI_NONE;
    trustData.fdwRevocationChecks = WTD_REVOKE_NONE;
    trustData.dwUnionChoice = WTD_CHOICE_FILE;
    trustData.pFile = &fileInfo;
    trustData.dwStateAction = WTD_STATEACTION_VERIFY;
    trustData.dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL;

    GUID policy = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    HWND trustWindow = reinterpret_cast<HWND>(INVALID_HANDLE_VALUE);
    LONG result = WinVerifyTrust(trustWindow, &policy, &trustData);
    trustData.dwStateAction = WTD_STATEACTION_CLOSE;
    WinVerifyTrust(trustWindow, &policy, &trustData);
    return result == ERROR_SUCCESS;
}

std::optional<std::filesystem::path> applicationLibraryPath()
{
    std::wstring executablePath(32768, L'\0');
    DWORD length = GetModuleFileNameW(nullptr, executablePath.data(), static_cast<DWORD>(executablePath.size()));
    if (!length || length >= executablePath.size())
        return std::nullopt;
    executablePath.resize(length);
    return std::filesystem::path(executablePath).parent_path() / nativeLibraryName;
}

template<typename Function>
Function resolve(HMODULE module, const char* name)
{
    FARPROC procedure = GetProcAddress(module, name);
    Function function = nullptr;
    static_assert(sizeof(function) == sizeof(procedure));
    std::memcpy(&function, &procedure, sizeof(function));
    return function;
}

std::optional<std::size_t> boundedCStringLength(const char* value, std::size_t maximumBytes)
{
    if (!value)
        return std::nullopt;
    for (std::size_t index = 0; index < maximumBytes; ++index) {
        if (!value[index])
            return index;
    }
    return std::nullopt;
}

class NativeOwnedString {
public:
    NativeOwnedString(char* value, StringFree stringFree)
        : m_value(value)
        , m_stringFree(stringFree)
    {
    }

    ~NativeOwnedString()
    {
        if (!m_value)
            return;
        if (m_wipeBytes)
            SecureZeroMemory(m_value, m_wipeBytes);
        m_stringFree(m_value);
    }

    NativeOwnedString(const NativeOwnedString&) = delete;
    NativeOwnedString& operator=(const NativeOwnedString&) = delete;

    char* get() const { return m_value; }
    void wipe(std::size_t bytes) { m_wipeBytes = bytes; }

private:
    char* m_value { nullptr };
    StringFree m_stringFree { nullptr };
    std::size_t m_wipeBytes { 0 };
};

} // namespace

struct XanhNativeSyncLibrary::Impl {
    HMODULE module { nullptr };
    std::string version;

    ~Impl()
    {
        if (module)
            FreeLibrary(module);
    }
};

XanhNativeSyncLibrary::XanhNativeSyncLibrary(std::unique_ptr<Impl> impl)
    : m_impl(std::move(impl))
{
}

XanhNativeSyncLibrary::~XanhNativeSyncLibrary() = default;

std::unique_ptr<XanhNativeSyncLibrary> XanhNativeSyncLibrary::loadFromApplicationDirectory()
{
    auto path = applicationLibraryPath();
    return path ? loadFromPath(path->wstring(), true) : nullptr;
}

#ifdef XANH_NATIVE_SYNC_TESTING
std::unique_ptr<XanhNativeSyncLibrary> XanhNativeSyncLibrary::loadUnsignedFromPathForTesting(std::wstring absolutePath)
{
    return loadFromPath(std::move(absolutePath), false);
}

std::unique_ptr<XanhNativeSyncLibrary> XanhNativeSyncLibrary::loadSignedFromPathForTesting(std::wstring absolutePath)
{
    return loadFromPath(std::move(absolutePath), true);
}
#endif

std::unique_ptr<XanhNativeSyncLibrary> XanhNativeSyncLibrary::loadFromPath(std::wstring absolutePath, bool requireTrustedSignature)
{
    auto path = normalizedLibraryPath(absolutePath);
    if (!path || !isRegularNonReparseFile(*path)
        || (requireTrustedSignature && !hasTrustedAuthenticodeSignature(*path)))
        return nullptr;

    auto impl = std::make_unique<Impl>();
    impl->module = LoadLibraryExW(path->c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!impl->module)
        return nullptr;

    for (const char* name : requiredExports) {
        if (!GetProcAddress(impl->module, name))
            return nullptr;
    }

    auto coreVersion = resolve<CoreVersion>(impl->module, "xanh_sync_core_version");
    auto stringFree = resolve<StringFree>(impl->module, "xanh_sync_string_free");
    auto generateKey = resolve<GenerateLocalLoginsKey>(impl->module, "xanh_sync_generate_local_logins_key");

    NativeOwnedString ownedVersion(coreVersion(), stringFree);
    if (!ownedVersion.get())
        return nullptr;
    auto versionLength = boundedCStringLength(ownedVersion.get(), maximumVersionBytes);
    if (!versionLength || !*versionLength)
        return nullptr;
    impl->version.assign(ownedVersion.get(), *versionLength);
    if (impl->version != expectedCoreVersion)
        return nullptr;

    // A portable build exposes the same symbols but cannot generate a Logins
    // key. Probe and immediately wipe one key to require the Mozilla backend.
    NativeOwnedString generatedKey(generateKey(), stringFree);
    if (!generatedKey.get())
        return nullptr;
    auto keyLength = boundedCStringLength(generatedKey.get(), maximumGeneratedKeyBytes + 1);
    bool validKey = keyLength && *keyLength > 0 && *keyLength <= maximumGeneratedKeyBytes;
    generatedKey.wipe(keyLength ? *keyLength : maximumGeneratedKeyBytes + 1);
    if (!validKey)
        return nullptr;

    return std::unique_ptr<XanhNativeSyncLibrary>(new XanhNativeSyncLibrary(std::move(impl)));
}

const std::string& XanhNativeSyncLibrary::version() const
{
    return m_impl->version;
}

void* XanhNativeSyncLibrary::moduleHandleForRuntime() const
{
    return m_impl->module;
}
