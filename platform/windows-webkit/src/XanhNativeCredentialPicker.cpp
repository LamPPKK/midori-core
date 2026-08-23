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

#include "XanhNativeCredentialPicker.h"

#include "XanhCredentialRecords.h"
#include "XanhDpapiSecretStore.h"
#include "XanhOAuthCallback.h"
#include "XanhNativeSyncLibrary.h"
#include "XanhNativeSyncRuntime.h"
#include "XanhWindowsHello.h"

#include <commctrl.h>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

constexpr wchar_t accountsEnvironment[] = L"XANH_WINCAIRO_FXA_ACCOUNTS_URL";
constexpr wchar_t tokenServerEnvironment[] = L"XANH_WINCAIRO_FXA_TOKEN_SERVER_URL";
constexpr wchar_t clientIDEnvironment[] = L"XANH_WINCAIRO_FXA_CLIENT_ID";
constexpr std::size_t maximumEnvironmentCharacters = 8192;
constexpr ULONGLONG vaultTimeoutMilliseconds = 5 * 60 * 1000;
constexpr std::string_view allSyncEngines =
    "[\"bookmarks\",\"history\",\"tabs\",\"passwords\"]";

void secureClear(std::string& value)
{
    if (!value.empty())
        SecureZeroMemory(value.data(), value.size());
    value.clear();
}

void invokeCompletion(
    XanhCredentialPickerCompletion completion,
    std::optional<XanhCredential> credential) noexcept
{
    if (!completion)
        return;
    try {
        completion(std::move(credential));
    } catch (...) {
    }
}

std::optional<std::wstring> environment(std::wstring_view name)
{
    DWORD required = GetEnvironmentVariableW(
        std::wstring(name).c_str(), nullptr, 0);
    if (!required || required > maximumEnvironmentCharacters + 1)
        return std::nullopt;
    std::wstring value(required, L'\0');
    DWORD written = GetEnvironmentVariableW(
        std::wstring(name).c_str(), value.data(), required);
    if (!written || written >= required)
        return std::nullopt;
    value.resize(written);
    if (!XanhCredentialBridgePolicy::isBoundedText(
            value, maximumEnvironmentCharacters))
        return std::nullopt;
    return value;
}

std::optional<std::string> utf8(std::wstring_view value)
{
    if (value.empty())
        return std::string { };
    if (value.size() > static_cast<std::size_t>(std::numeric_limits<int>::max()))
        return std::nullopt;
    int required = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
        nullptr, 0, nullptr, nullptr);
    if (required <= 0)
        return std::nullopt;
    std::string result(static_cast<std::size_t>(required), '\0');
    if (WideCharToMultiByte(
            CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
            result.data(), required, nullptr, nullptr)
        != required)
        return std::nullopt;
    return result;
}

std::string jsonString(std::string_view value)
{
    constexpr char hex[] = "0123456789abcdef";
    std::string result;
    result.reserve(value.size() + 2);
    result.push_back('"');
    for (unsigned char character : value) {
        switch (character) {
        case '"': result += "\\\""; break;
        case '\\': result += "\\\\"; break;
        case '\b': result += "\\b"; break;
        case '\f': result += "\\f"; break;
        case '\n': result += "\\n"; break;
        case '\r': result += "\\r"; break;
        case '\t': result += "\\t"; break;
        default:
            if (character < 0x20) {
                result += "\\u00";
                result.push_back(hex[character >> 4]);
                result.push_back(hex[character & 0xf]);
            } else
                result.push_back(static_cast<char>(character));
        }
    }
    result.push_back('"');
    return result;
}

void appendJSONString(std::string& result, std::string_view value)
{
    constexpr char hex[] = "0123456789abcdef";
    result.push_back('"');
    for (unsigned char character : value) {
        switch (character) {
        case '"': result += "\\\""; break;
        case '\\': result += "\\\\"; break;
        case '\b': result += "\\b"; break;
        case '\f': result += "\\f"; break;
        case '\n': result += "\\n"; break;
        case '\r': result += "\\r"; break;
        case '\t': result += "\\t"; break;
        default:
            if (character < 0x20) {
                result += "\\u00";
                result.push_back(hex[character >> 4]);
                result.push_back(hex[character & 0xf]);
            } else
                result.push_back(static_cast<char>(character));
        }
    }
    result.push_back('"');
}

bool isHTTPSURL(std::wstring_view value)
{
    auto separator = value.find(L"://");
    return separator != std::wstring_view::npos
        && XanhNavigationPolicy::equalASCIIFolded(value.substr(0, separator), L"https")
        && XanhNavigationPolicy::isAllowedWebURL(value);
}

std::optional<std::string> configurationJSON(std::wstring& accountOrigin)
{
    auto accounts = environment(accountsEnvironment);
    auto tokenServer = environment(tokenServerEnvironment);
    auto clientID = environment(clientIDEnvironment);
    if (!accounts || !tokenServer || !clientID || clientID->empty()
        || !isHTTPSURL(*accounts) || !isHTTPSURL(*tokenServer))
        return std::nullopt;
    auto canonicalAccountOrigin =
        XanhCredentialBridgePolicy::canonicalHTTPSOrigin(*accounts);
    if (!canonicalAccountOrigin)
        return std::nullopt;
    auto accountsUTF8 = utf8(*accounts);
    auto tokenServerUTF8 = utf8(*tokenServer);
    auto clientIDUTF8 = utf8(*clientID);
    if (!accountsUTF8 || !tokenServerUTF8 || !clientIDUTF8)
        return std::nullopt;
    accountOrigin = std::move(*canonicalAccountOrigin);
    return "{\"server\":{\"kind\":\"self-hosted\",\"accounts_url\":"
        + jsonString(*accountsUTF8) + ",\"token_server_url\":"
        + jsonString(*tokenServerUTF8) + "},\"client_id\":"
        + jsonString(*clientIDUTF8)
        + ",\"redirect_uri\":\"xanh-browser-wincairo://accounts/oauth\""
          ",\"device_name\":\"Xanh Browser WinCairo\",\"device_kind\":\"desktop\"}";
}

