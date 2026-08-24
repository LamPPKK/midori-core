/*
 * Copyright (C) 2026 Xanh Browser contributors.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.
 */

#include "XanhPortableBackup.h"

#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX 1
#endif
#include <windows.h>
#include <bcrypt.h>

#include <algorithm>
#include <limits>
#include <stdexcept>
#include <utility>

namespace XanhPortableBackup {
namespace {

constexpr std::array<uint8_t, 8> magic { 'X', 'A', 'N', 'H', 'B', 'K', '1', 0 };
constexpr uint32_t formatVersion = 1;
constexpr uint32_t payloadVersion = 1;
constexpr uint32_t defaultIterations = 210000;
constexpr uint32_t minimumIterations = 100000;
constexpr uint32_t maximumIterations = 1000000;
constexpr size_t saltBytes = 16;
constexpr size_t nonceBytes = 12;
constexpr size_t tagBytes = 16;
constexpr size_t keyBytes = 32;
constexpr size_t minimumEncodedBytes = 64;

class AlgorithmHandle {
public:
    AlgorithmHandle() = default;
    AlgorithmHandle(const AlgorithmHandle&) = delete;
    AlgorithmHandle& operator=(const AlgorithmHandle&) = delete;
    ~AlgorithmHandle()
    {
        if (m_handle)
            BCryptCloseAlgorithmProvider(m_handle, 0);
    }

    BCRYPT_ALG_HANDLE* address() { return &m_handle; }
    operator BCRYPT_ALG_HANDLE() const { return m_handle; }

private:
    BCRYPT_ALG_HANDLE m_handle { };
};

class KeyHandle {
public:
    KeyHandle() = default;
    KeyHandle(const KeyHandle&) = delete;
    KeyHandle& operator=(const KeyHandle&) = delete;
    ~KeyHandle()
    {
        if (m_handle)
            BCryptDestroyKey(m_handle);
    }

    BCRYPT_KEY_HANDLE* address() { return &m_handle; }
    operator BCRYPT_KEY_HANDLE() const { return m_handle; }

private:
    BCRYPT_KEY_HANDLE m_handle { };
};

template<typename T> class SecureVector final : public std::vector<T> {
public:
    using std::vector<T>::vector;
    SecureVector(const SecureVector&) = delete;
    SecureVector& operator=(const SecureVector&) = delete;
    SecureVector(SecureVector&&) noexcept = default;
    SecureVector& operator=(SecureVector&&) = delete;
    ~SecureVector()
    {
        if (!this->empty())
            SecureZeroMemory(this->data(), this->size() * sizeof(T));
    }
};

[[noreturn]] void fail(const char* message)
{
    throw std::runtime_error(message);
}

void requireSuccess(NTSTATUS status, const char* message)
{
    if (!BCRYPT_SUCCESS(status))
        fail(message);
}

ULONG checkedULONG(size_t value)
{
    if (value > std::numeric_limits<ULONG>::max())
        fail("Backup buffer is too large.");
    return static_cast<ULONG>(value);
}

std::string utf8FromWide(std::wstring_view value)
{
    if (value.empty())
        return { };
    if (value.size() > static_cast<size_t>(std::numeric_limits<int>::max()))
        fail("Backup text is too large.");
    int required = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (required <= 0)
        fail("Backup text is not valid Unicode.");
    std::string result(static_cast<size_t>(required), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), required, nullptr, nullptr) != required)
        fail("Backup text is not valid Unicode.");
    return result;
}

std::wstring wideFromUTF8(std::string_view value)
{
    if (value.empty())
        return { };
    if (value.size() > static_cast<size_t>(std::numeric_limits<int>::max()))
        fail("Backup text is too large.");
    int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
    if (required <= 0)
        fail("Backup text is not valid UTF-8.");
    std::wstring result(static_cast<size_t>(required), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), required) != required)
        fail("Backup text is not valid UTF-8.");
    return result;
}

