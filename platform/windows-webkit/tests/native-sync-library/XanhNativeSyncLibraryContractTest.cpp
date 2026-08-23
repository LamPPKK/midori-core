#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include "XanhNativeSyncLibrary.h"
#include "XanhNativeSyncRuntime.h"

#include <windows.h>

#include <atomic>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>

namespace {

void expect(bool condition, const char* message, unsigned& assertions)
{
    ++assertions;
    if (!condition)
        throw std::runtime_error(message);
}

using KeyWipeProbe = int (*)();
using SetIntProbe = void (*)(int);
using SetHandleProbe = void (*)(HANDLE);

template<typename Function>
Function resolve(HMODULE module, const char* name)
{
    FARPROC procedure = GetProcAddress(module, name);
    Function function = nullptr;
    static_assert(sizeof(function) == sizeof(procedure));
    std::memcpy(&function, &procedure, sizeof(function));
    return function;
}

} // namespace

int wmain(int argc, wchar_t** argv)
{
    unsigned assertions = 0;
    try {
        expect(argc == 5, "Expected four fake native-library paths.", assertions);

        expect(!XanhNativeSyncLibrary::loadSignedFromPathForTesting(argv[1]), "Unsigned fake library passed production Authenticode verification.", assertions);
        auto valid = XanhNativeSyncLibrary::loadUnsignedFromPathForTesting(argv[1]);
        expect(valid != nullptr, "Valid Mozilla native library was rejected.", assertions);
        expect(valid->version() == XanhNativeSyncLibrary::expectedCoreVersion, "Validated native version is incorrect.", assertions);
        HMODULE validModule = LoadLibraryExW(argv[1], nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        expect(validModule != nullptr, "Could not reopen valid fake library for contract probes.", assertions);
        auto setFailKeyGeneration = resolve<SetIntProbe>(validModule, "xanh_test_set_fail_key_generation");
        auto setFailRuntimeOpen = resolve<SetIntProbe>(validModule, "xanh_test_set_fail_runtime_open");
        auto setAccountState = resolve<SetIntProbe>(validModule, "xanh_test_set_account_state");
        auto setOversizedCredentials = resolve<SetIntProbe>(validModule, "xanh_test_set_oversized_credentials");
        auto credentialCallCollision = resolve<KeyWipeProbe>(validModule, "xanh_test_credential_call_collision");
        auto setRuntimeFreedEvent = resolve<SetHandleProbe>(validModule, "xanh_test_set_runtime_freed_event");
        expect(setFailKeyGeneration && setFailRuntimeOpen && setAccountState
                && setOversizedCredentials && credentialCallCollision && setRuntimeFreedEvent,
            "Could not resolve the native runtime contract probes.", assertions);

        std::string error;
        auto generatedKey = XanhNativeSyncRuntime::generateLocalLoginsKey(*valid, error);
        expect(generatedKey && generatedKey->view() == "test-local-logins-key", "A bounded local Logins key was not generated.", assertions);
        expect(error.empty(), "Successful key generation retained a stale error.", assertions);
        generatedKey.reset();
        setFailKeyGeneration(1);
        expect(!XanhNativeSyncRuntime::generateLocalLoginsKey(*valid, error), "A forced key-generation failure succeeded.", assertions);
        expect(error == "forced key generation failure", "Key-generation failure lost its native error.", assertions);
        setFailKeyGeneration(0);

        auto moveSource = XanhSensitiveUTF8::take(std::string("short-secret"));
        XanhSensitiveUTF8 moveTarget(std::move(moveSource));
        expect(moveSource.empty() && moveTarget.view() == "short-secret", "Sensitive move construction did not clear its source.", assertions);
        auto moveAssignmentTarget = XanhSensitiveUTF8::take(std::string("old-secret"));
        moveAssignmentTarget = std::move(moveTarget);
        expect(moveTarget.empty() && moveAssignmentTarget.view() == "short-secret", "Sensitive move assignment did not clear its source.", assertions);

        auto keyWipeProbe = resolve<KeyWipeProbe>(validModule, "xanh_test_generated_key_was_zeroed");
        expect(keyWipeProbe && keyWipeProbe() == 1, "Generated Logins probe key was not wiped before release.", assertions);

        auto invalidParameters = XanhNativeSyncRuntime::OpenParameters {
            std::string("{}\0forged", 9),
            "C:\\XanhBrowser\\Sync",
            std::nullopt,
            std::nullopt,
            std::nullopt,
        };
        auto invalidLibrary = XanhNativeSyncLibrary::loadUnsignedFromPathForTesting(argv[1]);
        expect(!XanhNativeSyncRuntime::open(std::move(invalidLibrary), std::move(invalidParameters), error), "An embedded-NUL runtime configuration was accepted.", assertions);
        expect(error == "Invalid native Sync runtime configuration", "Invalid runtime input did not return a local error.", assertions);

        auto oversizedParameters = XanhNativeSyncRuntime::OpenParameters {
            std::string(XanhNativeSyncRuntime::maximumConfigurationBytes + 1, 'x'),
            "C:\\XanhBrowser\\Sync",
            std::nullopt,
            std::nullopt,
            std::nullopt,
        };
        auto oversizedLibrary = XanhNativeSyncLibrary::loadUnsignedFromPathForTesting(argv[1]);
        expect(!XanhNativeSyncRuntime::open(std::move(oversizedLibrary), std::move(oversizedParameters), error), "An oversized runtime configuration was accepted.", assertions);

        setFailRuntimeOpen(1);
        auto failedOpenLibrary = XanhNativeSyncLibrary::loadUnsignedFromPathForTesting(argv[1]);
        auto failedOpenParameters = XanhNativeSyncRuntime::OpenParameters {
            "{}", "C:\\XanhBrowser\\Sync", std::nullopt, std::nullopt, std::nullopt
        };
        expect(!XanhNativeSyncRuntime::open(std::move(failedOpenLibrary), std::move(failedOpenParameters), error), "A forced runtime-open failure succeeded.", assertions);
        expect(error == "forced runtime open failure", "Runtime-open failure lost its native error.", assertions);
        setFailRuntimeOpen(0);

        auto parameters = XanhNativeSyncRuntime::OpenParameters {
            "{}",
            "C:\\XanhBrowser\\Sync",
            std::nullopt,
            std::nullopt,
            std::nullopt,
        };
        auto runtime = XanhNativeSyncRuntime::open(std::move(valid), std::move(parameters), error);
        expect(runtime != nullptr, "A valid native Sync runtime was rejected.", assertions);
        expect(error.empty(), "Successful runtime open retained a stale error.", assertions);
        expect(runtime->initialize() == XanhNativeSyncRuntime::AccountState::connected, "Runtime initialization returned the wrong account state.", assertions);
        constexpr XanhNativeSyncRuntime::AccountState states[] = {
            XanhNativeSyncRuntime::AccountState::disconnected,
            XanhNativeSyncRuntime::AccountState::authenticating,
            XanhNativeSyncRuntime::AccountState::connected,
            XanhNativeSyncRuntime::AccountState::authIssues,
        };
        for (auto state : states) {
            setAccountState(static_cast<int>(state));
            expect(runtime->accountState() == state, "A documented native account state was not mapped exactly.", assertions);
        }
        setAccountState(99);
        expect(!runtime->accountState(), "An out-of-range native account state was accepted.", assertions);
        expect(runtime->takeLastError() == "Invalid account state from native core", "An out-of-range native account state was not diagnosed locally.", assertions);
        setAccountState(2);

        auto secondLibrary = XanhNativeSyncLibrary::loadUnsignedFromPathForTesting(argv[1]);
        auto secondParameters = XanhNativeSyncRuntime::OpenParameters {
            "{}", "C:\\XanhBrowser\\SecondSync", std::nullopt, std::nullopt, std::nullopt
        };
        expect(!XanhNativeSyncRuntime::open(std::move(secondLibrary), std::move(secondParameters), error), "A second native Sync runtime was accepted.", assertions);
        expect(error == "test runtime already active", "The singleton runtime rejection lost its native error.", assertions);

        expect(!runtime->vaultUnlocked(), "A newly opened vault was unexpectedly unlocked.", assertions);
        expect(!runtime->unlockVault("wrong-key"), "An invalid Logins key unlocked the vault.", assertions);
        expect(runtime->takeLastError() == "test native Sync error", "A native failure was not captured on its calling thread.", assertions);
        std::atomic<bool> failureCaptured { false };
        std::atomic<bool> successfulCallCompleted { false };
        std::string callingThreadError;
        std::thread failingThread([&] {
            failureCaptured = !runtime->unlockVault("wrong-key");
            while (!successfulCallCompleted)
                std::this_thread::yield();
            callingThreadError = runtime->takeLastError();
        });
        std::thread successfulThread([&] {
            while (!failureCaptured)
                std::this_thread::yield();
            runtime->accountState();
            successfulCallCompleted = true;
        });
        failingThread.join();
        successfulThread.join();
        expect(callingThreadError == "test native Sync error", "A calling thread lost its native error to another thread.", assertions);
        expect(!runtime->unlockVault("wrong-key"), "A repeated invalid key unexpectedly unlocked the vault.", assertions);
        expect(!runtime->vaultUnlocked(), "A locked vault was reported unlocked after an error.", assertions);
        expect(runtime->takeLastError() == "Unknown Firefox Sync error", "A valid locked-state query retained a stale error.", assertions);
        expect(runtime->unlockVault("test-local-logins-key"), "A valid Logins key did not unlock the vault.", assertions);
        expect(runtime->vaultUnlocked(), "The unlocked vault was reported locked.", assertions);
        constexpr std::string_view context = "{\"document_url\":\"https://example.test/login\"}";
        {
            auto credentials = runtime->credentialsJSON(context);
            expect(credentials && credentials->view() == "[{\"password\":\"test-password\"}]", "Credential JSON was not returned exactly.", assertions);
        }
        auto credentialWipeProbe = resolve<KeyWipeProbe>(validModule, "xanh_test_credential_json_was_zeroed");
        expect(credentialWipeProbe && credentialWipeProbe() == 1, "Credential JSON was not wiped before native release.", assertions);
        expect(!runtime->credentialsJSON(std::string("safe\0forged", 11)), "An embedded-NUL credential context was accepted.", assertions);
        expect(!runtime->credentialsJSON(std::string(XanhNativeSyncRuntime::maximumCredentialContextBytes + 1, 'x')), "An oversized credential context was accepted.", assertions);

        std::atomic<unsigned> successfulCredentialCalls { 0 };
        auto readCredentials = [&] {
            auto credentials = runtime->credentialsJSON(context);
            if (credentials && credentials->view() == "[{\"password\":\"test-password\"}]")
                ++successfulCredentialCalls;
        };
        std::thread firstRead(readCredentials);
        std::thread secondRead(readCredentials);
        firstRead.join();
        secondRead.join();
        expect(successfulCredentialCalls == 2, "Serialized credential calls did not both succeed.", assertions);
        expect(credentialCallCollision() == 0, "Native credential calls overlapped despite adapter serialization.", assertions);

        setOversizedCredentials(1);
        expect(!runtime->credentialsJSON(context), "Oversized credential JSON was accepted.", assertions);
        expect(runtime->takeLastError() == "Oversized credential output from native core", "Oversized credential JSON did not return a local error.", assertions);
        expect(credentialWipeProbe() == 1, "The inspected prefix of oversized credential JSON was not wiped.", assertions);
        setOversizedCredentials(0);

        expect(runtime->touchCredential("login_1", context), "A valid credential touch failed.", assertions);
        expect(!runtime->touchCredential("bad id", context), "An invalid credential ID was accepted.", assertions);
        expect(runtime->takeLastError() == "Invalid credential touch input", "A host validation failure was not retained safely.", assertions);
        expect(runtime->lockVault(), "The vault did not lock.", assertions);
        expect(!runtime->vaultUnlocked(), "A locked vault was reported unlocked.", assertions);

        HANDLE runtimeFreedEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        expect(runtimeFreedEvent != nullptr, "Could not create the runtime-free ordering event.", assertions);
        setRuntimeFreedEvent(runtimeFreedEvent);
        FreeLibrary(validModule);
        validModule = nullptr;
        runtime.reset();
        expect(WaitForSingleObject(runtimeFreedEvent, 0) == WAIT_OBJECT_0, "The runtime was not freed while its owning DLL was still loaded.", assertions);
        CloseHandle(runtimeFreedEvent);

        expect(!XanhNativeSyncLibrary::loadUnsignedFromPathForTesting(argv[2]), "Mismatched native core version was accepted.", assertions);
        expect(!XanhNativeSyncLibrary::loadUnsignedFromPathForTesting(argv[3]), "Portable core without Mozilla backend was accepted.", assertions);
        expect(!XanhNativeSyncLibrary::loadUnsignedFromPathForTesting(argv[4]), "Native core with a missing C ABI export was accepted.", assertions);
        expect(!XanhNativeSyncLibrary::loadUnsignedFromPathForTesting(L"xanh_sync_core.dll"), "Relative native-library path was accepted.", assertions);

        auto wrongName = std::filesystem::path(argv[1]).parent_path() / L"renamed-sync-core.dll";
        expect(CopyFileW(argv[1], wrongName.c_str(), FALSE), "Could not create wrong-name fixture.", assertions);
        expect(!XanhNativeSyncLibrary::loadUnsignedFromPathForTesting(wrongName.wstring()), "Alternate native-library filename was accepted.", assertions);
        expect(DeleteFileW(wrongName.c_str()), "Could not remove wrong-name fixture.", assertions);

        std::cout << assertions << " Xanh native Sync library assertions passed\n";
        return 0;
    } catch (const std::exception& exception) {
        std::cerr << "Xanh native Sync library test failed: " << exception.what() << '\n';
        return 1;
    }
}