bool isRegularDirectory(const std::filesystem::path& path)
{
    DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES
        && (attributes & FILE_ATTRIBUTE_DIRECTORY)
        && !(attributes & FILE_ATTRIBUTE_REPARSE_POINT);
}

std::optional<std::filesystem::path> prepareProfileDirectory(
    std::wstring_view storageRoot)
{
    if (storageRoot.empty())
        return std::nullopt;
    std::filesystem::path root(storageRoot);
    std::error_code error;
    std::filesystem::create_directories(root, error);
    if (error || !isRegularDirectory(root))
        return std::nullopt;
    auto profile = root / L"Profile";
    error.clear();
    std::filesystem::create_directory(profile, error);
    if (error)
        return std::nullopt;
    return isRegularDirectory(profile) ? std::optional(profile) : std::nullopt;
}

bool removeRegularFile(const std::filesystem::path& path)
{
    DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES)
        return GetLastError() == ERROR_FILE_NOT_FOUND
            || GetLastError() == ERROR_PATH_NOT_FOUND;
    if (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))
        return false;
    return DeleteFileW(path.c_str()) || GetLastError() == ERROR_FILE_NOT_FOUND;
}

bool removeUnreadableLogins(const std::filesystem::path& profile)
{
    auto database = profile / L"logins.sqlite";
    for (const wchar_t* suffix : { L"", L"-wal", L"-shm", L"-journal" }) {
        if (!removeRegularFile(database.wstring() + suffix))
            return false;
    }
    return true;
}

bool isValidLocalLoginsKey(std::string_view value)
{
    return !value.empty()
        && value.size() <= XanhNativeSyncRuntime::maximumLoginsKeyBytes
        && value.find('\0') == std::string_view::npos;
}

std::optional<XanhSensitiveUTF8> credentialContextJSON(
    const XanhCredentialBridgePolicy::Request& request)
{
    auto document = utf8(request.documentURL);
    auto origin = utf8(request.claimedOrigin);
    if (!document || !origin)
        return std::nullopt;
    auto sensitiveDocument = XanhSensitiveUTF8::take(std::move(*document));
    auto sensitiveOrigin = XanhSensitiveUTF8::take(std::move(*origin));
    std::string result;
    try {
        result.reserve(XanhNativeSyncRuntime::maximumCredentialContextBytes);
        result += "{\"document_url\":";
        appendJSONString(result, sensitiveDocument.view());
        result += ",\"top_frame_origin\":";
        appendJSONString(result, sensitiveOrigin.view());
        result += ",\"frame_origin\":";
        appendJSONString(result, sensitiveOrigin.view());
        result += ",\"is_private\":false,\"user_selected\":true}";
        if (result.size() > XanhNativeSyncRuntime::maximumCredentialContextBytes) {
            secureClear(result);
            return std::nullopt;
        }
        return XanhSensitiveUTF8::take(std::move(result));
    } catch (...) {
        secureClear(result);
        throw;
    }
}

bool isCurrentProcessWindow(HWND window)
{
    if (!window)
        return false;
    DWORD process = 0;
    GetWindowThreadProcessId(window, &process);
    return process == GetCurrentProcessId();
}

} // namespace

struct XanhNativeCredentialPicker::Impl {
    struct DialogContext {
        Impl* impl { nullptr };
        std::uint64_t generation { 0 };
        HWND owner { nullptr };
    };

    Impl()
        : storageRoot(XanhDpapiSecretStore::defaultStorageRoot())
        , store(storageRoot)
    {
        timer = CreateThreadpoolTimer(timerFired, this, nullptr);
        initialize();
    }

    ~Impl()
    {
        if (hello)
            hello->cancel();
        if (timer) {
            SetThreadpoolTimer(timer, nullptr, 0, 0);
            WaitForThreadpoolTimerCallbacks(timer, TRUE);
            CloseThreadpoolTimer(timer);
        }
        if (runtime)
            runtime->lockVault();
    }

    bool loadStoredSecret(
        XanhDpapiSecretStore::Secret secret,
        std::optional<XanhSensitiveUTF8>& output)
    {
        auto value = store.read(secret);
        if (value.status == XanhDpapiSecretStore::Status::notFound) {
            secureClear(value.value);
            return true;
        }
        if (value.status != XanhDpapiSecretStore::Status::success
            || value.value.empty()
            || value.value.size() > XanhNativeSyncRuntime::maximumOpenSecretBytes
            || value.value.find('\0') != std::string::npos) {
            secureClear(value.value);
            return false;
        }
        output.emplace(XanhSensitiveUTF8::take(std::move(value.value)));
        return true;
    }