SecureVector<char> secureUTF8FromWide(std::wstring_view value)
{
    if (value.empty() || value.size() > static_cast<size_t>(std::numeric_limits<int>::max()))
        fail("Backup password is not valid Unicode.");
    int required = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (required <= 0)
        fail("Backup password is not valid Unicode.");
    SecureVector<char> result(static_cast<size_t>(required));
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), required, nullptr, nullptr) != required)
        fail("Backup password is not valid Unicode.");
    return result;
}

class Writer {
public:
    void writeByte(uint8_t value) { m_bytes.push_back(value); }

    void writeUInt32(uint32_t value)
    {
        m_bytes.push_back(static_cast<uint8_t>(value >> 24));
        m_bytes.push_back(static_cast<uint8_t>(value >> 16));
        m_bytes.push_back(static_cast<uint8_t>(value >> 8));
        m_bytes.push_back(static_cast<uint8_t>(value));
    }

    void writeUInt64(uint64_t value)
    {
        writeUInt32(static_cast<uint32_t>(value >> 32));
        writeUInt32(static_cast<uint32_t>(value));
    }

    void writeBytes(const uint8_t* bytes, size_t size)
    {
        if (size > maximumEncodedBytes || m_bytes.size() > maximumEncodedBytes - size)
            fail("Backup is too large.");
        m_bytes.insert(m_bytes.end(), bytes, bytes + size);
    }

    void writeString(std::wstring_view value)
    {
        auto utf8 = utf8FromWide(value);
        if (utf8.empty() || utf8.size() > maximumStringBytes)
            fail("Invalid backup text.");
        writeUInt32(static_cast<uint32_t>(utf8.size()));
        writeBytes(reinterpret_cast<const uint8_t*>(utf8.data()), utf8.size());
    }

    std::vector<uint8_t> take() { return std::move(m_bytes); }

private:
    std::vector<uint8_t> m_bytes;
};

class Reader {
public:
    explicit Reader(const std::vector<uint8_t>& bytes)
        : m_bytes(bytes)
    {
    }

    size_t remaining() const { return m_bytes.size() - m_position; }

    uint8_t readByte()
    {
        ensure(1);
        return m_bytes[m_position++];
    }

    uint32_t readUInt32()
    {
        ensure(4);
        uint32_t value = static_cast<uint32_t>(m_bytes[m_position]) << 24
            | static_cast<uint32_t>(m_bytes[m_position + 1]) << 16
            | static_cast<uint32_t>(m_bytes[m_position + 2]) << 8
            | static_cast<uint32_t>(m_bytes[m_position + 3]);
        m_position += 4;
        return value;
    }

    uint64_t readUInt64()
    {
        return (static_cast<uint64_t>(readUInt32()) << 32) | readUInt32();
    }

    std::vector<uint8_t> readBytes(size_t count)
    {
        ensure(count);
        std::vector<uint8_t> result(m_bytes.begin() + m_position, m_bytes.begin() + m_position + count);
        m_position += count;
        return result;
    }

    std::wstring readString()
    {
        auto size = readUInt32();
        if (!size || size > maximumStringBytes)
            fail("Invalid backup text.");
        auto bytes = readBytes(size);
        return wideFromUTF8({ reinterpret_cast<const char*>(bytes.data()), bytes.size() });
    }

private:
    void ensure(size_t count)
    {
        if (count > remaining())
            fail("Truncated backup.");
    }

    const std::vector<uint8_t>& m_bytes;
    size_t m_position { };
};

void validatePassphrase(std::wstring_view passphrase)
{
    if (passphrase.size() < 8 || passphrase.size() > 1024)
        fail("Backup password must contain between 8 and 1,024 characters.");
}

bool isUnicodeWhitespace(wchar_t character)
{
    return (character >= 0x0009 && character <= 0x000d)
        || character == 0x0020 || character == 0x0085 || character == 0x00a0 || character == 0x1680
        || (character >= 0x2000 && character <= 0x200a)
        || character == 0x2028 || character == 0x2029 || character == 0x202f || character == 0x205f || character == 0x3000;
}

