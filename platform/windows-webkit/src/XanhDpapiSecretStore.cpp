#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include "XanhDpapiSecretStore.h"

#include <windows.h>
#include <bcrypt.h>
#include <dpapi.h>
#include <knownfolders.h>
#include <shlobj.h>

#include <algorithm>
#include <array>
#include <filesystem>
#include <limits>
#include <optional>
#include <utility>
#include <vector>

namespace {

using Secret = XanhDpapiSecretStore::Secret;
using Status = XanhDpapiSecretStore::Status;

constexpr std::array<std::uint8_t, 8> envelopeMagic { 'X', 'A', 'N', 'H', 'D', 'P', '1', 0 };
constexpr std::uint32_t envelopeVersion = 1;
constexpr std::size_t envelopePrefixBytes = envelopeMagic.size() + 3 * sizeof(std::uint32_t);
constexpr std::size_t sha256Bytes = 32;
constexpr std::size_t envelopeHeaderBytes = envelopePrefixBytes + sha256Bytes;
constexpr std::size_t maximumProtectedBytes = XanhDpapiSecretStore::maximumPlaintextBytes + 64 * 1024;
constexpr wchar_t mutexName[] = L"Local\\XanhBrowser.WinCairo.DpapiSecretStore.v1";
constexpr wchar_t temporaryPrefix[] = L".xanh-dpapi-";
constexpr DWORD mutexWaitMilliseconds = 5000;
constexpr std::size_t maximumDirectoryEntriesToInspect = 64;

class Handle {
public:
    explicit Handle(HANDLE handle = INVALID_HANDLE_VALUE)
        : m_handle(handle)
    {
    }

    ~Handle()
    {
        if (m_handle && m_handle != INVALID_HANDLE_VALUE)
            CloseHandle(m_handle);
    }

    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;

    Handle(Handle&& other) noexcept
        : m_handle(std::exchange(other.m_handle, INVALID_HANDLE_VALUE))
    {
    }

    Handle& operator=(Handle&& other) noexcept
    {
        if (this == &other)
            return *this;
        if (m_handle && m_handle != INVALID_HANDLE_VALUE)
            CloseHandle(m_handle);
        m_handle = std::exchange(other.m_handle, INVALID_HANDLE_VALUE);
        return *this;
    }

    HANDLE get() const { return m_handle; }
    explicit operator bool() const { return m_handle && m_handle != INVALID_HANDLE_VALUE; }

private:
    HANDLE m_handle;
};

class LocalBuffer {
public:
    explicit LocalBuffer(void* value = nullptr)
        : m_value(value)
    {
    }

    ~LocalBuffer()
    {
        if (m_value)
            LocalFree(m_value);
    }

    LocalBuffer(const LocalBuffer&) = delete;
    LocalBuffer& operator=(const LocalBuffer&) = delete;

private:
    void* m_value;
};

class CoTaskBuffer {
public:
    explicit CoTaskBuffer(void* value = nullptr)
        : m_value(value)
    {
    }

    ~CoTaskBuffer()
    {
        if (m_value)
            CoTaskMemFree(m_value);
    }

    CoTaskBuffer(const CoTaskBuffer&) = delete;
    CoTaskBuffer& operator=(const CoTaskBuffer&) = delete;

private:
    void* m_value;
};

class SensitiveLocalBuffer {
public:
    SensitiveLocalBuffer(void* value, std::size_t size)
        : m_value(value)
        , m_size(size)
    {
    }

    ~SensitiveLocalBuffer()
    {
        if (!m_value)
            return;
        SecureZeroMemory(m_value, m_size);
        LocalFree(m_value);
    }