    bool prepareLocalLoginsKey()
    {
        auto stored = store.read(XanhDpapiSecretStore::Secret::loginsKey);
        if (stored.status == XanhDpapiSecretStore::Status::success
            && isValidLocalLoginsKey(stored.value)) {
            secureClear(stored.value);
            return true;
        }

        bool replaceable = stored.status == XanhDpapiSecretStore::Status::notFound
            || stored.status == XanhDpapiSecretStore::Status::corruptData
            || stored.status == XanhDpapiSecretStore::Status::protectionError
            || stored.status == XanhDpapiSecretStore::Status::success;
        secureClear(stored.value);
        if (!replaceable)
            return false;
        if (stored.status != XanhDpapiSecretStore::Status::notFound
            && store.remove(XanhDpapiSecretStore::Secret::loginsKey)
                != XanhDpapiSecretStore::Status::success)
            return false;
        if (!profile || !removeUnreadableLogins(*profile))
            return false;

        auto generated = runtime->generateLocalLoginsKey();
        return generated && isValidLocalLoginsKey(generated->view())
            && store.write(XanhDpapiSecretStore::Secret::loginsKey, generated->view())
                == XanhDpapiSecretStore::Status::success;
    }

    bool persistRuntimeStateLocked()
    {
        if (!runtime)
            return false;
        auto account = runtime->accountJSON();
        if (!account || account->empty())
            return false;
        auto persisted = runtime->persistedState();
        if (!persisted)
            return false;
        auto status = persisted->empty()
            ? store.remove(XanhDpapiSecretStore::Secret::syncState)
            : store.write(XanhDpapiSecretStore::Secret::syncState,
                persisted->view());
        if (status != XanhDpapiSecretStore::Status::success)
            return false;
        // Account state contains the connected refresh credentials. Commit it
        // last so a failed Sync-state write cannot resurrect a sign-in that the
        // UI reported as failed.
        return store.write(XanhDpapiSecretStore::Secret::accountState,
                   account->view())
            == XanhDpapiSecretStore::Status::success;
    }

    bool finishDisconnectLocked(bool deleteLocal)
    {
        if (!runtime)
            return false;
        std::vector<XanhDpapiSecretStore::Secret> secrets {
            XanhDpapiSecretStore::Secret::accountState,
            XanhDpapiSecretStore::Secret::syncState,
            XanhDpapiSecretStore::Secret::schedule,
        };
        if (deleteLocal) {
            secrets.push_back(XanhDpapiSecretStore::Secret::loginsKey);
            secrets.push_back(XanhDpapiSecretStore::Secret::engineSelection);
        }
        for (auto secret : secrets) {
            if (store.remove(secret) != XanhDpapiSecretStore::Status::success)
                return false;
        }
        if (store.remove(XanhDpapiSecretStore::Secret::disconnectIntent)
            != XanhDpapiSecretStore::Status::success)
            return false;
        pendingDisconnect.reset();
        oauthOwner = nullptr;
        oauthBoundToWindow = false;
        runtime.reset();
        accountOrigin.clear();
        profile.reset();
        initialize();
        return true;
    }

    void initialize()
    {
        auto disconnect = store.read(
            XanhDpapiSecretStore::Secret::disconnectIntent);
        if (disconnect.status == XanhDpapiSecretStore::Status::success) {
            if (disconnect.value == "keep-local")
                pendingDisconnect = false;
            else if (disconnect.value == "delete-local")
                pendingDisconnect = true;
            else {
                secureClear(disconnect.value);
                return;
            }
        } else if (disconnect.status != XanhDpapiSecretStore::Status::notFound) {
            secureClear(disconnect.value);
            return;
        }
        secureClear(disconnect.value);

        std::wstring configuredAccountOrigin;
        auto configuration = configurationJSON(configuredAccountOrigin);
        if (!configuration || !timer)
            return;
        auto library = XanhNativeSyncLibrary::loadFromApplicationDirectory();
        if (!library)
            return;
        profile = prepareProfileDirectory(storageRoot);
        if (!profile)
            return;
        auto profileUTF8 = utf8(profile->wstring());
        if (!profileUTF8)
            return;

        std::optional<XanhSensitiveUTF8> account;
        std::optional<XanhSensitiveUTF8> syncState;
        if (!loadStoredSecret(XanhDpapiSecretStore::Secret::accountState, account)
            || !loadStoredSecret(XanhDpapiSecretStore::Secret::syncState, syncState))
            return;
        bool hadAccount = account.has_value();

        XanhNativeSyncRuntime::OpenParameters parameters {
            std::move(*configuration), std::move(*profileUTF8), std::nullopt,
            std::move(account), std::move(syncState)
        };
        std::string error;
        auto opened = XanhNativeSyncRuntime::open(
            std::move(library), std::move(parameters), error);
        secureClear(error);
        if (!opened || !opened->initialize())
            return;
        runtime = std::move(opened);
        accountOrigin = std::move(configuredAccountOrigin);
        if (pendingDisconnect) {
            auto deleteLocal = *pendingDisconnect;
            if (runtime->disconnect(deleteLocal))
                finishDisconnectLocked(deleteLocal);
        }
        else if (hadAccount && !prepareLocalLoginsKey())
            runtime.reset();
    }

    static void CALLBACK timerFired(PTP_CALLBACK_INSTANCE, void* context, PTP_TIMER)
    {
        static_cast<Impl*>(context)->lockAfterTimeout();
    }

    static HRESULT CALLBACK dialogCallback(
        HWND dialog, UINT notification, WPARAM, LPARAM, LONG_PTR data)
    {
        auto* context = reinterpret_cast<DialogContext*>(data);
        if (!context || !context->impl)
            return S_OK;
        std::scoped_lock lock(context->impl->mutex);
        if (!context->impl->requestCurrentLocked(
                context->generation, context->owner, false)) {
            if (notification == TDN_CREATED)
                PostMessageW(dialog, TDM_CLICK_BUTTON, IDCANCEL, 0);
            return S_OK;
        }
        if (notification == TDN_CREATED)
            context->impl->activeDialog = dialog;
        else if (notification == TDN_DESTROYED
            && context->impl->activeDialog == dialog)
            context->impl->activeDialog = nullptr;
        return S_OK;
    }