void validatePayload(const Payload& payload, URLValidator validator)
{
    bool sourceIsWhitespace = std::all_of(payload.sourceEdition.begin(), payload.sourceEdition.end(), isUnicodeWhitespace);
    if (!validator || payload.createdAtEpochMilliseconds > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())
        || payload.sourceEdition.empty() || payload.sourceEdition.size() > maximumStringBytes || sourceIsWhitespace
        || payload.urls.empty() || payload.urls.size() > maximumURLs
        || payload.selectedIndex >= payload.urls.size())
        fail("Invalid backup payload.");
    auto sourceBytes = utf8FromWide(payload.sourceEdition);
    if (sourceBytes.empty() || sourceBytes.size() > maximumStringBytes)
        fail("Invalid backup source edition.");
    for (const auto& url : payload.urls) {
        if (!canonicalizeURL(url, validator))
            fail("Backup contains an unsafe URL.");
    }
}

std::vector<uint8_t> encodePayload(const Payload& payload, URLValidator validator)
{
    validatePayload(payload, validator);
    Writer output;
    output.writeUInt32(payloadVersion);
    output.writeUInt64(payload.createdAtEpochMilliseconds);
    output.writeString(payload.sourceEdition);
    output.writeUInt32(payload.selectedIndex);
    output.writeByte(payload.desktopSite ? 1 : 0);
    output.writeUInt32(static_cast<uint32_t>(payload.urls.size()));
    for (const auto& url : payload.urls)
        output.writeString(*canonicalizeURL(url, validator));
    return output.take();
}

Payload decodePayload(const std::vector<uint8_t>& plaintext, URLValidator validator)
{
    Reader input(plaintext);
    if (input.readUInt32() != payloadVersion)
        fail("Unsupported backup payload.");
    Payload payload;
    payload.createdAtEpochMilliseconds = input.readUInt64();
    payload.sourceEdition = input.readString();
    payload.selectedIndex = input.readUInt32();
    uint8_t flags = input.readByte();
    uint32_t count = input.readUInt32();
    if (flags & 0xfe || !count || count > maximumURLs)
        fail("Invalid backup payload.");
    payload.desktopSite = flags & 1;
    payload.urls.reserve(count);
    for (uint32_t index = 0; index < count; ++index) {
        auto url = canonicalizeURL(input.readString(), validator);
        if (!url)
            fail("Backup contains an unsafe URL.");
        payload.urls.push_back(std::move(*url));
    }
    if (input.remaining())
        fail("Backup contains trailing data.");
    validatePayload(payload, validator);
    return payload;
}

SecureVector<uint8_t> deriveKey(std::wstring_view passphrase, const uint8_t* salt, size_t saltSize, uint32_t iterations)
{
    validatePassphrase(passphrase);
    auto password = secureUTF8FromWide(passphrase);

    AlgorithmHandle algorithm;
    requireSuccess(BCryptOpenAlgorithmProvider(algorithm.address(), BCRYPT_SHA256_ALGORITHM, nullptr, BCRYPT_ALG_HANDLE_HMAC_FLAG), "Could not initialize backup key derivation.");
    SecureVector<uint8_t> key(keyBytes);
    requireSuccess(BCryptDeriveKeyPBKDF2(algorithm, reinterpret_cast<PUCHAR>(password.data()), checkedULONG(password.size()), const_cast<PUCHAR>(salt), checkedULONG(saltSize), iterations, key.data(), checkedULONG(key.size()), 0), "Could not derive the backup key.");
    return key;
}