    SensitiveLocalBuffer(const SensitiveLocalBuffer&) = delete;
    SensitiveLocalBuffer& operator=(const SensitiveLocalBuffer&) = delete;

private:
    void* m_value;
    std::size_t m_size;
};

class StoreLock {
public:
    StoreLock()
        : m_mutex(CreateMutexW(nullptr, FALSE, mutexName))
    {
        if (!m_mutex)
            return;
        DWORD result = WaitForSingleObject(m_mutex.get(), mutexWaitMilliseconds);
        m_locked = result == WAIT_OBJECT_0 || result == WAIT_ABANDONED;
    }

    ~StoreLock()
    {
        if (m_locked)
            ReleaseMutex(m_mutex.get());
    }

    explicit operator bool() const { return m_locked; }

private:
    Handle m_mutex;
    bool m_locked { false };
};

std::optional<std::wstring_view> fileNameFor(Secret secret)
{
    switch (secret) {
    case Secret::accountState:
        return L"account-state.bin";
    case Secret::syncState:
        return L"sync-state.bin";
    case Secret::loginsKey:
        return L"logins-key.bin";
    case Secret::schedule:
        return L"schedule.bin";
    case Secret::engineSelection:
        return L"engine-selection.bin";
    case Secret::disconnectIntent:
        return L"disconnect-intent.bin";
    }
    return std::nullopt;
}

std::filesystem::path normalizedAbsoluteRoot(std::wstring_view root)
{
    if (root.empty())
        return { };
    std::filesystem::path path(root);
    if (!path.is_absolute())
        return { };
    for (const auto& component : path) {
        if (component == L"..")
            return { };
    }
    return path.lexically_normal();
}

Status existingDirectoryStatus(const std::filesystem::path& directory)
{
    DWORD attributes = GetFileAttributesW(directory.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        DWORD error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ? Status::notFound : Status::ioError;
    }
    if (!(attributes & FILE_ATTRIBUTE_DIRECTORY) || (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
        return Status::ioError;
    return Status::success;
}

Status ensureDirectory(const std::filesystem::path& directory)
{
    std::error_code error;
    std::filesystem::create_directories(directory, error);
    if (error || existingDirectoryStatus(directory) != Status::success)
        return Status::ioError;
    return Status::success;
}

std::filesystem::path pathFor(const std::filesystem::path& directory, Secret secret)
{
    auto name = fileNameFor(secret);
    return name ? directory / *name : std::filesystem::path { };
}

void appendUint32(std::vector<std::uint8_t>& bytes, std::uint32_t value)
{
    bytes.push_back(static_cast<std::uint8_t>(value));
    bytes.push_back(static_cast<std::uint8_t>(value >> 8));
    bytes.push_back(static_cast<std::uint8_t>(value >> 16));
    bytes.push_back(static_cast<std::uint8_t>(value >> 24));
}

std::optional<std::uint32_t> readUint32(const std::uint8_t* bytes, std::size_t size, std::size_t offset)
{
    if (offset > size || size - offset < sizeof(std::uint32_t))
        return std::nullopt;
    return static_cast<std::uint32_t>(bytes[offset])
        | (static_cast<std::uint32_t>(bytes[offset + 1]) << 8)
        | (static_cast<std::uint32_t>(bytes[offset + 2]) << 16)
        | (static_cast<std::uint32_t>(bytes[offset + 3]) << 24);
}

std::optional<std::array<std::uint8_t, sha256Bytes>> sha256(const std::uint8_t* first, std::size_t firstSize, const std::uint8_t* second = nullptr, std::size_t secondSize = 0)
{
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    std::array<std::uint8_t, sha256Bytes> digest { };
    DWORD objectBytes = 0;
    DWORD written = 0;
    std::vector<std::uint8_t> object;

    NTSTATUS status = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0);
    if (status < 0)
        return std::nullopt;
    auto cleanup = [&] {
        if (hash)
            BCryptDestroyHash(hash);
        if (algorithm)
            BCryptCloseAlgorithmProvider(algorithm, 0);
        if (!object.empty())
            SecureZeroMemory(object.data(), object.size());
    };

    status = BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&objectBytes), sizeof(objectBytes), &written, 0);
    if (status < 0 || written != sizeof(objectBytes)) {
        cleanup();
        return std::nullopt;
    }
    object.resize(objectBytes);
    status = BCryptCreateHash(algorithm, &hash, object.data(), static_cast<ULONG>(object.size()), nullptr, 0, 0);
    if (status < 0) {
        cleanup();
        return std::nullopt;
    }