    void armLockTimerLocked(ULONGLONG delayMilliseconds)
    {
        if (!timer)
            return;
        constexpr ULONGLONG hundredNanosecondsPerMillisecond = 10'000;
        LARGE_INTEGER due { };
        due.QuadPart = -static_cast<LONGLONG>(
            delayMilliseconds * hundredNanosecondsPerMillisecond);
        FILETIME fileTime { due.LowPart, static_cast<DWORD>(due.HighPart) };
        SetThreadpoolTimer(timer, &fileTime, 0, 0);
    }

    void scheduleLockLocked()
    {
        vaultDeadline = GetTickCount64() + vaultTimeoutMilliseconds;
        armLockTimerLocked(vaultTimeoutMilliseconds);
    }

    void cancelTimerLocked()
    {
        vaultDeadline = 0;
        if (timer)
            SetThreadpoolTimer(timer, nullptr, 0, 0);
    }

    void lockAfterTimeout()
    {
        HWND dialog = nullptr;
        {
            std::scoped_lock lock(mutex);
            if (!vaultDeadline || !runtime)
                return;
            auto now = GetTickCount64();
            if (now < vaultDeadline) {
                armLockTimerLocked(vaultDeadline - now);
                return;
            }
            vaultDeadline = 0;
            if (operationActive)
                vaultLockPending = true;
            else if (!runtime->lockVault())
                runtime.reset();
            dialog = activeDialog;
        }
        if (dialog)
            PostMessageW(dialog, TDM_CLICK_BUTTON, IDCANCEL, 0);
    }

    bool unlockVaultLocked()
    {
        if (!runtime)
            return false;
        if (runtime->vaultUnlocked()) {
            scheduleLockLocked();
            return true;
        }

        auto key = store.read(XanhDpapiSecretStore::Secret::loginsKey);
        if (key.status != XanhDpapiSecretStore::Status::success
            || !isValidLocalLoginsKey(key.value)) {
            secureClear(key.value);
            return false;
        }
        auto sensitiveKey = XanhSensitiveUTF8::take(std::move(key.value));
        if (!runtime->unlockVault(sensitiveKey.view()))
            return false;
        scheduleLockLocked();
        return true;
    }

    bool requestCurrentLocked(
        std::uint64_t expectedGeneration,
        HWND expectedOwner,
        bool requireForeground = true) const
    {
        return requestActive && generation == expectedGeneration
            && activeOwner == expectedOwner && expectedOwner
            && IsWindow(expectedOwner) && IsWindowVisible(expectedOwner)
            && !IsIconic(expectedOwner)
            && (!requireForeground || GetForegroundWindow() == expectedOwner);
    }

    XanhCredentialPickerCompletion takeCompletionLocked(
        std::uint64_t expectedGeneration)
    {
        if (!requestActive || generation != expectedGeneration)
            return { };
        requestActive = false;
        activeOwner = nullptr;
        presencePending = false;
        hello.reset();
        return std::move(completion);
    }

    SyncCompletion takeSyncCompletionLocked(
        std::uint64_t expectedGeneration)
    {
        if (!operationActive || generation != expectedGeneration
            || !syncCompletion)
            return { };
        operationActive = false;
        operationOwner = nullptr;
        presencePending = false;
        hello.reset();
        return std::move(syncCompletion);
    }

    bool applyPendingVaultLockLocked()
    {
        if (!vaultLockPending)
            return true;
        vaultLockPending = false;
        cancelTimerLocked();
        if (runtime && !runtime->lockVault()) {
            runtime.reset();
            return false;
        }
        return true;
    }

    void completeSync(
        std::uint64_t expectedGeneration,
        std::optional<SyncStatus> result)
    {
        SyncCompletion callback;
        {
            std::scoped_lock lock(mutex);
            if (!operationActive || generation != expectedGeneration
                || !syncCompletion)
                return;
            if (!applyPendingVaultLockLocked())
                result.reset();
            callback = takeSyncCompletionLocked(expectedGeneration);
        }
        if (!callback)
            return;
        try {
            callback(std::move(result));
        } catch (...) {
        }
    }

    void completeRequest(
        std::uint64_t expectedGeneration,
        std::optional<XanhCredential> result)
    {
        XanhCredentialPickerCompletion callback;
        {
            std::scoped_lock lock(mutex);
            callback = takeCompletionLocked(expectedGeneration);
        }
        invokeCompletion(std::move(callback), std::move(result));
    }

    std::wstring storageRoot;
    std::wstring accountOrigin;
    XanhDpapiSecretStore store;
    std::optional<std::filesystem::path> profile;
    std::unique_ptr<XanhNativeSyncRuntime> runtime;
    PTP_TIMER timer { nullptr };
    std::mutex mutex;
    std::shared_ptr<XanhWindowsHello> hello;
    XanhCredentialPickerCompletion completion;
    SyncCompletion syncCompletion;
    std::uint64_t generation { 0 };
    ULONGLONG vaultDeadline { 0 };
    HWND activeOwner { nullptr };
    HWND operationOwner { nullptr };
    HWND oauthOwner { nullptr };
    HWND activeDialog { nullptr };
    bool requestActive { false };
    bool presencePending { false };
    bool operationActive { false };
    bool vaultLockPending { false };
    bool oauthBoundToWindow { false };
    std::optional<bool> pendingDisconnect;
};

