#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>

namespace {

char* copyString(const char* value)
{
    std::size_t length = std::strlen(value);
    auto* copy = new char[length + 1];
    std::memcpy(copy, value, length + 1);
    return copy;
}

char* sensitiveString(const char* value);

std::mutex allocationMutex;
std::unordered_map<char*, std::size_t> generatedKeyAllocations;
std::unordered_map<char*, std::size_t> credentialJSONAllocations;
std::atomic<bool> generatedKeyWasZeroed { true };
std::atomic<bool> credentialJSONWasZeroed { true };
std::atomic<int> activeRuntimes { 0 };
std::atomic<int> accountState { 2 };
std::atomic<int> activeCredentialCalls { 0 };
std::atomic<bool> credentialCallCollision { false };
std::atomic<bool> oversizedCredentials { false };
std::atomic<bool> failKeyGeneration { false };
std::atomic<bool> failRuntimeOpen { false };
std::atomic<bool> emptyPersistedState { false };
HANDLE runtimeFreedEvent = nullptr;
thread_local std::string lastErrorText = "test native Sync error";

struct FakeRuntime {
    bool vaultUnlocked { false };
};

char* sensitiveString(const char* value)
{
    char* result = copyString(value);
    std::scoped_lock lock(allocationMutex);
    credentialJSONAllocations.emplace(result, std::strlen(value));
    return result;
}

} // namespace

extern "C" __declspec(dllexport) char* xanh_sync_core_version()
{
#ifdef XANH_FAKE_BAD_VERSION
    return copyString("0.0.0-test");
#else
    return copyString("1.0.0-alpha.1");
#endif
}

extern "C" __declspec(dllexport) void xanh_sync_string_free(char* value)
{
    {
        std::scoped_lock lock(allocationMutex);
        auto verifyWipe = [value](auto& allocations, std::atomic<bool>& aggregate) {
            auto allocation = allocations.find(value);
            if (allocation == allocations.end())
                return;
            bool zeroed = true;
            for (std::size_t index = 0; index < allocation->second; ++index)
                zeroed = zeroed && value[index] == '\0';
            if (!zeroed)
                aggregate = false;
            allocations.erase(allocation);
        };
        verifyWipe(generatedKeyAllocations, generatedKeyWasZeroed);
        verifyWipe(credentialJSONAllocations, credentialJSONWasZeroed);
    }
    delete[] value;
}

extern "C" __declspec(dllexport) char* xanh_sync_generate_local_logins_key()
{
#ifdef XANH_FAKE_NO_MOZILLA
    return nullptr;
#else
    if (failKeyGeneration) {
        lastErrorText = "forced key generation failure";
        return nullptr;
    }
    char* generatedKey = copyString("test-local-logins-key");
    {
        std::scoped_lock lock(allocationMutex);
        generatedKeyAllocations.emplace(
            generatedKey, std::strlen("test-local-logins-key"));
    }
    return generatedKey;
#endif
}

extern "C" __declspec(dllexport) int xanh_test_generated_key_was_zeroed()
{
    return generatedKeyWasZeroed ? 1 : 0;
}

extern "C" __declspec(dllexport) int xanh_test_credential_json_was_zeroed()
{
    return credentialJSONWasZeroed ? 1 : 0;
}

extern "C" __declspec(dllexport) void xanh_test_set_fail_key_generation(int value)
{
    failKeyGeneration = value != 0;
}

extern "C" __declspec(dllexport) void xanh_test_set_empty_persisted_state(int value)
{
    emptyPersistedState = value != 0;
}

extern "C" __declspec(dllexport) void xanh_test_set_fail_runtime_open(int value)
{
    failRuntimeOpen = value != 0;
}

extern "C" __declspec(dllexport) void xanh_test_set_account_state(int value)
{
    accountState = value;
}

extern "C" __declspec(dllexport) void xanh_test_set_oversized_credentials(int value)
{
    oversizedCredentials = value != 0;
}

extern "C" __declspec(dllexport) int xanh_test_credential_call_collision()
{
    return credentialCallCollision ? 1 : 0;
}

extern "C" __declspec(dllexport) void xanh_test_set_runtime_freed_event(HANDLE event)
{
    runtimeFreedEvent = event;
}

extern "C" __declspec(dllexport) char* xanh_sync_last_error()
{
    return copyString(lastErrorText.c_str());
}

extern "C" __declspec(dllexport) void* xanh_sync_runtime_open(
    const char* configuration, const char* profile, const char*, const char*, const char*)
{
    if (!configuration || !*configuration || !profile || !*profile) {
        lastErrorText = "invalid runtime parameters";
        return nullptr;
    }
    if (failRuntimeOpen) {
        lastErrorText = "forced runtime open failure";
        return nullptr;
    }
    int expected = 0;
    if (!activeRuntimes.compare_exchange_strong(expected, 1)) {
        lastErrorText = "test runtime already active";
        return nullptr;
    }
    return new FakeRuntime;
}

extern "C" __declspec(dllexport) void xanh_sync_runtime_free(void* runtime)
{
    delete static_cast<FakeRuntime*>(runtime);
    activeRuntimes = 0;
    if (runtimeFreedEvent)
        SetEvent(runtimeFreedEvent);
}

extern "C" __declspec(dllexport) int xanh_sync_runtime_initialize(void*)
{
    return accountState;
}

extern "C" __declspec(dllexport) int xanh_sync_runtime_account_state(void*)
{
    return accountState;
}

extern "C" __declspec(dllexport) char* xanh_sync_runtime_begin_oauth(void* runtime)
{
    if (!runtime) {
        lastErrorText = "test native Sync error";
        return nullptr;
    }
    accountState = 1;
    return sensitiveString(
        "https://accounts.example.test/authorization?state=test-state");
}

