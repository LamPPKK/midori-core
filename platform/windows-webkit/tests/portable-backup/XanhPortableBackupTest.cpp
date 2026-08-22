#include "../../src/XanhPortableBackup.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincrypt.h>

#include <algorithm>
#include <array>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace {

constexpr std::string_view asciiGolden = "WEFOSEJLMQAAAAABAAM0UAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhsAAABrGe+1+LCSaxIIZoTehQCW/YIh3t1cWKdtm2ZRhz5KDI1ss8rhvNIL709BNuA0TcxI/6UIxeKecxM6+ofiMw3m0Ij51SZIl9KKSASqMcyXCRVDgSnVBCrcAKURj7URBqlSOW181AoYQXA+Aiw=";
constexpr std::string_view unicodeGolden = "WEFOSEJLMQAAAAABAAM0UAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhsAAABrfjICD8Mjv9vFJ0zWrTRPQSUTvi8TnvUo1avIYeQ5ehuR/ZrSJ6l/mE8DpJJ/RyRFfKbZF6I+GbB2zRIFF8M//fuYuJSK/3/0K0dBM0CnXITV+mXV4Z6zOoIAxLCvs/QXPJTSiUKgBg/XtVE=";

int assertions;

void expect(bool condition, const char* message)
{
    ++assertions;
    if (!condition)
        throw std::runtime_error(message);
}

template<typename Callback> void expectFailure(Callback&& callback, const char* message)
{
    ++assertions;
    try {
        callback();
    } catch (const std::exception&) {
        return;
    }
    throw std::runtime_error(message);
}

bool isAllowedTestURL(std::wstring_view value)
{
    auto authorityStart = value.rfind(L"https://", 0) == 0 ? 8 : value.rfind(L"http://", 0) == 0 ? 7 : 0;
    if (!authorityStart || value.size() > XanhPortableBackup::maximumStringBytes)
        return false;
    auto authorityEnd = value.find_first_of(L"/?#", authorityStart);
    auto authority = value.substr(authorityStart, authorityEnd == std::wstring_view::npos ? value.size() - authorityStart : authorityEnd - authorityStart);
    return !authority.empty() && authority.find(L'@') == std::wstring_view::npos && authority.find_first_of(L" \r\n\t\\") == std::wstring_view::npos;
}

std::vector<uint8_t> decodeBase64(std::string_view encoded)
{
    DWORD size = 0;
    if (!CryptStringToBinaryA(encoded.data(), static_cast<DWORD>(encoded.size()), CRYPT_STRING_BASE64, nullptr, &size, nullptr, nullptr))
        throw std::runtime_error("Could not size the golden vector.");
    std::vector<uint8_t> result(size);
    if (!CryptStringToBinaryA(encoded.data(), static_cast<DWORD>(encoded.size()), CRYPT_STRING_BASE64, result.data(), &size, nullptr, nullptr))
        throw std::runtime_error("Could not decode the golden vector.");
    result.resize(size);
    return result;
}

XanhPortableBackup::Payload payload()
{
    return {
        1700000000000,
        L"android-lite-webkit",
        { L"https://example.com/", L"https://webkit.org/" },
        1,
        true,
    };
}

std::array<uint8_t, 16> fixedSalt()
{
    std::array<uint8_t, 16> result { };
    for (uint8_t index = 0; index < result.size(); ++index)
        result[index] = index;
    return result;
}

std::array<uint8_t, 12> fixedNonce()
{
    std::array<uint8_t, 12> result { };
    for (uint8_t index = 0; index < result.size(); ++index)
        result[index] = index + 16;
    return result;
}

void testGoldenVectors()
{
    auto expected = decodeBase64(asciiGolden);
    auto encoded = XanhPortableBackup::encodeWithParametersForTesting(payload(), L"correct horse battery staple", isAllowedTestURL, fixedSalt(), fixedNonce());
    expect(encoded == expected, "ASCII password output drifted from the Android/C# golden vector.");
    expect(XanhPortableBackup::decode(expected, L"correct horse battery staple", isAllowedTestURL) == payload(), "ASCII golden vector did not decode.");

    auto unicodeExpected = decodeBase64(unicodeGolden);
    auto unicodeEncoded = XanhPortableBackup::encodeWithParametersForTesting(payload(), L"m\u1eadt-kh\u1ea9u-Xanh-\U0001f512", isAllowedTestURL, fixedSalt(), fixedNonce());
    expect(unicodeEncoded == unicodeExpected, "Unicode password output drifted from the Android/C# golden vector.");
    expect(XanhPortableBackup::decode(unicodeExpected, L"m\u1eadt-kh\u1ea9u-Xanh-\U0001f512", isAllowedTestURL) == payload(), "Unicode golden vector did not decode.");
}

