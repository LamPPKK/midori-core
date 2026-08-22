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

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace XanhPortableBackup {

inline constexpr size_t maximumEncodedBytes = 1024 * 1024;
inline constexpr size_t maximumURLs = 50;
inline constexpr size_t maximumStringBytes = 4096;

using URLValidator = bool (*)(std::wstring_view);

std::optional<std::wstring> canonicalizeURL(std::wstring_view, URLValidator asciiURLValidator);

struct Payload {
    uint64_t createdAtEpochMilliseconds { };
    std::wstring sourceEdition;
    std::vector<std::wstring> urls;
    uint32_t selectedIndex { };
    bool desktopSite { false };

    bool operator==(const Payload& other) const
    {
        return createdAtEpochMilliseconds == other.createdAtEpochMilliseconds
            && sourceEdition == other.sourceEdition
            && urls == other.urls
            && selectedIndex == other.selectedIndex
            && desktopSite == other.desktopSite;
    }
};

std::vector<uint8_t> encode(const Payload&, std::wstring_view passphrase, URLValidator);
Payload decode(const std::vector<uint8_t>&, std::wstring_view passphrase, URLValidator);

#if defined(XANH_PORTABLE_BACKUP_TESTING)
std::vector<uint8_t> encodeWithParametersForTesting(const Payload&, std::wstring_view passphrase, URLValidator, const std::array<uint8_t, 16>& salt, const std::array<uint8_t, 12>& nonce);
#endif

} // namespace XanhPortableBackup
