#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <cstring>

namespace {

char* copyString(const char* value)
{
    std::size_t length = std::strlen(value);
    auto* copy = new char[length + 1];
    std::memcpy(copy, value, length + 1);
    return copy;
}

char* lastGeneratedKey = nullptr;
bool generatedKeyWasZeroed = false;

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
    if (value == lastGeneratedKey) {
        generatedKeyWasZeroed = true;
        for (std::size_t index = 0; index < std::strlen("test-local-logins-key"); ++index)
            generatedKeyWasZeroed = generatedKeyWasZeroed && value[index] == '\0';
        lastGeneratedKey = nullptr;
    }
    delete[] value;
}

extern "C" __declspec(dllexport) char* xanh_sync_generate_local_logins_key()
{
#ifdef XANH_FAKE_NO_MOZILLA
    return nullptr;
#else
    lastGeneratedKey = copyString("test-local-logins-key");
    return lastGeneratedKey;
#endif
}

extern "C" __declspec(dllexport) int xanh_test_generated_key_was_zeroed()
{
    return generatedKeyWasZeroed ? 1 : 0;
}

#define XANH_STUB(name) extern "C" __declspec(dllexport) void name() { }

XANH_STUB(xanh_sync_credential_access_allowed)
XANH_STUB(xanh_sync_last_error)
XANH_STUB(xanh_sync_runtime_open)
XANH_STUB(xanh_sync_runtime_free)
XANH_STUB(xanh_sync_runtime_initialize)
XANH_STUB(xanh_sync_runtime_account_state)
XANH_STUB(xanh_sync_runtime_begin_oauth)
XANH_STUB(xanh_sync_runtime_complete_oauth)
XANH_STUB(xanh_sync_runtime_account_json)
XANH_STUB(xanh_sync_runtime_persisted_state)
XANH_STUB(xanh_sync_runtime_unlock_vault)
XANH_STUB(xanh_sync_runtime_lock_vault)
XANH_STUB(xanh_sync_runtime_vault_unlocked)
XANH_STUB(xanh_sync_runtime_sync)
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
XANH_STUB(xanh_sync_runtime_credentials_json)
XANH_STUB(xanh_sync_runtime_add_credential)
XANH_STUB(xanh_sync_runtime_update_credential)
XANH_STUB(xanh_sync_runtime_delete_credential)
#ifndef XANH_FAKE_OMIT_TOUCH
XANH_STUB(xanh_sync_runtime_touch_credential)
#endif
XANH_STUB(xanh_sync_runtime_disconnect)
