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

#pragma once

#include "XanhNavigationPolicy.h"

#include <climits>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>

namespace XanhCredentialBridgePolicy {

inline constexpr size_t maximumTabIDBytes = 256;
inline constexpr size_t challengeHexCharacters = 32;
inline constexpr size_t requestIDHexCharacters = 32;
inline constexpr size_t maximumFieldUTF8Bytes = 256;
inline constexpr size_t maximumUsernameUTF8Bytes = 1024;
inline constexpr size_t maximumPasswordUTF8Bytes = 4096;
inline constexpr size_t maximumRequestsPerDocument = 64;

struct Request {
    std::wstring type;
    std::wstring tabID;
    std::wstring challenge;
    std::wstring requestID;
    std::wstring documentURL;
    std::wstring claimedOrigin;
    std::wstring usernameField;
    std::wstring passwordField;
};

struct Token {
    uint64_t generation { };
    std::wstring challenge;
    std::wstring requestID;
    std::wstring documentURL;
};

inline bool isASCIIHex(std::wstring_view value, size_t requiredCharacters)
{
    if (value.size() != requiredCharacters)
        return false;
    for (auto character : value) {
        character = XanhNavigationPolicy::toASCIILower(character);
        if (!((character >= L'0' && character <= L'9') || (character >= L'a' && character <= L'f')))
            return false;
    }
    return true;
}

inline bool isSafeTabID(std::wstring_view value)
{
    if (value.empty() || value.size() > maximumTabIDBytes)
        return false;
    for (auto character : value) {
        if (!XanhNavigationPolicy::isASCIIAlphaNumeric(character) && character != L'-' && character != L'_')
            return false;
    }
    return true;
}

inline std::optional<size_t> utf8Length(std::wstring_view value)
{
    size_t length = 0;
    for (size_t index = 0; index < value.size(); ++index) {
        uint32_t scalar = static_cast<uint32_t>(value[index]);
#if WCHAR_MAX <= 0xFFFF
        if (scalar >= 0xD800 && scalar <= 0xDBFF) {
            if (++index >= value.size())
                return std::nullopt;
            auto low = static_cast<uint32_t>(value[index]);
            if (low < 0xDC00 || low > 0xDFFF)
                return std::nullopt;
            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00);
        } else if (scalar >= 0xDC00 && scalar <= 0xDFFF)
            return std::nullopt;
#else
        if (scalar >= 0xD800 && scalar <= 0xDFFF)
            return std::nullopt;
#endif
        if (scalar > 0x10FFFF)
            return std::nullopt;
        if (scalar <= 0x7F)
            ++length;
        else if (scalar <= 0x7FF)
            length += 2;
        else if (scalar <= 0xFFFF)
            length += 3;
        else
            length += 4;
    }
    return length;
}

inline bool containsControl(std::wstring_view value)
{
    for (auto character : value) {
        auto scalar = static_cast<uint32_t>(character);
        if (scalar <= 0x1F || scalar == 0x7F || (scalar >= 0x80 && scalar <= 0x9F))
            return true;
    }
    return false;
}

inline bool isBoundedText(std::wstring_view value, size_t maximumUTF8Bytes)
{
    if (containsControl(value))
        return false;
    auto length = utf8Length(value);
    return length && *length <= maximumUTF8Bytes;
}

inline std::optional<std::wstring> canonicalHTTPSOrigin(std::wstring_view value)
{
    if (!XanhNavigationPolicy::isAllowedWebURL(value))
        return std::nullopt;
    auto separator = value.find(L"://");
    if (separator == std::wstring_view::npos
        || !XanhNavigationPolicy::equalASCIIFolded(value.substr(0, separator), L"https"))
        return std::nullopt;

    auto authorityStart = separator + 3;
    auto authorityEnd = value.find_first_of(L"/?#", authorityStart);
    auto authority = value.substr(authorityStart,
        authorityEnd == std::wstring_view::npos ? value.size() - authorityStart : authorityEnd - authorityStart);
    if (authority.empty())
        return std::nullopt;

    std::wstring normalizedAuthority(authority);
    for (auto& character : normalizedAuthority)
        character = XanhNavigationPolicy::toASCIILower(character);

    if (normalizedAuthority.front() == L'[') {
        auto bracket = normalizedAuthority.find(L']');
        if (bracket != std::wstring::npos && normalizedAuthority.substr(bracket + 1) == L":443")
            normalizedAuthority.erase(bracket + 1);
    } else {
        auto colon = normalizedAuthority.rfind(L':');
        if (colon != std::wstring::npos && normalizedAuthority.substr(colon) == L":443")
            normalizedAuthority.erase(colon);
    }
    return L"https://" + normalizedAuthority;
}