    if ((firstSize && BCryptHashData(hash, const_cast<std::uint8_t*>(first), static_cast<ULONG>(firstSize), 0) < 0)
        || (secondSize && BCryptHashData(hash, const_cast<std::uint8_t*>(second), static_cast<ULONG>(secondSize), 0) < 0)
        || BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0) < 0) {
        cleanup();
        return std::nullopt;
    }
    cleanup();
    return digest;
}

bool constantTimeEqual(const std::uint8_t* left, const std::uint8_t* right, std::size_t size)
{
    std::uint8_t difference = 0;
    for (std::size_t index = 0; index < size; ++index)
        difference |= left[index] ^ right[index];
    return difference == 0;
}

std::vector<std::uint8_t> entropyFor(Secret secret)
{
    constexpr std::string_view prefix = "Xanh Browser WinCairo DPAPI secret v1:";
    auto name = fileNameFor(secret);
    if (!name)
        return { };
    std::vector<std::uint8_t> entropy(prefix.begin(), prefix.end());
    for (wchar_t character : *name) {
        if (character > 0x7f)
            return { };
        entropy.push_back(static_cast<std::uint8_t>(character));
    }
    return entropy;
}

std::optional<std::vector<std::uint8_t>> makeEnvelope(Secret secret, std::string_view value)
{
    if (!fileNameFor(secret) || value.size() > XanhDpapiSecretStore::maximumPlaintextBytes
        || value.size() > std::numeric_limits<std::uint32_t>::max())
        return std::nullopt;

    std::vector<std::uint8_t> envelope;
    envelope.reserve(envelopeHeaderBytes + value.size());
    envelope.insert(envelope.end(), envelopeMagic.begin(), envelopeMagic.end());
    appendUint32(envelope, envelopeVersion);
    appendUint32(envelope, static_cast<std::uint32_t>(secret));
    appendUint32(envelope, static_cast<std::uint32_t>(value.size()));
    const auto* payload = reinterpret_cast<const std::uint8_t*>(value.data());
    auto digest = sha256(envelope.data(), envelope.size(), payload, value.size());
    if (!digest)
        return std::nullopt;
    envelope.insert(envelope.end(), digest->begin(), digest->end());
    if (!value.empty())
        envelope.insert(envelope.end(), payload, payload + value.size());
    return envelope;
}

XanhDpapiSecretStore::ReadResult parseEnvelope(Secret secret, const std::uint8_t* bytes, std::size_t size)
{
    if (size < envelopeHeaderBytes || !std::equal(envelopeMagic.begin(), envelopeMagic.end(), bytes))
        return { Status::corruptData, { } };
    auto version = readUint32(bytes, size, envelopeMagic.size());
    auto storedSecret = readUint32(bytes, size, envelopeMagic.size() + sizeof(std::uint32_t));
    auto payloadBytes = readUint32(bytes, size, envelopeMagic.size() + 2 * sizeof(std::uint32_t));
    if (!version || !storedSecret || !payloadBytes || *version != envelopeVersion
        || *storedSecret != static_cast<std::uint32_t>(secret)
        || *payloadBytes > XanhDpapiSecretStore::maximumPlaintextBytes
        || static_cast<std::size_t>(*payloadBytes) != size - envelopeHeaderBytes)
        return { Status::corruptData, { } };

    auto digest = sha256(bytes, envelopePrefixBytes, bytes + envelopeHeaderBytes, *payloadBytes);
    if (!digest || !constantTimeEqual(bytes + envelopePrefixBytes, digest->data(), digest->size()))
        return { Status::corruptData, { } };

    return { Status::success, std::string(reinterpret_cast<const char*>(bytes + envelopeHeaderBytes), *payloadBytes) };
}