XanhNativeCredentialPicker::XanhNativeCredentialPicker()
    : m_impl(std::make_unique<Impl>())
{
}

XanhNativeCredentialPicker::~XanhNativeCredentialPicker() = default;

std::shared_ptr<XanhNativeCredentialPicker> XanhNativeCredentialPicker::shared()
{
    static std::mutex sharedMutex;
    static std::weak_ptr<XanhNativeCredentialPicker> existing;
    std::scoped_lock lock(sharedMutex);
    auto result = existing.lock();
    if (!result) {
        result = std::shared_ptr<XanhNativeCredentialPicker>(
            new XanhNativeCredentialPicker);
        existing = result;
    }
    return result;
}

void XanhNativeCredentialPicker::pick(
    HWND ownerWindow,
    XanhCredentialBridgePolicy::Request request,
    XanhCredentialPickerCompletion completion)
{
    if (!completion)
        return;
    std::uint64_t generation = 0;
    bool alreadyUnlocked = false;
    bool accepted = false;
    {
        std::scoped_lock lock(m_impl->mutex);
        accepted = m_impl->runtime && m_impl->profile && !m_impl->requestActive
            && !m_impl->operationActive && !m_impl->pendingDisconnect
            && ownerWindow && IsWindow(ownerWindow)
            && GetForegroundWindow() == ownerWindow && IsWindowVisible(ownerWindow)
            && !IsIconic(ownerWindow);
        if (accepted) {
            m_impl->requestActive = true;
            m_impl->activeOwner = ownerWindow;
            if (++m_impl->generation == 0)
                ++m_impl->generation;
            generation = m_impl->generation;
            m_impl->completion = std::move(completion);
            alreadyUnlocked = m_impl->runtime->vaultUnlocked();
            m_impl->cancelTimerLocked();
        }
    }
    if (!accepted) {
        invokeCompletion(std::move(completion), std::nullopt);
        return;
    }

    auto continueAfterPresence = [weak = weak_from_this(), ownerWindow,
                                     generation, request = std::move(request)](bool verified) mutable {
        auto service = weak.lock();
        if (!service)
            return;
        auto& impl = *service->m_impl;
        try {
            std::optional<std::vector<XanhCredentialRecord>> records;
            {
                std::unique_lock lock(impl.mutex);
                if (impl.requestActive && impl.generation == generation)
                    impl.presencePending = false;
                if (!verified
                    || !impl.requestCurrentLocked(generation, ownerWindow)
                    || !impl.unlockVaultLocked()) {
                    lock.unlock();
                    impl.completeRequest(generation, std::nullopt);
                    return;
                }
                auto context = credentialContextJSON(request);
                auto json = context
                    ? impl.runtime->credentialsJSON(context->view()) : std::nullopt;
                records = json
                    ? XanhCredentialRecords::parse(json->view(), request.claimedOrigin)
                    : std::nullopt;
                json.reset();
                if (!records || records->empty()
                    || !impl.requestCurrentLocked(generation, ownerWindow)) {
                    lock.unlock();
                    impl.completeRequest(generation, std::nullopt);
                    return;
                }
            }

            std::vector<XanhSensitiveWide> labels;
            std::vector<TASKDIALOG_BUTTON> buttons;
            labels.reserve(records->size());
            buttons.reserve(records->size());
            for (std::size_t index = 0; index < records->size(); ++index) {
                auto username = (*records)[index].username.view();
                auto label = XanhSensitiveWide::forNativeLabel(username);
                if (!label) {
                    impl.completeRequest(generation, std::nullopt);
                    return;
                }
                labels.push_back(std::move(*label));
                buttons.push_back({
                    static_cast<int>(1000 + index),
                    labels.back().empty()
                        ? L"(empty username)" : labels.back().view().data()
                });
            }
            std::wstring content = L"Choose a saved login for ";
            content += request.claimedOrigin;
            content += L". Xanh will fill only this exact HTTPS page.";
            Impl::DialogContext dialogContext { &impl, generation, ownerWindow };
            TASKDIALOGCONFIG config { };
            config.cbSize = sizeof(config);
            config.hwndParent = ownerWindow;
            config.dwFlags = TDF_USE_COMMAND_LINKS | TDF_ALLOW_DIALOG_CANCELLATION
                | TDF_POSITION_RELATIVE_TO_WINDOW;
            config.dwCommonButtons = TDCBF_CANCEL_BUTTON;
            config.pszWindowTitle = L"Xanh Browser";
            config.pszMainInstruction = L"Choose a saved login";
            config.pszContent = content.c_str();
            config.cButtons = static_cast<UINT>(buttons.size());
            config.pButtons = buttons.data();
            config.pfCallback = Impl::dialogCallback;
            config.lpCallbackData = reinterpret_cast<LONG_PTR>(&dialogContext);

            int selectedButton = IDCANCEL;
            HRESULT dialogResult = TaskDialogIndirect(
                &config, &selectedButton, nullptr, nullptr);

            XanhCredentialPickerCompletion callback;
            std::optional<XanhCredential> result;
            {
                std::unique_lock lock(impl.mutex);
                if (!impl.requestCurrentLocked(generation, ownerWindow)
                    || !impl.runtime
                    || FAILED(dialogResult) || selectedButton < 1000
                    || static_cast<std::size_t>(selectedButton - 1000)
                        >= records->size()) {
                    lock.unlock();
                    impl.completeRequest(generation, std::nullopt);
                    return;
                }
                auto& selected = (*records)[
                    static_cast<std::size_t>(selectedButton - 1000)];
                auto touchContext = credentialContextJSON(request);
                if (!touchContext
                    || !impl.runtime->touchCredential(
                        selected.id, touchContext->view())) {
                    lock.unlock();
                    impl.completeRequest(generation, std::nullopt);
                    return;
                }
                result.emplace(XanhCredential {
                    std::move(selected.username),
                    std::move(selected.password)
                });
                impl.scheduleLockLocked();
                callback = impl.takeCompletionLocked(generation);
            }
            invokeCompletion(std::move(callback), std::move(result));
        } catch (...) {
            impl.completeRequest(generation, std::nullopt);
        }
    };

    if (alreadyUnlocked) {
        continueAfterPresence(true);
        return;
    }
    std::shared_ptr<XanhWindowsHello> hello;
    {
        std::scoped_lock lock(m_impl->mutex);
        if (!m_impl->requestCurrentLocked(generation, ownerWindow))
            return;
        m_impl->hello = std::make_shared<XanhWindowsHello>(ownerWindow);
        m_impl->presencePending = true;
        hello = m_impl->hello;
    }
    try {
        hello->verify(
            L"Unlock passwords saved in Xanh Browser",
            std::move(continueAfterPresence));
    } catch (...) {
        m_impl->completeRequest(generation, std::nullopt);
    }
}