SecureVector<uint8_t> cryptGCM(bool encrypting, const std::vector<uint8_t>& input, const SecureVector<uint8_t>& keyBytesValue, const uint8_t* nonce, size_t nonceSize, uint8_t* tag, size_t tagSize)
{
    AlgorithmHandle algorithm;
    requireSuccess(BCryptOpenAlgorithmProvider(algorithm.address(), BCRYPT_AES_ALGORITHM, nullptr, 0), "Could not initialize backup encryption.");
    requireSuccess(BCryptSetProperty(algorithm, BCRYPT_CHAINING_MODE, reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(BCRYPT_CHAIN_MODE_GCM)), sizeof(BCRYPT_CHAIN_MODE_GCM), 0), "Could not select authenticated backup encryption.");

    DWORD keyObjectSize = 0;
    DWORD resultSize = 0;
    requireSuccess(BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&keyObjectSize), sizeof(keyObjectSize), &resultSize, 0), "Could not inspect backup encryption.");
    SecureVector<uint8_t> keyObject(keyObjectSize);
    KeyHandle key;
    requireSuccess(BCryptGenerateSymmetricKey(algorithm, key.address(), keyObject.data(), checkedULONG(keyObject.size()), const_cast<PUCHAR>(keyBytesValue.data()), checkedULONG(keyBytesValue.size()), 0), "Could not initialize the backup key.");

    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO authentication;
    BCRYPT_INIT_AUTH_MODE_INFO(authentication);
    authentication.pbNonce = const_cast<PUCHAR>(nonce);
    authentication.cbNonce = checkedULONG(nonceSize);
    authentication.pbTag = tag;
    authentication.cbTag = checkedULONG(tagSize);

    SecureVector<uint8_t> output(input.size());
    ULONG written = 0;
    auto operation = encrypting ? BCryptEncrypt : BCryptDecrypt;
    NTSTATUS status = operation(key, const_cast<PUCHAR>(input.data()), checkedULONG(input.size()), &authentication, nullptr, 0, output.data(), checkedULONG(output.size()), &written, 0);
    if (!BCRYPT_SUCCESS(status))
        fail(encrypting ? "Could not encrypt the backup." : "Wrong password or damaged backup.");
    if (written != output.size())
        fail("Backup encryption returned an unexpected size.");
    return output;
}

std::vector<uint8_t> encodeWithParameters(const Payload& payload, std::wstring_view passphrase, URLValidator validator, const std::array<uint8_t, saltBytes>& salt, const std::array<uint8_t, nonceBytes>& nonce)
{
    auto plaintextBytes = encodePayload(payload, validator);
    SecureVector<uint8_t> plaintext;
    plaintext.swap(plaintextBytes);
    auto key = deriveKey(passphrase, salt.data(), salt.size(), defaultIterations);
    std::array<uint8_t, tagBytes> tag { };
    auto ciphertext = cryptGCM(true, plaintext, key, nonce.data(), nonce.size(), tag.data(), tag.size());

    Writer output;
    output.writeBytes(magic.data(), magic.size());
    output.writeUInt32(formatVersion);
    output.writeUInt32(defaultIterations);
    output.writeBytes(salt.data(), salt.size());
    output.writeBytes(nonce.data(), nonce.size());
    if (ciphertext.size() > std::numeric_limits<uint32_t>::max() - tag.size())
        fail("Backup is too large.");
    output.writeUInt32(static_cast<uint32_t>(ciphertext.size() + tag.size()));
    output.writeBytes(ciphertext.data(), ciphertext.size());
    output.writeBytes(tag.data(), tag.size());
    auto result = output.take();
    if (result.size() > maximumEncodedBytes)
        fail("Backup is too large.");
    return result;
}

} // namespace