std::optional<std::vector<std::uint8_t>> protect(Secret secret, std::vector<std::uint8_t>& plaintext)
{
    auto entropy = entropyFor(secret);
    if (entropy.empty() || plaintext.size() > std::numeric_limits<DWORD>::max())
        return std::nullopt;
    DATA_BLOB input { static_cast<DWORD>(plaintext.size()), plaintext.data() };
    DATA_BLOB additionalEntropy { static_cast<DWORD>(entropy.size()), entropy.data() };
    DATA_BLOB output { };
    if (!CryptProtectData(&input, L"Xanh Browser WinCairo secret", &additionalEntropy, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output)) {
        SecureZeroMemory(entropy.data(), entropy.size());
        return std::nullopt;
    }
    LocalBuffer outputOwner(output.pbData);
    if (!output.pbData || !output.cbData) {
        SecureZeroMemory(entropy.data(), entropy.size());
        return std::nullopt;
    }
    std::vector<std::uint8_t> protectedBytes(output.pbData, output.pbData + output.cbData);
    SecureZeroMemory(entropy.data(), entropy.size());
    return protectedBytes;
}

XanhDpapiSecretStore::ReadResult unprotect(Secret secret, std::vector<std::uint8_t>& protectedBytes)
{
    auto entropy = entropyFor(secret);
    if (entropy.empty() || protectedBytes.empty() || protectedBytes.size() > std::numeric_limits<DWORD>::max())
        return { Status::protectionError, { } };
    DATA_BLOB input { static_cast<DWORD>(protectedBytes.size()), protectedBytes.data() };
    DATA_BLOB additionalEntropy { static_cast<DWORD>(entropy.size()), entropy.data() };
    DATA_BLOB output { };
    if (!CryptUnprotectData(&input, nullptr, &additionalEntropy, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output)) {
        SecureZeroMemory(entropy.data(), entropy.size());
        return { Status::protectionError, { } };
    }
    SensitiveLocalBuffer outputOwner(output.pbData, output.cbData);
    SecureZeroMemory(entropy.data(), entropy.size());
    auto result = parseEnvelope(secret, output.pbData, output.cbData);
    return result;
}

Status readProtectedFile(const std::filesystem::path& path, std::vector<std::uint8_t>& bytes)
{
    Handle file(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (!file) {
        DWORD error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ? Status::notFound : Status::ioError;
    }

    FILE_ATTRIBUTE_TAG_INFO tagInfo { };
    if (!GetFileInformationByHandleEx(file.get(), FileAttributeTagInfo, &tagInfo, sizeof(tagInfo))
        || (tagInfo.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)))
        return Status::ioError;
    LARGE_INTEGER size { };
    if (!GetFileSizeEx(file.get(), &size) || size.QuadPart <= 0
        || static_cast<unsigned long long>(size.QuadPart) > maximumProtectedBytes)
        return Status::corruptData;

    bytes.resize(static_cast<std::size_t>(size.QuadPart));
    std::size_t offset = 0;
    while (offset < bytes.size()) {
        DWORD chunk = static_cast<DWORD>(std::min<std::size_t>(bytes.size() - offset, std::numeric_limits<DWORD>::max()));
        DWORD read = 0;
        if (!ReadFile(file.get(), bytes.data() + offset, chunk, &read, nullptr) || !read)
            return Status::ioError;
        offset += read;
    }
    return Status::success;
}

