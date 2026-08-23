/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include "XanhCredentialPickerTypes.h"

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

struct XanhCredentialRecord {
    std::string id;
    XanhSensitiveWide username;
    XanhSensitiveWide password;
};

class XanhCredentialRecords {
public:
    static constexpr std::size_t maximumJSONBytes = 4 * 1024 * 1024;
    static constexpr std::size_t maximumRecords = 100;
    static constexpr std::size_t maximumIDBytes = 128;
    static constexpr std::size_t maximumOriginBytes = 8192;
    static constexpr std::size_t maximumUsernameBytes = 1024;
    static constexpr std::size_t maximumPasswordBytes = 4096;
    static constexpr std::size_t maximumFieldBytes = 256;

    static std::optional<std::vector<XanhCredentialRecord>> parse(
        std::string_view json, std::wstring_view expectedOrigin);
};