class State {
public:
    State(std::wstring tabID, bool isPrivate)
        : m_tabID(std::move(tabID))
        , m_isPrivate(isPrivate)
    {
    }

    const std::wstring& tabID() const { return m_tabID; }
    bool isEnabled() const { return !m_isPrivate && isSafeTabID(m_tabID); }
    uint64_t generation() const { return m_generation; }

    void navigationStarted()
    {
        ++m_generation;
        m_committed = false;
        m_documentURL.clear();
        m_boundChallenge.clear();
        m_seenRequestIDs.clear();
    }

    bool navigationFinished(std::wstring documentURL)
    {
        ++m_generation;
        m_boundChallenge.clear();
        m_seenRequestIDs.clear();
        if (!canonicalHTTPSOrigin(documentURL)) {
            m_committed = false;
            m_documentURL.clear();
            return false;
        }
        m_documentURL = std::move(documentURL);
        m_committed = true;
        return true;
    }

    void rendererTerminated()
    {
        ++m_generation;
        m_committed = false;
        m_documentURL.clear();
        m_boundChallenge.clear();
        m_seenRequestIDs.clear();
    }

    std::optional<Token> validate(const Request& request, bool isMainFrame)
    {
        if (!isEnabled() || !m_committed || !isMainFrame
            || request.type != L"credential-request"
            || request.tabID != m_tabID
            || !isASCIIHex(request.challenge, challengeHexCharacters)
            || !isASCIIHex(request.requestID, requestIDHexCharacters)
            || request.documentURL != m_documentURL
            || request.documentURL.size() > XanhNavigationPolicy::maximumURLCharacters
            || request.claimedOrigin.size() > XanhNavigationPolicy::maximumURLCharacters
            || !isBoundedText(request.usernameField, maximumFieldUTF8Bytes)
            || !isBoundedText(request.passwordField, maximumFieldUTF8Bytes))
            return std::nullopt;

        auto expectedOrigin = canonicalHTTPSOrigin(m_documentURL);
        auto claimedOrigin = canonicalHTTPSOrigin(request.claimedOrigin);
        if (!expectedOrigin || !claimedOrigin || *expectedOrigin != *claimedOrigin
            || request.claimedOrigin != *claimedOrigin)
            return std::nullopt;

        if (m_boundChallenge.empty())
            m_boundChallenge = request.challenge;
        else if (m_boundChallenge != request.challenge)
            return std::nullopt;
        if (m_seenRequestIDs.size() >= maximumRequestsPerDocument
            || !m_seenRequestIDs.insert(request.requestID).second)
            return std::nullopt;

        return Token { m_generation, request.challenge, request.requestID, request.documentURL };
    }

    bool isCurrent(const Token& token) const
    {
        return m_committed
            && token.generation == m_generation
            && token.challenge == m_boundChallenge
            && token.documentURL == m_documentURL
            && isASCIIHex(token.requestID, requestIDHexCharacters)
            && m_seenRequestIDs.find(token.requestID) != m_seenRequestIDs.end();
    }

private:
    std::wstring m_tabID;
    bool m_isPrivate { true };
    bool m_committed { false };
    uint64_t m_generation { 0 };
    std::wstring m_documentURL;
    std::wstring m_boundChallenge;
    std::unordered_set<std::wstring> m_seenRequestIDs;
};

} // namespace XanhCredentialBridgePolicy