void XanhNativeCredentialPicker::cancel(HWND ownerWindow)
{
    HWND dialog = nullptr;
    std::shared_ptr<XanhWindowsHello> hello;
    XanhCredentialPickerCompletion completion;
    {
        std::scoped_lock lock(m_impl->mutex);
        if (m_impl->requestActive && m_impl->activeOwner == ownerWindow) {
            if (++m_impl->generation == 0)
                ++m_impl->generation;
            m_impl->requestActive = false;
            m_impl->activeOwner = nullptr;
            m_impl->presencePending = false;
            hello = std::exchange(m_impl->hello, { });
            completion = std::move(m_impl->completion);
            dialog = m_impl->activeDialog;
            m_impl->activeDialog = nullptr;
        }
    }
    if (hello)
        hello->cancel();
    if (dialog)
        PostMessageW(dialog, TDM_CLICK_BUTTON, IDCANCEL, 0);
    invokeCompletion(std::move(completion), std::nullopt);
}

void XanhNativeCredentialPicker::windowClosed(HWND ownerWindow)
{
    cancel(ownerWindow);
    std::shared_ptr<XanhWindowsHello> hello;
    SyncCompletion syncCompletion;
    {
        std::scoped_lock lock(m_impl->mutex);
        if (m_impl->oauthBoundToWindow && m_impl->oauthOwner == ownerWindow)
            m_impl->oauthOwner = nullptr;
        if (m_impl->operationActive
            && m_impl->operationOwner == ownerWindow
            && m_impl->syncCompletion) {
            if (m_impl->presencePending) {
                if (++m_impl->generation == 0)
                    ++m_impl->generation;
                m_impl->operationActive = false;
                m_impl->operationOwner = nullptr;
                m_impl->presencePending = false;
                hello = std::exchange(m_impl->hello, { });
                syncCompletion = std::move(m_impl->syncCompletion);
            } else {
                m_impl->operationOwner = nullptr;
                m_impl->vaultLockPending = true;
            }
        }
    }
    if (hello)
        hello->cancel();
    if (syncCompletion) {
        try {
            syncCompletion(std::nullopt);
        } catch (...) {
        }
    }
}

void XanhNativeCredentialPicker::applicationActivationChanged(
    HWND ownerWindow, bool isActive, HWND otherWindow)
{
    if (isActive)
        return;
    bool remainsInsideXanh = isCurrentProcessWindow(otherWindow);
    HWND dialog = nullptr;
    std::shared_ptr<XanhWindowsHello> hello;
    XanhCredentialPickerCompletion completion;
    {
        std::scoped_lock lock(m_impl->mutex);
        if (m_impl->requestActive && m_impl->activeOwner == ownerWindow
            && m_impl->presencePending && !remainsInsideXanh)
            return;
        if (m_impl->operationActive && m_impl->operationOwner == ownerWindow
            && m_impl->presencePending && !remainsInsideXanh)
            return;
        if (m_impl->requestActive && m_impl->activeOwner == ownerWindow
            && otherWindow && (otherWindow == m_impl->activeDialog
                || GetWindow(otherWindow, GW_OWNER) == ownerWindow))
            return;
        if (m_impl->requestActive && m_impl->activeOwner == ownerWindow) {
            if (++m_impl->generation == 0)
                ++m_impl->generation;
            m_impl->requestActive = false;
            m_impl->activeOwner = nullptr;
            m_impl->presencePending = false;
            hello = std::exchange(m_impl->hello, { });
            completion = std::move(m_impl->completion);
            dialog = m_impl->activeDialog;
            m_impl->activeDialog = nullptr;
        }
        if (!remainsInsideXanh) {
            m_impl->cancelTimerLocked();
            if (m_impl->operationActive)
                m_impl->vaultLockPending = true;
            else if (m_impl->runtime && !m_impl->runtime->lockVault())
                m_impl->runtime.reset();
        }
    }
    if (hello)
        hello->cancel();
    if (dialog)
        PostMessageW(dialog, TDM_CLICK_BUTTON, IDCANCEL, 0);
    invokeCompletion(std::move(completion), std::nullopt);
}