extern "C" __declspec(dllexport) int xanh_sync_runtime_complete_oauth(
    void* runtime, const char* code, const char* state)
{
    if (!runtime || !code || std::strcmp(code, "test-code")
        || !state || std::strcmp(state, "test-state")) {
        lastErrorText = "test native Sync error";
        return -1;
    }
    accountState = 2;
    return accountState;
}

extern "C" __declspec(dllexport) char* xanh_sync_runtime_account_json(void* runtime)
{
    if (!runtime) {
        lastErrorText = "test native Sync error";
        return nullptr;
    }
    return sensitiveString("{\"account\":\"test-secret\"}");
}

extern "C" __declspec(dllexport) char* xanh_sync_runtime_persisted_state(void* runtime)
{
    if (!runtime) {
        lastErrorText = "test native Sync error";
        return nullptr;
    }
    return sensitiveString(emptyPersistedState
        ? "" : "{\"sync\":\"test-secret\"}");
}

extern "C" __declspec(dllexport) char* xanh_sync_runtime_sync(
    void* runtime, int reason, const char* engines)
{
    if (!runtime || reason != 1 || !engines
        || std::strcmp(engines,
            "[\"bookmarks\",\"history\",\"tabs\",\"passwords\"]")) {
        lastErrorText = "test native Sync error";
        return nullptr;
    }
    return sensitiveString(
        "{\"next_sync_allowed_epoch_seconds\":null,\"status\":\"success\"}");
}

extern "C" __declspec(dllexport) bool xanh_sync_runtime_disconnect(
    void* runtime, bool)
{
    if (!runtime) {
        lastErrorText = "test native Sync error";
        return false;
    }
    static_cast<FakeRuntime*>(runtime)->vaultUnlocked = false;
    accountState = 0;
    return true;
}

extern "C" __declspec(dllexport) bool xanh_sync_runtime_vault_unlocked(void* runtime)
{
    return runtime && static_cast<FakeRuntime*>(runtime)->vaultUnlocked;
}

extern "C" __declspec(dllexport) bool xanh_sync_runtime_unlock_vault(void* runtime, const char* key)
{
    if (!runtime || !key || std::strcmp(key, "test-local-logins-key")) {
        lastErrorText = "test native Sync error";
        return false;
    }
    static_cast<FakeRuntime*>(runtime)->vaultUnlocked = true;
    return true;
}

extern "C" __declspec(dllexport) bool xanh_sync_runtime_lock_vault(void* runtime)
{
    if (!runtime)
        return false;
    static_cast<FakeRuntime*>(runtime)->vaultUnlocked = false;
    return true;
}

extern "C" __declspec(dllexport) char* xanh_sync_runtime_credentials_json(
    void* runtime, const char* context)
{
    if (!runtime || !static_cast<FakeRuntime*>(runtime)->vaultUnlocked
        || !context || std::strcmp(context, "{\"document_url\":\"https://example.test/login\"}")) {
        lastErrorText = "test native Sync error";
        return nullptr;
    }
    if (activeCredentialCalls.fetch_add(1) != 0)
        credentialCallCollision = true;
    Sleep(25);
    activeCredentialCalls.fetch_sub(1);
    if (oversizedCredentials) {
        constexpr std::size_t maximumCredentialOutputBytes = 4 * 1024 * 1024;
        char* credentialJSON = new char[maximumCredentialOutputBytes + 2];
        std::memset(credentialJSON, 'x', maximumCredentialOutputBytes + 1);
        credentialJSON[maximumCredentialOutputBytes + 1] = '\0';
        {
            std::scoped_lock lock(allocationMutex);
            credentialJSONAllocations.emplace(
                credentialJSON, maximumCredentialOutputBytes + 1);
        }
        return credentialJSON;
    }
    constexpr char credentialJSON[] = "[{\"password\":\"test-password\"}]";
    char* result = copyString(credentialJSON);
    {
        std::scoped_lock lock(allocationMutex);
        credentialJSONAllocations.emplace(result, std::strlen(credentialJSON));
    }
    return result;
}

#ifndef XANH_FAKE_OMIT_TOUCH
extern "C" __declspec(dllexport) bool xanh_sync_runtime_touch_credential(
    void* runtime, const char* id, const char* context)
{
    return runtime && id && !std::strcmp(id, "login_1")
        && context && !std::strcmp(context, "{\"document_url\":\"https://example.test/login\"}");
}
#endif

#define XANH_STUB(name) extern "C" __declspec(dllexport) void name() { }

XANH_STUB(xanh_sync_credential_access_allowed)
XANH_STUB(xanh_sync_runtime_update_local_tabs)
XANH_STUB(xanh_sync_runtime_remote_tabs_json)
XANH_STUB(xanh_sync_bookmark_root_guid)
XANH_STUB(xanh_sync_runtime_create_bookmark)
XANH_STUB(xanh_sync_runtime_import_legacy_bookmarks)
XANH_STUB(xanh_sync_runtime_bookmarks_json)
XANH_STUB(xanh_sync_runtime_update_bookmark)
XANH_STUB(xanh_sync_runtime_delete_bookmark)
XANH_STUB(xanh_sync_runtime_record_history)
XANH_STUB(xanh_sync_runtime_recent_history_json)
XANH_STUB(xanh_sync_runtime_delete_history_visit)
XANH_STUB(xanh_sync_runtime_clear_history)
XANH_STUB(xanh_sync_runtime_add_credential)
XANH_STUB(xanh_sync_runtime_update_credential)
XANH_STUB(xanh_sync_runtime_delete_credential)