std::optional<std::wstring> canonicalizeURL(std::wstring_view value, URLValidator asciiURLValidator)
{
    if (!asciiURLValidator || value.empty() || value.size() > maximumStringBytes)
        return std::nullopt;
    auto separator = value.find(L"://");
    if (separator == std::wstring_view::npos)
        return std::nullopt;
    auto authorityStart = separator + 3;
    auto authorityEnd = value.find_first_of(L"/?#", authorityStart);
    auto authority = value.substr(authorityStart, authorityEnd == std::wstring_view::npos ? value.size() - authorityStart : authorityEnd - authorityStart);
    if (authority.empty() || authority.find(L'@') != std::wstring_view::npos)
        return std::nullopt;

    std::wstring canonicalAuthority;
    if (authority.front() == L'[') {
        canonicalAuthority.assign(authority);
    } else {
        auto colon = authority.rfind(L':');
        auto host = colon == std::wstring_view::npos ? authority : authority.substr(0, colon);
        auto port = colon == std::wstring_view::npos ? std::wstring_view { } : authority.substr(colon);
        if (host.empty() || host.size() > static_cast<size_t>(std::numeric_limits<int>::max()))
            return std::nullopt;
        int required = IdnToAscii(IDN_USE_STD3_ASCII_RULES, host.data(), static_cast<int>(host.size()), nullptr, 0);
        if (required <= 0)
            return std::nullopt;
        canonicalAuthority.resize(static_cast<size_t>(required));
        if (IdnToAscii(IDN_USE_STD3_ASCII_RULES, host.data(), static_cast<int>(host.size()), canonicalAuthority.data(), required) != required)
            return std::nullopt;
        canonicalAuthority.append(port);
    }

    std::wstring canonical(value.substr(0, authorityStart));
    canonical.append(canonicalAuthority);
    if (authorityEnd != std::wstring_view::npos)
        canonical.append(value.substr(authorityEnd));
    auto encoded = utf8FromWide(canonical);
    if (encoded.empty() || encoded.size() > maximumStringBytes || !asciiURLValidator(canonical))
        return std::nullopt;
    return canonical;
}

std::vector<uint8_t> encode(const Payload& payload, std::wstring_view passphrase, URLValidator validator)
{
    std::array<uint8_t, saltBytes> salt { };
    std::array<uint8_t, nonceBytes> nonce { };
    requireSuccess(BCryptGenRandom(nullptr, salt.data(), checkedULONG(salt.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG), "Could not generate backup salt.");
    requireSuccess(BCryptGenRandom(nullptr, nonce.data(), checkedULONG(nonce.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG), "Could not generate backup nonce.");
    return encodeWithParameters(payload, passphrase, validator, salt, nonce);
}

Payload decode(const std::vector<uint8_t>& encoded, std::wstring_view passphrase, URLValidator validator)
{
    validatePassphrase(passphrase);
    if (encoded.size() < minimumEncodedBytes || encoded.size() > maximumEncodedBytes)
        fail("Invalid backup size.");
    Reader input(encoded);
    if (input.readBytes(magic.size()) != std::vector<uint8_t>(magic.begin(), magic.end()))
        fail("Not a Xanh Browser backup.");
    if (input.readUInt32() != formatVersion)
        fail("Unsupported backup version.");
    uint32_t iterations = input.readUInt32();
    if (iterations < minimumIterations || iterations > maximumIterations)
        fail("Invalid backup key settings.");
    auto salt = input.readBytes(saltBytes);
    auto nonce = input.readBytes(nonceBytes);
    uint32_t encryptedSize = input.readUInt32();
    if (encryptedSize < tagBytes || encryptedSize != input.remaining())
        fail("Invalid backup payload size.");
    auto encrypted = input.readBytes(encryptedSize);
    std::vector<uint8_t> ciphertext(encrypted.begin(), encrypted.end() - tagBytes);
    std::array<uint8_t, tagBytes> tag { };
    std::copy(encrypted.end() - tagBytes, encrypted.end(), tag.begin());
    auto key = deriveKey(passphrase, salt.data(), salt.size(), iterations);
    auto plaintext = cryptGCM(false, ciphertext, key, nonce.data(), nonce.size(), tag.data(), tag.size());
    return decodePayload(plaintext, validator);
}

#if defined(XANH_PORTABLE_BACKUP_TESTING)
std::vector<uint8_t> encodeWithParametersForTesting(const Payload& payload, std::wstring_view passphrase, URLValidator validator, const std::array<uint8_t, 16>& salt, const std::array<uint8_t, 12>& nonce)
{
    return encodeWithParameters(payload, passphrase, validator, salt, nonce);
}
#endif

} // namespace XanhPortableBackup
