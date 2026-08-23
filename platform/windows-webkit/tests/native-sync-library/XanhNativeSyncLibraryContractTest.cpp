#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include "XanhNativeSyncLibrary.h"

#include <windows.h>

#include <cstring>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void expect(bool condition, const char* message, unsigned& assertions)
{
    ++assertions;
    if (!condition)
        throw std::runtime_error(message);
}

using KeyWipeProbe = int (*)();

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
        expect(validModule != nullptr, "Could not reopen valid fake library for the wipe probe.", assertions);
        FARPROC keyWipeProcedure = GetProcAddress(validModule, "xanh_test_generated_key_was_zeroed");
        KeyWipeProbe keyWipeProbe = nullptr;
        static_assert(sizeof(keyWipeProbe) == sizeof(keyWipeProcedure));
        std::memcpy(&keyWipeProbe, &keyWipeProcedure, sizeof(keyWipeProbe));
        expect(keyWipeProbe && keyWipeProbe() == 1, "Generated Logins probe key was not wiped before release.", assertions);
        FreeLibrary(validModule);

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