bool XanhNativeCredentialPicker::canBeginOAuth(HWND ownerWindow)
{
    std::scoped_lock lock(m_impl->mutex);
    return m_impl->runtime && !m_impl->requestActive
        && !m_impl->operationActive && !m_impl->pendingDisconnect
        && !m_impl->oauthBoundToWindow
        && ownerWindow && isCurrentProcessWindow(ownerWindow)
        && GetForegroundWindow() == ownerWindow;
}

std::optional<XanhSensitiveWide> XanhNativeCredentialPicker::beginOAuth(
    HWND ownerWindow)
{
    {
        std::scoped_lock lock(m_impl->mutex);
        if (!m_impl->runtime || m_impl->requestActive || m_impl->operationActive
            || m_impl->pendingDisconnect || m_impl->oauthBoundToWindow
            || !ownerWindow
            || !isCurrentProcessWindow(ownerWindow)
            || GetForegroundWindow() != ownerWindow)
            return std::nullopt;
        m_impl->operationActive = true;
        m_impl->operationOwner = nullptr;
        m_impl->vaultLockPending = false;
    }
    try {
        auto url = m_impl->runtime->beginOAuth();
        auto wide = url ? XanhSensitiveWide::fromUTF8(url->view()) : std::nullopt;
        auto origin = wide
            ? XanhCredentialBridgePolicy::canonicalHTTPSOrigin(wide->view())
            : std::nullopt;
        std::scoped_lock lock(m_impl->mutex);
        bool valid = wide && origin && *origin == m_impl->accountOrigin
            && m_impl->persistRuntimeStateLocked();
        bool lockApplied = m_impl->applyPendingVaultLockLocked();
        valid = valid && lockApplied;
        m_impl->operationActive = false;
        if (!valid) {
            m_impl->oauthOwner = nullptr;
            m_impl->oauthBoundToWindow = false;
            m_impl->runtime.reset();
            return std::nullopt;
        }
        m_impl->oauthOwner = ownerWindow;
        m_impl->oauthBoundToWindow = true;
        return wide;
    } catch (...) {
        std::scoped_lock lock(m_impl->mutex);
        m_impl->applyPendingVaultLockLocked();
        m_impl->operationActive = false;
        m_impl->oauthOwner = nullptr;
        m_impl->oauthBoundToWindow = false;
        m_impl->runtime.reset();
        return std::nullopt;
    }
}

bool XanhNativeCredentialPicker::abandonOAuth(HWND ownerWindow)
{
    std::scoped_lock lock(m_impl->mutex);
    if (!m_impl->runtime || m_impl->requestActive || m_impl->operationActive
        || m_impl->pendingDisconnect || !m_impl->oauthBoundToWindow
        || m_impl->oauthOwner != ownerWindow)
        return false;
    m_impl->oauthOwner = nullptr;
    m_impl->oauthBoundToWindow = false;
    m_impl->runtime.reset();
    m_impl->initialize();
    return m_impl->runtime != nullptr;
}

bool XanhNativeCredentialPicker::canHandleOAuthCallback(HWND ownerWindow)
{
    std::scoped_lock lock(m_impl->mutex);
    if (!m_impl->runtime || m_impl->requestActive || m_impl->operationActive
        || m_impl->pendingDisconnect || !ownerWindow
        || !isCurrentProcessWindow(ownerWindow))
        return false;
    return m_impl->oauthBoundToWindow
        && m_impl->oauthOwner == ownerWindow
        && m_impl->runtime->accountState()
        == XanhNativeSyncRuntime::AccountState::authenticating;
}

bool XanhNativeCredentialPicker::completeOAuth(
    HWND ownerWindow, std::wstring_view callbackURL,
    OAuthCompletion completion)
{
    auto callback = XanhOAuthCallbackParser::parse(callbackURL);
    if (!callback || !completion)
        return false;
    std::uint64_t operationGeneration = 0;
    {
        std::scoped_lock lock(m_impl->mutex);
        if (!m_impl->runtime || m_impl->requestActive || m_impl->operationActive
            || m_impl->pendingDisconnect || !ownerWindow
            || !isCurrentProcessWindow(ownerWindow)
            || !m_impl->oauthBoundToWindow
            || m_impl->oauthOwner != ownerWindow
            || m_impl->runtime->accountState()
                != XanhNativeSyncRuntime::AccountState::authenticating)
            return false;
        m_impl->operationActive = true;
        m_impl->operationOwner = nullptr;
        m_impl->vaultLockPending = false;
        if (++m_impl->generation == 0)
            ++m_impl->generation;
        operationGeneration = m_impl->generation;
    }
    try {
        auto sharedCompletion =
            std::make_shared<OAuthCompletion>(std::move(completion));
        std::thread([service = shared_from_this(),
                        callback = std::move(*callback),
                        sharedCompletion,
                        operationGeneration]() mutable {
            auto& impl = *service->m_impl;
            bool success = false;
            try {
                auto state = impl.runtime->completeOAuth(
                    callback.code.view(), callback.state.view());
                std::scoped_lock lock(impl.mutex);
                success = impl.operationActive
                    && impl.generation == operationGeneration
                    && state
                    && *state == XanhNativeSyncRuntime::AccountState::connected
                    && impl.prepareLocalLoginsKey();
                bool lockApplied = impl.applyPendingVaultLockLocked();
                success = success && lockApplied;
                if (success)
                    success = impl.persistRuntimeStateLocked();
                impl.operationActive = false;
                if (!success)
                    impl.runtime.reset();
                impl.oauthOwner = nullptr;
                impl.oauthBoundToWindow = false;
            } catch (...) {
                std::scoped_lock lock(impl.mutex);
                impl.applyPendingVaultLockLocked();
                impl.operationActive = false;
                impl.oauthOwner = nullptr;
                impl.oauthBoundToWindow = false;
                impl.runtime.reset();
            }
            try {
                (*sharedCompletion)(success);
            } catch (...) {
            }
        }).detach();
        return true;
    } catch (...) {
        std::scoped_lock lock(m_impl->mutex);
        m_impl->applyPendingVaultLockLocked();
        m_impl->operationActive = false;
        // Thread creation failed before native state was consumed. Keep the
        // owner binding so the browser can deliver the callback again.
        return false;
    }
}

