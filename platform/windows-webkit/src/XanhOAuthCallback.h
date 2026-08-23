/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include "XanhNativeSyncRuntime.h"

#include <optional>
#include <string_view>

struct XanhOAuthCallback {
    XanhSensitiveUTF8 code;
    XanhSensitiveUTF8 state;
};

namespace XanhOAuthCallbackParser {

inline constexpr std::size_t maximumCallbackCharacters = 32 * 1024;

std::optional<XanhOAuthCallback> parse(std::wstring_view);

} // namespace XanhOAuthCallbackParser
