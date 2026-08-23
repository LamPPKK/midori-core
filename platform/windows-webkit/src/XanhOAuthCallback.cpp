/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "XanhOAuthCallback.h"

#include <cstdint>
#include <string>
#include <utility>

namespace {

constexpr std::wstring_view callbackPrefix =
    L"xanh-browser-wincairo://accounts/oauth?";

class SensitiveString {
public:
    ~SensitiveString()
    {
        if (!value.empty()) {
            volatile char* output = value.data();
            for (std::size_t index = 0; index < value.size(); ++index)
                output[index] = 0;
        }
    }

    std::string value;
};

int hexValue(wchar_t value)
{
    if (value >= L'0' && value <= L'9')
        return value - L'0';
    if (value >= L'a' && value <= L'f')
        return value - L'a' + 10;
    if (value >= L'A' && value <= L'F')
        return value - L'A' + 10;
    return -1;
}

bool validUTF8(std::string_view value)
{
    std::size_t offset = 0;
    while (offset < value.size()) {
        auto first = static_cast<unsigned char>(value[offset++]);
        if (first <= 0x7f)
            continue;
        unsigned continuations = 0;
        std::uint32_t scalar = 0;
        std::uint32_t minimum = 0;
        if ((first & 0xe0) == 0xc0) {
            continuations = 1;
            scalar = first & 0x1f;
            minimum = 0x80;
        } else if ((first & 0xf0) == 0xe0) {
            continuations = 2;
            scalar = first & 0x0f;
            minimum = 0x800;
        } else if ((first & 0xf8) == 0xf0) {
            continuations = 3;
            scalar = first & 0x07;
            minimum = 0x10000;
        } else
            return false;
        if (value.size() - offset < continuations)
            return false;
        for (unsigned index = 0; index < continuations; ++index) {
            auto next = static_cast<unsigned char>(value[offset++]);
            if ((next & 0xc0) != 0x80)
                return false;
            scalar = (scalar << 6) | (next & 0x3f);
        }
        if (scalar < minimum || scalar > 0x10ffff
            || (scalar >= 0xd800 && scalar <= 0xdfff))
            return false;
    }
    return true;
}

std::optional<XanhSensitiveUTF8> decode(std::wstring_view value)
{
    if (value.empty()
        || value.size() > XanhNativeSyncRuntime::maximumOAuthComponentBytes)
        return std::nullopt;
    SensitiveString bytes;
    bytes.value.reserve(value.size());
    for (std::size_t index = 0; index < value.size(); ++index) {
        auto character = static_cast<std::uint32_t>(value[index]);
        if (character == L'%') {
            if (value.size() - index < 3)
                return std::nullopt;
            int high = hexValue(value[index + 1]);
            int low = hexValue(value[index + 2]);
            if (high < 0 || low < 0)
                return std::nullopt;
            character = static_cast<std::uint32_t>((high << 4) | low);
            index += 2;
        } else if (character > 0x7f)
            return std::nullopt;
        if (character <= 0x1f || character == 0x7f)
            return std::nullopt;
        bytes.value.push_back(static_cast<char>(character));
        if (bytes.value.size()
            > XanhNativeSyncRuntime::maximumOAuthComponentBytes)
            return std::nullopt;
    }
    if (!validUTF8(bytes.value))
        return std::nullopt;
    return XanhSensitiveUTF8::take(std::move(bytes.value));
}

} // namespace

std::optional<XanhOAuthCallback> XanhOAuthCallbackParser::parse(
    std::wstring_view value)
{
    if (value.size() > maximumCallbackCharacters
        || value.substr(0, callbackPrefix.size()) != callbackPrefix
        || value.find(L'#') != std::wstring_view::npos)
        return std::nullopt;
    auto query = value.substr(callbackPrefix.size());
    std::optional<XanhSensitiveUTF8> code;
    std::optional<XanhSensitiveUTF8> state;
    while (!query.empty()) {
        auto separator = query.find(L'&');
        auto field = query.substr(0, separator);
        query = separator == std::wstring_view::npos
            ? std::wstring_view() : query.substr(separator + 1);
        auto equals = field.find(L'=');
        if (equals == std::wstring_view::npos
            || field.find(L'=', equals + 1) != std::wstring_view::npos)
            return std::nullopt;
        auto name = field.substr(0, equals);
        auto decoded = decode(field.substr(equals + 1));
        if (!decoded)
            return std::nullopt;
        if (name == L"code" && !code)
            code = std::move(decoded);
        else if (name == L"state" && !state)
            state = std::move(decoded);
        else
            return std::nullopt;
        if (separator != std::wstring_view::npos && query.empty())
            return std::nullopt;
    }
    if (!code || !state)
        return std::nullopt;
    return XanhOAuthCallback { std::move(*code), std::move(*state) };
}