std::optional<std::filesystem::path> createTemporaryFile(const std::filesystem::path& directory, Handle& file)
{
    for (unsigned attempt = 0; attempt < 16; ++attempt) {
        std::array<std::uint8_t, 16> random { };
        if (BCryptGenRandom(nullptr, random.data(), static_cast<ULONG>(random.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0)
            return std::nullopt;
        constexpr wchar_t hex[] = L"0123456789abcdef";
        std::wstring name(temporaryPrefix);
        name.reserve(name.size() + random.size() * 2 + 4);
        for (auto byte : random) {
            name.push_back(hex[byte >> 4]);
            name.push_back(hex[byte & 0xf]);
        }
        name += L".tmp";
        auto path = directory / name;
        Handle candidate(CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr));
        if (candidate) {
            file = std::move(candidate);
            return path;
        }
        if (GetLastError() != ERROR_FILE_EXISTS && GetLastError() != ERROR_ALREADY_EXISTS)
            return std::nullopt;
    }
    return std::nullopt;
}

Status writeProtectedFile(const std::filesystem::path& directory, const std::filesystem::path& target, const std::vector<std::uint8_t>& bytes)
{
    Handle temporary;
    auto temporaryPath = createTemporaryFile(directory, temporary);
    if (!temporaryPath)
        return Status::ioError;

    bool committed = false;
    auto cleanup = [&] {
        temporary = Handle { };
        if (!committed)
            DeleteFileW(temporaryPath->c_str());
    };

    std::size_t offset = 0;
    while (offset < bytes.size()) {
        DWORD chunk = static_cast<DWORD>(std::min<std::size_t>(bytes.size() - offset, std::numeric_limits<DWORD>::max()));
        DWORD written = 0;
        if (!WriteFile(temporary.get(), bytes.data() + offset, chunk, &written, nullptr) || !written) {
            cleanup();
            return Status::ioError;
        }
        offset += written;
    }
    if (!FlushFileBuffers(temporary.get())) {
        cleanup();
        return Status::ioError;
    }
    temporary = Handle { };

    DWORD targetAttributes = GetFileAttributesW(target.c_str());
    if (targetAttributes != INVALID_FILE_ATTRIBUTES
        && (targetAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) {
        cleanup();
        return Status::ioError;
    }

    if (!MoveFileExW(temporaryPath->c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        cleanup();
        return Status::ioError;
    }
    committed = true;
    return Status::success;
}

Status removeFile(const std::filesystem::path& path)
{
    DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        DWORD error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ? Status::success : Status::ioError;
    }
    if (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))
        return Status::ioError;
    if (!DeleteFileW(path.c_str()))
        return GetLastError() == ERROR_FILE_NOT_FOUND ? Status::success : Status::ioError;
    return Status::success;
}

bool isTemporaryFileName(std::wstring_view name)
{
    constexpr std::size_t randomHexCharacters = 32;
    constexpr std::wstring_view suffix = L".tmp";
    constexpr std::wstring_view prefix = temporaryPrefix;
    if (name.size() != prefix.size() + randomHexCharacters + suffix.size()
        || name.substr(0, prefix.size()) != prefix
        || name.substr(name.size() - suffix.size()) != suffix)
        return false;
    auto random = name.substr(prefix.size(), randomHexCharacters);
    return std::all_of(random.begin(), random.end(), [](wchar_t character) {
        return (character >= L'0' && character <= L'9') || (character >= L'a' && character <= L'f');
    });
}

Status removeTemporaryFiles(const std::filesystem::path& directory)
{
    std::error_code error;
    std::size_t inspected = 0;
    for (std::filesystem::directory_iterator iterator(directory, error), end; !error && iterator != end; iterator.increment(error)) {
        if (++inspected > maximumDirectoryEntriesToInspect)
            return Status::ioError;
        auto name = iterator->path().filename().wstring();
        if (!isTemporaryFileName(name))
            continue;
        DWORD attributes = GetFileAttributesW(iterator->path().c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES)
            continue;
        if (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))
            return Status::ioError;
        if (!DeleteFileW(iterator->path().c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND)
            return Status::ioError;
    }
    return error ? Status::ioError : Status::success;
}

} // namespace

