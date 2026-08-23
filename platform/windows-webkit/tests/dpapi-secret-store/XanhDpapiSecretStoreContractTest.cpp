#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include "XanhDpapiSecretStore.h"

#include <windows.h>
#include <bcrypt.h>

#include <algorithm>
#include <array>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using Secret = XanhDpapiSecretStore::Secret;
using Status = XanhDpapiSecretStore::Status;

void expect(bool condition, const char* message, unsigned& assertions)
{
    ++assertions;
    if (!condition)
        throw std::runtime_error(message);
}

std::filesystem::path temporaryRoot()
{
    auto base = std::filesystem::temp_directory_path();
    for (unsigned attempt = 0; attempt < 16; ++attempt) {
        std::array<unsigned char, 16> bytes { };
        if (BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0)
            throw std::runtime_error("BCryptGenRandom failed.");
        constexpr wchar_t hex[] = L"0123456789abcdef";
        std::wstring name = L"xanh-dpapi-test-";
        for (auto byte : bytes) {
            name.push_back(hex[byte >> 4]);
            name.push_back(hex[byte & 0xf]);
        }
        auto path = base / name;
        if (CreateDirectoryW(path.c_str(), nullptr))
            return path;
        if (GetLastError() != ERROR_ALREADY_EXISTS)
            throw std::runtime_error("Could not create test directory.");
    }
    throw std::runtime_error("Could not allocate unique test directory.");
}

std::filesystem::path fileFor(const std::filesystem::path& root, Secret secret)
{
    switch (secret) {
    case Secret::accountState:
        return root / L"account-state.bin";
    case Secret::syncState:
        return root / L"sync-state.bin";
    case Secret::loginsKey:
        return root / L"logins-key.bin";
    case Secret::schedule:
        return root / L"schedule.bin";
    case Secret::engineSelection:
        return root / L"engine-selection.bin";
    case Secret::disconnectIntent:
        return root / L"disconnect-intent.bin";
    }
    return { };
}

std::vector<unsigned char> readBytes(const std::filesystem::path& path)
{
    std::ifstream input(path, std::ios::binary);
    return { std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>() };
}

void writeBytes(const std::filesystem::path& path, const std::vector<unsigned char>& bytes)
{
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
}

} // namespace