void testRoundTripAndAuthentication()
{
    auto original = payload();
    original.sourceEdition = L"windows-wincairo";
    original.desktopSite = false;
    auto encoded = XanhPortableBackup::encode(original, L"correct password", isAllowedTestURL);
    expect(encoded.size() <= XanhPortableBackup::maximumEncodedBytes, "Random backup exceeded the size cap.");
    expect(XanhPortableBackup::decode(encoded, L"correct password", isAllowedTestURL) == original, "Random backup did not round-trip.");
    expectFailure([&] { XanhPortableBackup::decode(encoded, L"wrong password", isAllowedTestURL); }, "Wrong password was accepted.");
    encoded.back() ^= 1;
    expectFailure([&] { XanhPortableBackup::decode(encoded, L"correct password", isAllowedTestURL); }, "Tampered backup was accepted.");
}

void testBoundsAndURLs()
{
    auto unsafe = payload();
    unsafe.urls = { L"https://user:secret@example.com/" };
    unsafe.selectedIndex = 0;
    expectFailure([&] { XanhPortableBackup::encode(unsafe, L"correct password", isAllowedTestURL); }, "Credential URL was exported.");
    unsafe.urls = { L"file:///C:/private.txt" };
    expectFailure([&] { XanhPortableBackup::encode(unsafe, L"correct password", isAllowedTestURL); }, "File URL was exported.");

    auto tooMany = payload();
    tooMany.urls.assign(XanhPortableBackup::maximumURLs + 1, L"https://example.com/");
    expectFailure([&] { XanhPortableBackup::encode(tooMany, L"correct password", isAllowedTestURL); }, "More than 50 URLs were exported.");
    auto oversizedURL = payload();
    oversizedURL.urls = { L"https://example.com/" + std::wstring(XanhPortableBackup::maximumStringBytes, L'a') };
    oversizedURL.selectedIndex = 0;
    expectFailure([&] { XanhPortableBackup::encode(oversizedURL, L"correct password", isAllowedTestURL); }, "An oversized URL was processed.");
    auto invalidTimestamp = payload();
    invalidTimestamp.createdAtEpochMilliseconds = std::numeric_limits<uint64_t>::max();
    expectFailure([&] { XanhPortableBackup::encode(invalidTimestamp, L"correct password", isAllowedTestURL); }, "A timestamp outside the cross-platform Int64 range was accepted.");
    auto whitespaceSource = payload();
    whitespaceSource.sourceEdition = L" \t\r\n\u2003";
    expectFailure([&] { XanhPortableBackup::encode(whitespaceSource, L"correct password", isAllowedTestURL); }, "A whitespace-only source edition was accepted.");
    expectFailure([&] { XanhPortableBackup::encode(payload(), L"short", isAllowedTestURL); }, "Short password was accepted.");
    expectFailure([&] { XanhPortableBackup::decode(std::vector<uint8_t>(63), L"correct password", isAllowedTestURL); }, "An undersized envelope was accepted.");
    expectFailure([&] { XanhPortableBackup::decode(std::vector<uint8_t>(XanhPortableBackup::maximumEncodedBytes + 1), L"correct password", isAllowedTestURL); }, "Oversized input was accepted.");
}

void testIDNCanonicalization()
{
    auto canonical = XanhPortableBackup::canonicalizeURL(L"https://b\u00fccher.example/catalogue", isAllowedTestURL);
    expect(canonical && *canonical == L"https://xn--bcher-kva.example/catalogue", "An IDN host did not canonicalize to its ASCII form.");
    expect(!XanhPortableBackup::canonicalizeURL(L"https://user:secret@b\u00fccher.example/", isAllowedTestURL), "A credential-bearing IDN URL was accepted.");

    auto idnPayload = payload();
    idnPayload.urls = { L"https://b\u00fccher.example/" };
    idnPayload.selectedIndex = 0;
    auto encoded = XanhPortableBackup::encodeWithParametersForTesting(idnPayload, L"correct password", isAllowedTestURL, fixedSalt(), fixedNonce());
    auto decoded = XanhPortableBackup::decode(encoded, L"correct password", isAllowedTestURL);
    expect(decoded.urls == std::vector<std::wstring> { L"https://xn--bcher-kva.example/" }, "An IDN backup did not round-trip through the canonical ASCII host.");
}

} // namespace

int main()
{
    try {
        testGoldenVectors();
        testRoundTripAndAuthentication();
        testBoundsAndURLs();
        testIDNCanonicalization();
        std::cout << assertions << " Xanh portable-backup assertions passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
