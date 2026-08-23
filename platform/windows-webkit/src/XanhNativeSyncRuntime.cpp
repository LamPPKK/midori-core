/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include "XanhNativeSyncRuntime.h"

#include "XanhNativeSyncLibrary.h"

#include <windows.h>
#include "xanh_sync.h"

#include <cstring>
#include <mutex>
#include <new>
#include <thread>
#include <unordered_map>
#include <utility>

namespace {

using GenerateLocalLoginsKey = decltype(&xanh_sync_generate_local_logins_key);
using RuntimeOpen = decltype(&xanh_sync_runtime_open);
using RuntimeFree = decltype(&xanh_sync_runtime_free);
using RuntimeInitialize = decltype(&xanh_sync_runtime_initialize);
using RuntimeAccountState = decltype(&xanh_sync_runtime_account_state);
using RuntimeVaultUnlocked = decltype(&xanh_sync_runtime_vault_unlocked);
using RuntimeUnlockVault = decltype(&xanh_sync_runtime_unlock_vault);
using RuntimeLockVault = decltype(&xanh_sync_runtime_lock_vault);
using RuntimeCredentialsJSON = decltype(&xanh_sync_runtime_credentials_json);
using RuntimeTouchCredential = decltype(&xanh_sync_runtime_touch_credential);
using LastError = decltype(&xanh_sync_last_error);
using StringFree = decltype(&xanh_sync_string_free);

template<typename Function>
Function resolve(HMODULE module, const char* name)
{
    FARPROC procedure = GetProcAddress(module, name);
    Function function = nullptr;
    static_assert(sizeof(function) == sizeof(procedure));
    std::memcpy(&function, &procedure, sizeof(function));
    return function;
}

bool isBoundedCStringInput(std::string_view value, std::size_t maximumBytes, bool allowEmpty)
{
    return value.size() <= maximumBytes
        && (allowEmpty || !value.empty())
        && value.find('\0') == std::string_view::npos;
}

bool isCredentialID(std::string_view value)
{
    if (!isBoundedCStringInput(
            value, XanhNativeSyncRuntime::maximumCredentialIDBytes, false))
        return false;
    for (unsigned char character : value) {
        if (!(character >= 'a' && character <= 'z')
            && !(character >= 'A' && character <= 'Z')
            && !(character >= '0' && character <= '9')
            && character != '-' && character != '_')
            return false;
    }
    return true;
}

std::optional<std::size_t> boundedCStringLength(const char* value, std::size_t maximumBytes)
{
    if (!value)
        return std::nullopt;
    for (std::size_t index = 0; index <= maximumBytes; ++index) {
        if (!value[index])
            return index;
    }
    return std::nullopt;
}

std::optional<XanhNativeSyncRuntime::AccountState> accountState(std::int32_t value)
{
    if (value < static_cast<std::int32_t>(XanhNativeSyncRuntime::AccountState::disconnected)
        || value > static_cast<std::int32_t>(XanhNativeSyncRuntime::AccountState::authIssues))
        return std::nullopt;
    return static_cast<XanhNativeSyncRuntime::AccountState>(value);
}

void clear(std::string& value)
{
    if (!value.empty())
        SecureZeroMemory(value.data(), value.size());
    value.clear();
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

std::string takeNativeError(LastError lastError, StringFree stringFree)
{
    NativeOwnedString value(lastError(), stringFree);
    if (!value.get())
        return "Unknown Firefox Sync error";
    auto length = boundedCStringLength(
        value.get(), XanhNativeSyncRuntime::maximumErrorBytes);
    if (!length) {
        value.wipe(XanhNativeSyncRuntime::maximumErrorBytes + 1);
        return "Invalid Firefox Sync error";
    }
    value.wipe(*length);
    std::string error(value.get(), *length);
    return error.empty() ? "Unknown Firefox Sync error" : error;
}

} // namespace

XanhSensitiveUTF8 XanhSensitiveUTF8::take(std::string&& value)
{
    try {
        auto result = copyOf(value);
        ::clear(value);
        return result;
    } catch (...) {
        ::clear(value);
        throw;
    }
}

XanhSensitiveUTF8 XanhSensitiveUTF8::copyOf(std::string_view value)
{
    XanhSensitiveUTF8 result;
    if (value.empty())
        return result;
    result.m_data = std::make_unique<char[]>(value.size() + 1);
    std::memcpy(result.m_data.get(), value.data(), value.size());
    result.m_data[value.size()] = '\0';
    result.m_size = value.size();
    return result;
}

XanhSensitiveUTF8::~XanhSensitiveUTF8()
{
    clear();
}

XanhSensitiveUTF8::XanhSensitiveUTF8(XanhSensitiveUTF8&& other)
    : m_data(std::move(other.m_data))
    , m_size(std::exchange(other.m_size, 0))
{
}

XanhSensitiveUTF8& XanhSensitiveUTF8::operator=(XanhSensitiveUTF8&& other)
{
    if (this != &other) {
        clear();
        m_data = std::move(other.m_data);
        m_size = std::exchange(other.m_size, 0);
    }
    return *this;
}

void XanhSensitiveUTF8::clear()
{
    if (m_data && m_size)
        SecureZeroMemory(m_data.get(), m_size);
    m_data.reset();
    m_size = 0;
}

struct XanhNativeSyncRuntime::Impl {
    std::unique_ptr<XanhNativeSyncLibrary> library;
    void* runtime { nullptr };
    RuntimeFree runtimeFree { nullptr };
    RuntimeInitialize runtimeInitialize { nullptr };
    RuntimeAccountState runtimeAccountState { nullptr };
    RuntimeVaultUnlocked runtimeVaultUnlocked { nullptr };
    RuntimeUnlockVault runtimeUnlockVault { nullptr };
    RuntimeLockVault runtimeLockVault { nullptr };
    RuntimeCredentialsJSON runtimeCredentialsJSON { nullptr };
    RuntimeTouchCredential runtimeTouchCredential { nullptr };
    LastError lastError { nullptr };
    StringFree stringFree { nullptr };
    std::mutex mutex;
    std::unordered_map<std::thread::id, std::string> hostLastErrors;