int main()
{
    unsigned assertions = 0;
    auto root = temporaryRoot();
    try {
        XanhDpapiSecretStore store(root.wstring());
        const std::array secrets {
            Secret::accountState,
            Secret::syncState,
            Secret::loginsKey,
            Secret::schedule,
            Secret::engineSelection,
            Secret::disconnectIntent,
        };

        expect(store.read(Secret::engineSelection).status == Status::notFound, "Missing secret did not report notFound.", assertions);
        auto staleTemporary = root / L".xanh-dpapi-00000000000000000000000000000000.tmp";
        {
            std::ofstream stale(staleTemporary, std::ios::binary);
            stale << "stale ciphertext";
        }
        expect(store.write(Secret::engineSelection, "cleanup-trigger") == Status::success, "Write after stale temporary file failed.", assertions);
        expect(!std::filesystem::exists(staleTemporary), "Bounded stale temporary file was not removed.", assertions);

        for (std::size_t index = 0; index < secrets.size(); ++index) {
            std::string value = "secret-value-" + std::to_string(index);
            expect(store.write(secrets[index], value) == Status::success, "Secret write failed.", assertions);
            auto result = store.read(secrets[index]);
            expect(result.status == Status::success && result.value == value, "Secret round trip failed.", assertions);
            auto ciphertext = readBytes(fileFor(root, secrets[index]));
            expect(!ciphertext.empty(), "Protected secret file is empty.", assertions);
            expect(std::search(ciphertext.begin(), ciphertext.end(), value.begin(), value.end()) == ciphertext.end(), "Plaintext leaked into protected file.", assertions);
        }

        expect(store.write(Secret::accountState, "first") == Status::success, "Initial overwrite fixture failed.", assertions);
        expect(store.write(Secret::accountState, "second") == Status::success, "Atomic overwrite failed.", assertions);
        auto overwritten = store.read(Secret::accountState);
        expect(overwritten.status == Status::success && overwritten.value == "second", "Overwrite did not publish the new value.", assertions);

        expect(store.write(Secret::schedule, "") == Status::success, "Empty value should remain distinct from a missing secret.", assertions);
        auto empty = store.read(Secret::schedule);
        expect(empty.status == Status::success && empty.value.empty(), "Empty secret round trip failed.", assertions);

        std::string maximum(XanhDpapiSecretStore::maximumPlaintextBytes, 'x');
        expect(store.write(Secret::syncState, maximum) == Status::success, "Maximum bounded secret was rejected.", assertions);
        maximum.push_back('x');
        expect(store.write(Secret::syncState, maximum) == Status::invalidInput, "Oversized secret was accepted.", assertions);

        expect(store.write(Secret::loginsKey, "tamper-target") == Status::success, "Tamper fixture write failed.", assertions);
        auto tamperedPath = fileFor(root, Secret::loginsKey);
        auto tampered = readBytes(tamperedPath);
        expect(tampered.size() > 8, "Tamper fixture was unexpectedly small.", assertions);
        tampered[tampered.size() / 2] ^= 0x80;
        writeBytes(tamperedPath, tampered);
        auto corrupt = store.read(Secret::loginsKey);
        expect(corrupt.status == Status::protectionError || corrupt.status == Status::corruptData, "Tampered ciphertext was accepted.", assertions);

        expect(store.write(Secret::accountState, "entropy-bound") == Status::success, "Entropy fixture write failed.", assertions);
        auto accountPath = fileFor(root, Secret::accountState);
        auto syncPath = fileFor(root, Secret::syncState);
        expect(CopyFileW(accountPath.c_str(), syncPath.c_str(), FALSE), "Could not copy entropy fixture.", assertions);
        auto wrongSlot = store.read(Secret::syncState);
        expect(wrongSlot.status == Status::protectionError || wrongSlot.status == Status::corruptData, "A secret decrypted in the wrong slot.", assertions);

        expect(store.remove(Secret::engineSelection) == Status::success, "Secret removal failed.", assertions);
        expect(store.remove(Secret::engineSelection) == Status::success, "Secret removal was not idempotent.", assertions);
        expect(store.read(Secret::engineSelection).status == Status::notFound, "Removed secret is still readable.", assertions);
        {
            std::ofstream stale(root / L".xanh-dpapi-11111111111111111111111111111111.tmp", std::ios::binary);
            stale << "stale encrypted output";
        }
        expect(store.removeAll() == Status::success, "Store removal failed.", assertions);
        expect(!std::filesystem::exists(root), "Store removal left fixed-slot or temporary data behind.", assertions);
        expect(store.removeAll() == Status::success, "Store removal was not idempotent.", assertions);

        expect(XanhDpapiSecretStore::defaultStorageRoot().find(L"Xanh Browser\\FirefoxSync") != std::wstring::npos, "Default store is not below Xanh Browser LocalAppData.", assertions);
        expect(XanhDpapiSecretStore(L"relative-path").write(Secret::accountState, "x") == Status::invalidInput, "Relative root was accepted.", assertions);
        expect(XanhDpapiSecretStore(root.wstring() + L"\\nested\\..").write(Secret::accountState, "x") == Status::invalidInput, "Parent traversal in an explicit root was accepted.", assertions);
        expect(XanhDpapiSecretStore(root.wstring()).write(static_cast<Secret>(999), "x") == Status::invalidInput, "Unknown secret slot was accepted.", assertions);

        std::cout << assertions << " Xanh DPAPI secret-store assertions passed\n";
        return 0;
    } catch (const std::exception& exception) {
        std::cerr << "Xanh DPAPI secret-store test failed: " << exception.what() << '\n';
        std::error_code ignored;
        std::filesystem::remove_all(root, ignored);
        return 1;
    }
}
