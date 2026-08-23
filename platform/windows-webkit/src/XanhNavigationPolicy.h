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

#include <cstddef>
#include <string_view>

namespace XanhNavigationPolicy {

inline constexpr size_t maximumURLCharacters = 8192;
inline constexpr size_t maximumExternalURLCharacters = 2048;

enum class Decision {
    allowInWebView,
    openExternal,
    block,
};

inline wchar_t toASCIILower(wchar_t character)
{
    if (character >= L'A' && character <= L'Z')
        return character + (L'a' - L'A');
    return character;
}

inline bool equalASCIIFolded(std::wstring_view left, std::wstring_view right)
{
    if (left.size() != right.size())
        return false;
    for (size_t index = 0; index < left.size(); ++index) {
        if (toASCIILower(left[index]) != toASCIILower(right[index]))
            return false;
    }
    return true;
}

inline bool isASCIIAlphaNumeric(wchar_t character)
{
    character = toASCIILower(character);
    return (character >= L'a' && character <= L'z') || (character >= L'0' && character <= L'9');
}

inline bool hasForbiddenCharacters(std::wstring_view url)
{
    for (auto character : url) {
        if (character <= 0x20 || character == 0x7f || (character >= 0x80 && character <= 0x9f) || character == L'\\')
            return true;
    }
    return false;
}

inline bool hasValidPort(std::wstring_view port)
{
    if (port.empty() || port.size() > 5)
        return false;

    unsigned value = 0;
    for (auto character : port) {
        if (character < L'0' || character > L'9')
            return false;
        value = value * 10 + static_cast<unsigned>(character - L'0');
    }
    return value <= 65535;
}

inline bool isValidIPv4Host(std::wstring_view host)
{
    unsigned octets = 0;
    size_t start = 0;
    while (start < host.size()) {
        auto end = host.find(L'.', start);
        auto octet = host.substr(start, end == std::wstring_view::npos ? host.size() - start : end - start);
        if (octet.empty() || octet.size() > 3)
            return false;
        unsigned value = 0;
        for (auto character : octet) {
            if (character < L'0' || character > L'9')
                return false;
            value = value * 10 + static_cast<unsigned>(character - L'0');
        }
        if (value > 255)
            return false;
        ++octets;
        if (end == std::wstring_view::npos)
            break;
        start = end + 1;
    }
    return octets == 4;
}

inline bool isValidDomainHost(std::wstring_view host)
{
    if (host.empty() || host.size() > 253 || host.front() == L'.')
        return false;
    bool onlyDigitsAndDots = true;
    for (auto character : host) {
        if (!isASCIIAlphaNumeric(character) && character != L'.' && character != L'-' && character != L'_')
            return false;
        if ((character < L'0' || character > L'9') && character != L'.')
            onlyDigitsAndDots = false;
    }
    if (host.find(L"..") != std::wstring_view::npos)
        return false;
    if (onlyDigitsAndDots)
        return isValidIPv4Host(host);

    size_t start = 0;
    while (start < host.size()) {
        auto end = host.find(L'.', start);
        auto label = host.substr(start, end == std::wstring_view::npos ? host.size() - start : end - start);
        if (label.empty())
            return end == host.size() - 1;
        if (label.size() > 63 || label.front() == L'-' || label.back() == L'-')
            return false;
        if (end == std::wstring_view::npos)
            break;
        start = end + 1;
    }
    return true;
}

inline bool isValidIPv6Group(std::wstring_view group, bool allowIPv4, unsigned& groupCount)
{
    if (group.empty())
        return false;
    if (allowIPv4 && group.find(L'.') != std::wstring_view::npos) {
        if (!isValidIPv4Host(group))
            return false;
        groupCount += 2;
        return true;
    }
    if (group.size() > 4)
        return false;
    for (auto character : group) {
        character = toASCIILower(character);
        if (!((character >= L'0' && character <= L'9') || (character >= L'a' && character <= L'f')))
            return false;
    }
    ++groupCount;
    return true;
}

inline bool countIPv6Groups(std::wstring_view side, bool allowIPv4, unsigned& groupCount)
{
    if (side.empty())
        return true;
    if (side.front() == L':' || side.back() == L':')
        return false;
    size_t start = 0;
    while (start < side.size()) {
        auto end = side.find(L':', start);
        auto group = side.substr(start, end == std::wstring_view::npos ? side.size() - start : end - start);
        bool isLast = end == std::wstring_view::npos;
        if (!isValidIPv6Group(group, allowIPv4 && isLast, groupCount))
            return false;
        if (isLast)
            break;
        start = end + 1;
    }
    return true;
}

inline bool isValidIPv6Host(std::wstring_view host)
{
    if (host.empty())
        return false;
    auto compression = host.find(L"::");
    if (compression != std::wstring_view::npos && host.find(L"::", compression + 2) != std::wstring_view::npos)
        return false;

    unsigned groupCount = 0;
    if (compression == std::wstring_view::npos)
        return countIPv6Groups(host, true, groupCount) && groupCount == 8;

    auto left = host.substr(0, compression);
    auto right = host.substr(compression + 2);
    if (!countIPv6Groups(left, false, groupCount) || !countIPv6Groups(right, true, groupCount))
        return false;
    return groupCount < 8;
}

inline bool isAllowedWebURL(std::wstring_view url)
{
    if (url.empty() || url.size() > maximumURLCharacters || hasForbiddenCharacters(url))
        return false;

    auto separator = url.find(L"://");
    if (separator == std::wstring_view::npos)
        return false;
    auto scheme = url.substr(0, separator);
    if (!equalASCIIFolded(scheme, L"http") && !equalASCIIFolded(scheme, L"https"))
        return false;

    auto authorityStart = separator + 3;
    auto authorityEnd = url.find_first_of(L"/?#", authorityStart);
    auto authority = url.substr(authorityStart, authorityEnd == std::wstring_view::npos ? url.size() - authorityStart : authorityEnd - authorityStart);
    if (authority.empty() || authority.find(L'@') != std::wstring_view::npos)
        return false;

    if (authority.front() == L'[') {
        auto closingBracket = authority.find(L']');
        if (closingBracket == std::wstring_view::npos || !isValidIPv6Host(authority.substr(1, closingBracket - 1)))
            return false;
        auto suffix = authority.substr(closingBracket + 1);
        return suffix.empty() || (suffix.front() == L':' && hasValidPort(suffix.substr(1)));
    }

    auto colon = authority.find(L':');
    if (colon == std::wstring_view::npos)
        return isValidDomainHost(authority);
    if (authority.find(L':', colon + 1) != std::wstring_view::npos)
        return false;
    return isValidDomainHost(authority.substr(0, colon)) && hasValidPort(authority.substr(colon + 1));
}

inline bool isAllowedInternalURL(std::wstring_view url)
{
    auto fragment = url.find(L'#');
    auto base = url.substr(0, fragment);
    if (url.size() > maximumURLCharacters || hasForbiddenCharacters(url))
        return false;
    return equalASCIIFolded(base, L"about:blank") || equalASCIIFolded(base, L"about:srcdoc");
}

inline bool isAllowedExternalURL(std::wstring_view url)
{
    if (url.empty() || url.size() > maximumExternalURLCharacters || hasForbiddenCharacters(url))
        return false;
    auto separator = url.find(L':');
    if (separator == std::wstring_view::npos || separator + 1 == url.size())
        return false;
    auto scheme = url.substr(0, separator);
    if (!equalASCIIFolded(scheme, L"mailto") && !equalASCIIFolded(scheme, L"tel"))
        return false;

    auto isHexDigit = [](wchar_t character) {
        character = toASCIILower(character);
        return (character >= L'0' && character <= L'9') || (character >= L'a' && character <= L'f');
    };
    auto hexValue = [](wchar_t character) -> unsigned {
        character = toASCIILower(character);
        return character >= L'a' ? static_cast<unsigned>(character - L'a' + 10) : static_cast<unsigned>(character - L'0');
    };
    constexpr std::wstring_view allowedPunctuation = L"-._~!$&'()*+,;=:@/?#[]";
    for (size_t index = separator + 1; index < url.size(); ++index) {
        auto character = url[index];
        if (character == L'%') {
            if (index + 2 >= url.size() || !isHexDigit(url[index + 1]) || !isHexDigit(url[index + 2]))
                return false;
            unsigned decoded = hexValue(url[index + 1]) * 16 + hexValue(url[index + 2]);
            if (decoded <= 0x20 || decoded == 0x7f)
                return false;
            index += 2;
            continue;
        }
        if (!isASCIIAlphaNumeric(character) && allowedPunctuation.find(character) == std::wstring_view::npos)
            return false;
    }
    return true;
}

inline Decision decide(std::wstring_view url, bool hasUnconsumedUserGesture, bool isTrustedLinkClick, bool isRedirect, bool shouldOpenExternalSchemes)
{
    if (isAllowedWebURL(url) || isAllowedInternalURL(url))
        return Decision::allowInWebView;
    if (isAllowedExternalURL(url) && hasUnconsumedUserGesture && isTrustedLinkClick && !isRedirect && shouldOpenExternalSchemes)
        return Decision::openExternal;
    return Decision::block;
}

} // namespace XanhNavigationPolicy