void XanhNativeCredentialPicker::syncNow(
    HWND ownerWindow, SyncCompletion completion)
{
    if (!completion)
        return;
    std::uint64_t generation = 0;
    std::shared_ptr<XanhWindowsHello> hello;
    bool accepted = false;
    {
        std::scoped_lock lock(m_impl->mutex);
        accepted = m_impl->runtime && !m_impl->requestActive
            && !m_impl->operationActive && !m_impl->pendingDisconnect
            && ownerWindow && IsWindow(ownerWindow)
            && GetForegroundWindow() == ownerWindow
            && IsWindowVisible(ownerWindow) && !IsIconic(ownerWindow)
            && m_impl->runtime->accountState()
                == XanhNativeSyncRuntime::AccountState::connected;
        if (accepted) {
            m_impl->operationActive = true;
            m_impl->operationOwner = ownerWindow;
            m_impl->vaultLockPending = false;
            m_impl->presencePending = true;
            if (++m_impl->generation == 0)
                ++m_impl->generation;
            generation = m_impl->generation;
            m_impl->syncCompletion = std::move(completion);
            m_impl->cancelTimerLocked();
            m_impl->hello = std::make_shared<XanhWindowsHello>(ownerWindow);
            hello = m_impl->hello;
        }
    }
    if (!accepted) {
        try {
            completion(std::nullopt);
        } catch (...) {
        }
        return;
    }

    try {
        hello->verify(L"Unlock passwords before Firefox Sync",
            [weak = weak_from_this(), ownerWindow, generation](bool verified) {
                auto service = weak.lock();
                if (!service)
                    return;
                auto& impl = *service->m_impl;
                {
                    std::unique_lock lock(impl.mutex);
                    bool current = impl.operationActive
                        && impl.generation == generation
                        && impl.operationOwner == ownerWindow
                        && impl.syncCompletion;
                    if (current) {
                        impl.presencePending = false;
                        impl.hello.reset();
                    }
                    if (!verified || !current || !IsWindow(ownerWindow)
                        || GetForegroundWindow() != ownerWindow
                        || !impl.unlockVaultLocked()) {
                        lock.unlock();
                        impl.completeSync(generation, std::nullopt);
                        return;
                    }
                }

                try {
                    std::thread([service = std::move(service), generation] {
                        auto& impl = *service->m_impl;
                        std::optional<SyncStatus> status;
                        try {
                            auto result = impl.runtime->sync(1, allSyncEngines);
                            status = result
                                ? XanhSyncResultParser::parse(result->view())
                                : std::nullopt;
                            std::scoped_lock lock(impl.mutex);
                            if (status) {
                                bool canCommit = impl.operationActive
                                    && impl.generation == generation
                                    && impl.applyPendingVaultLockLocked()
                                    && impl.persistRuntimeStateLocked();
                                if (!canCommit)
                                    status.reset();
                            }
                            if (!status)
                                impl.runtime.reset();
                        } catch (...) {
                            std::scoped_lock lock(impl.mutex);
                            impl.runtime.reset();
                            status.reset();
                        }
                        impl.completeSync(generation, std::move(status));
                    }).detach();
                } catch (...) {
                    impl.completeSync(generation, std::nullopt);
                }
            });
    } catch (...) {
        m_impl->completeSync(generation, std::nullopt);
    }
}

bool XanhNativeCredentialPicker::disconnect(bool deleteLocal)
{
    {
        std::scoped_lock lock(m_impl->mutex);
        if (!m_impl->runtime || m_impl->requestActive || m_impl->operationActive
            || (m_impl->pendingDisconnect
                && *m_impl->pendingDisconnect != deleteLocal))
            return false;
        m_impl->operationActive = true;
        m_impl->operationOwner = nullptr;
        m_impl->vaultLockPending = false;
        if (!m_impl->pendingDisconnect) {
            auto intent = deleteLocal ? "delete-local" : "keep-local";
            if (m_impl->store.write(
                    XanhDpapiSecretStore::Secret::disconnectIntent, intent)
                != XanhDpapiSecretStore::Status::success) {
                m_impl->operationActive = false;
                return false;
            }
            m_impl->pendingDisconnect = deleteLocal;
        }
    }
    try {
        bool nativeSuccess = m_impl->runtime->disconnect(deleteLocal);
        std::scoped_lock lock(m_impl->mutex);
        bool success = nativeSuccess
            && m_impl->finishDisconnectLocked(deleteLocal);
        bool lockApplied = m_impl->applyPendingVaultLockLocked();
        success = success && lockApplied;
        m_impl->operationActive = false;
        return success;
    } catch (...) {
        std::scoped_lock lock(m_impl->mutex);
        m_impl->applyPendingVaultLockLocked();
        m_impl->operationActive = false;
        return false;
    }
}

std::optional<XanhNativeSyncRuntime::AccountState>
XanhNativeCredentialPicker::accountState()
{
    std::scoped_lock lock(m_impl->mutex);
    if (!m_impl->runtime || m_impl->operationActive || m_impl->pendingDisconnect)
        return std::nullopt;
    return m_impl->runtime->accountState();
}