    ~Impl()
    {
        if (runtime)
            runtimeFree(runtime);
    }

    std::optional<XanhSensitiveUTF8> takeSensitive(char* value, std::size_t maximumBytes)
    {
        if (!value)
            return std::nullopt;
        NativeOwnedString owned(value, stringFree);
        auto length = boundedCStringLength(owned.get(), maximumBytes);
        if (!length) {
            // Only wipe the prefix that the bounded scan proved readable.
            owned.wipe(maximumBytes + 1);
            setError("Oversized credential output from native core");
            return std::nullopt;
        }
        owned.wipe(*length);
        return XanhSensitiveUTF8::copyOf(
            std::string_view(owned.get(), *length));
    }

    std::string takeError()
    {
        return takeNativeError(lastError, stringFree);
    }

    void captureNativeError()
    {
        hostLastErrors[std::this_thread::get_id()] = takeError();
    }

    void setError(std::string value)
    {
        hostLastErrors[std::this_thread::get_id()] = std::move(value);
    }

    void clearError()
    {
        hostLastErrors.erase(std::this_thread::get_id());
    }
};

std::unique_ptr<XanhNativeSyncRuntime> XanhNativeSyncRuntime::open(
    std::unique_ptr<XanhNativeSyncLibrary> library, OpenParameters parameters,
    std::string& error)
{
    if (!library
        || !isBoundedCStringInput(parameters.configurationJSON, maximumConfigurationBytes, false)
        || !isBoundedCStringInput(parameters.profileDirectory, maximumProfileDirectoryBytes, false)
        || (parameters.localLoginsKey
            && !isBoundedCStringInput(parameters.localLoginsKey->view(), maximumLoginsKeyBytes, false))
        || (parameters.accountJSON
            && !isBoundedCStringInput(parameters.accountJSON->view(), maximumOpenSecretBytes, false))
        || (parameters.persistedSyncState
            && !isBoundedCStringInput(parameters.persistedSyncState->view(), maximumOpenSecretBytes, false)))
    {
        error = "Invalid native Sync runtime configuration";
        return nullptr;
    }

    HMODULE module = static_cast<HMODULE>(library->moduleHandleForRuntime());
    auto runtimeOpen = resolve<RuntimeOpen>(module, "xanh_sync_runtime_open");
    auto impl = std::make_unique<Impl>();
    impl->library = std::move(library);
    impl->runtimeFree = resolve<RuntimeFree>(module, "xanh_sync_runtime_free");
    impl->runtimeInitialize = resolve<RuntimeInitialize>(module, "xanh_sync_runtime_initialize");
    impl->runtimeAccountState = resolve<RuntimeAccountState>(module, "xanh_sync_runtime_account_state");
    impl->runtimeVaultUnlocked = resolve<RuntimeVaultUnlocked>(module, "xanh_sync_runtime_vault_unlocked");
    impl->runtimeUnlockVault = resolve<RuntimeUnlockVault>(module, "xanh_sync_runtime_unlock_vault");
    impl->runtimeLockVault = resolve<RuntimeLockVault>(module, "xanh_sync_runtime_lock_vault");
    impl->runtimeCredentialsJSON = resolve<RuntimeCredentialsJSON>(module, "xanh_sync_runtime_credentials_json");
    impl->runtimeTouchCredential = resolve<RuntimeTouchCredential>(module, "xanh_sync_runtime_touch_credential");
    impl->lastError = resolve<LastError>(module, "xanh_sync_last_error");
    impl->stringFree = resolve<StringFree>(module, "xanh_sync_string_free");

    const char* localLoginsKey = parameters.localLoginsKey
        ? parameters.localLoginsKey->view().data() : nullptr;
    const char* accountJSON = parameters.accountJSON
        ? parameters.accountJSON->view().data() : nullptr;
    const char* persistedSyncState = parameters.persistedSyncState
        ? parameters.persistedSyncState->view().data() : nullptr;
    impl->runtime = runtimeOpen(
        parameters.configurationJSON.c_str(), parameters.profileDirectory.c_str(),
        localLoginsKey, accountJSON, persistedSyncState);
    if (!impl->runtime) {
        error = impl->takeError();
        return nullptr;
    }
    error.clear();
    return std::unique_ptr<XanhNativeSyncRuntime>(new XanhNativeSyncRuntime(std::move(impl)));
}

std::optional<XanhSensitiveUTF8> XanhNativeSyncRuntime::generateLocalLoginsKey(
    const XanhNativeSyncLibrary& library, std::string& error)
{
    HMODULE module = static_cast<HMODULE>(library.moduleHandleForRuntime());
    auto generateKey = resolve<GenerateLocalLoginsKey>(module, "xanh_sync_generate_local_logins_key");
    auto lastError = resolve<LastError>(module, "xanh_sync_last_error");
    auto stringFree = resolve<StringFree>(module, "xanh_sync_string_free");
    char* value = generateKey();
    if (!value) {
        error = takeNativeError(lastError, stringFree);
        return std::nullopt;
    }
    NativeOwnedString owned(value, stringFree);
    auto length = boundedCStringLength(owned.get(), maximumLoginsKeyBytes);
    if (!length || !*length) {
        owned.wipe(length ? *length : maximumLoginsKeyBytes + 1);
        error = "Invalid local Logins key from native core";
        return std::nullopt;
    }
    owned.wipe(*length);
    error.clear();
    return XanhSensitiveUTF8::copyOf(
        std::string_view(owned.get(), *length));
}

XanhNativeSyncRuntime::XanhNativeSyncRuntime(std::unique_ptr<Impl> impl)
    : m_impl(std::move(impl))
{
}

XanhNativeSyncRuntime::~XanhNativeSyncRuntime() = default;

std::optional<XanhNativeSyncRuntime::AccountState> XanhNativeSyncRuntime::initialize()
{
    std::scoped_lock lock(m_impl->mutex);
    auto rawState = m_impl->runtimeInitialize(m_impl->runtime);
    auto state = ::accountState(rawState);
    if (state)
        m_impl->clearError();
    else if (rawState >= 0)
        m_impl->setError("Invalid account state from native core");
    else
        m_impl->captureNativeError();
    return state;
}

std::optional<XanhNativeSyncRuntime::AccountState> XanhNativeSyncRuntime::accountState()
{
    std::scoped_lock lock(m_impl->mutex);
    auto rawState = m_impl->runtimeAccountState(m_impl->runtime);
    auto state = ::accountState(rawState);
    if (state)
        m_impl->clearError();
    else if (rawState >= 0)
        m_impl->setError("Invalid account state from native core");
    else
        m_impl->captureNativeError();
    return state;
}

bool XanhNativeSyncRuntime::vaultUnlocked()
{
    std::scoped_lock lock(m_impl->mutex);
    bool result = m_impl->runtimeVaultUnlocked(m_impl->runtime);
    // false is the valid locked state in the C ABI, not an error sentinel.
    m_impl->clearError();
    return result;
}

bool XanhNativeSyncRuntime::unlockVault(std::string_view localLoginsKey)
{
    if (!isBoundedCStringInput(localLoginsKey, maximumLoginsKeyBytes, false)) {
        std::scoped_lock lock(m_impl->mutex);
        m_impl->setError("Invalid local Logins key");
        return false;
    }
    std::string key(localLoginsKey);
    std::scoped_lock lock(m_impl->mutex);
    bool result = m_impl->runtimeUnlockVault(m_impl->runtime, key.c_str());
    ::clear(key);
    if (result)
        m_impl->clearError();
    else
        m_impl->captureNativeError();
    return result;
}

bool XanhNativeSyncRuntime::lockVault()
{
    std::scoped_lock lock(m_impl->mutex);
    bool result = m_impl->runtimeLockVault(m_impl->runtime);
    if (result)
        m_impl->clearError();
    else
        m_impl->captureNativeError();
    return result;
}

std::optional<XanhSensitiveUTF8> XanhNativeSyncRuntime::credentialsJSON(std::string_view contextJSON)
{
    if (!isBoundedCStringInput(contextJSON, maximumCredentialContextBytes, false)) {
        std::scoped_lock lock(m_impl->mutex);
        m_impl->setError("Invalid credential context");
        return std::nullopt;
    }
    std::string context(contextJSON);
    std::scoped_lock lock(m_impl->mutex);
    char* nativeResult = m_impl->runtimeCredentialsJSON(
        m_impl->runtime, context.c_str());
    if (!nativeResult) {
        m_impl->captureNativeError();
        return std::nullopt;
    }
    auto result = m_impl->takeSensitive(nativeResult, maximumCredentialOutputBytes);
    if (result)
        m_impl->clearError();
    return result;
}

bool XanhNativeSyncRuntime::touchCredential(std::string_view id, std::string_view contextJSON)
{
    if (!isCredentialID(id)
        || !isBoundedCStringInput(contextJSON, maximumCredentialContextBytes, false)) {
        std::scoped_lock lock(m_impl->mutex);
        m_impl->setError("Invalid credential touch input");
        return false;
    }
    std::string idCopy(id);
    std::string context(contextJSON);
    std::scoped_lock lock(m_impl->mutex);
    bool result = m_impl->runtimeTouchCredential(m_impl->runtime, idCopy.c_str(), context.c_str());
    if (result)
        m_impl->clearError();
    else
        m_impl->captureNativeError();
    return result;
}

std::string XanhNativeSyncRuntime::takeLastError()
{
    std::scoped_lock lock(m_impl->mutex);
    auto error = m_impl->hostLastErrors.find(std::this_thread::get_id());
    if (error == m_impl->hostLastErrors.end())
        return "Unknown Firefox Sync error";
    std::string result = std::move(error->second);
    m_impl->hostLastErrors.erase(error);
    return result.empty() ? "Unknown Firefox Sync error" : result;
}