std::wstring XanhDpapiSecretStore::defaultStorageRoot()
{
    PWSTR localAppData = nullptr;
    HRESULT result = SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &localAppData);
    CoTaskBuffer owner(localAppData);
    if (FAILED(result) || !localAppData)
        return { };
    return (std::filesystem::path(localAppData) / L"Xanh Browser" / L"FirefoxSync").wstring();
}

XanhDpapiSecretStore::XanhDpapiSecretStore(std::wstring storageRoot)
    : m_storageRoot(std::move(storageRoot))
{
}

XanhDpapiSecretStore::ReadResult XanhDpapiSecretStore::read(Secret secret) const
{
    auto root = normalizedAbsoluteRoot(m_storageRoot);
    auto path = pathFor(root, secret);
    if (root.empty() || path.empty())
        return { Status::invalidInput, { } };
    StoreLock lock;
    if (!lock)
        return { Status::ioError, { } };
    auto directoryStatus = existingDirectoryStatus(root);
    if (directoryStatus != Status::success)
        return { directoryStatus, { } };
    std::vector<std::uint8_t> protectedBytes;
    auto status = readProtectedFile(path, protectedBytes);
    if (status != Status::success)
        return { status, { } };
    return unprotect(secret, protectedBytes);
}

XanhDpapiSecretStore::Status XanhDpapiSecretStore::write(Secret secret, std::string_view value) const
{
    auto root = normalizedAbsoluteRoot(m_storageRoot);
    auto path = pathFor(root, secret);
    if (root.empty() || path.empty() || value.size() > maximumPlaintextBytes)
        return Status::invalidInput;
    StoreLock lock;
    if (!lock)
        return Status::ioError;
    auto directoryStatus = ensureDirectory(root);
    if (directoryStatus != Status::success)
        return directoryStatus;
    auto temporaryStatus = removeTemporaryFiles(root);
    if (temporaryStatus != Status::success)
        return temporaryStatus;
    auto plaintext = makeEnvelope(secret, value);
    if (!plaintext)
        return Status::protectionError;
    auto protectedBytes = protect(secret, *plaintext);
    SecureZeroMemory(plaintext->data(), plaintext->size());
    if (!protectedBytes || protectedBytes->empty() || protectedBytes->size() > maximumProtectedBytes)
        return Status::protectionError;
    return writeProtectedFile(root, path, *protectedBytes);
}

XanhDpapiSecretStore::Status XanhDpapiSecretStore::remove(Secret secret) const
{
    auto root = normalizedAbsoluteRoot(m_storageRoot);
    auto path = pathFor(root, secret);
    if (root.empty() || path.empty())
        return Status::invalidInput;
    StoreLock lock;
    if (!lock)
        return Status::ioError;
    auto directoryStatus = existingDirectoryStatus(root);
    if (directoryStatus == Status::notFound)
        return Status::success;
    if (directoryStatus != Status::success)
        return directoryStatus;
    return removeFile(path);
}

XanhDpapiSecretStore::Status XanhDpapiSecretStore::removeAll() const
{
    auto root = normalizedAbsoluteRoot(m_storageRoot);
    if (root.empty())
        return Status::invalidInput;
    StoreLock lock;
    if (!lock)
        return Status::ioError;
    auto directoryStatus = existingDirectoryStatus(root);
    if (directoryStatus == Status::notFound)
        return Status::success;
    if (directoryStatus != Status::success)
        return directoryStatus;
    for (auto secret : { Secret::accountState, Secret::syncState, Secret::loginsKey, Secret::schedule, Secret::engineSelection, Secret::disconnectIntent }) {
        auto status = removeFile(pathFor(root, secret));
        if (status != Status::success)
            return status;
    }
    auto temporaryStatus = removeTemporaryFiles(root);
    if (temporaryStatus != Status::success)
        return temporaryStatus;
    if (!RemoveDirectoryW(root.c_str()) && GetLastError() != ERROR_DIR_NOT_EMPTY && GetLastError() != ERROR_PATH_NOT_FOUND)
        return Status::ioError;
    return Status::success;
}
