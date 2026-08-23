/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <cstdint>
#include <limits>
#include <optional>
#include <string_view>

namespace XanhSyncResultParser {

enum class Status {
    success,
    partial,
    networkError,
    authError,
    backedOff,
};

inline std::optional<Status> parseStatus(std::string_view value)
{
    if (value == "success")
        return Status::success;
    if (value == "partial")
        return Status::partial;
    if (value == "network-error")
        return Status::networkError;
    if (value == "auth-error")
        return Status::authError;
    if (value == "backed-off")
        return Status::backedOff;
    return std::nullopt;
}

inline bool validNextSync(std::string_view value)
{
    if (value == "null")
        return true;
    if (value.empty() || (value.size() > 1 && value.front() == '0'))
        return false;
    std::uint64_t parsed = 0;
    for (char character : value) {
        if (character < '0' || character > '9')
            return false;
        auto digit = static_cast<unsigned>(character - '0');
        if (parsed > (std::numeric_limits<std::uint64_t>::max() - digit) / 10)
            return false;
        parsed = parsed * 10 + digit;
    }
    return true;
}

inline std::optional<Status> parse(std::string_view value)
{
    constexpr std::string_view statusFirstPrefix = "{\"status\":\"";
    constexpr std::string_view statusFirstMiddle =
        "\",\"next_sync_allowed_epoch_seconds\":";
    constexpr std::string_view nextFirstPrefix =
        "{\"next_sync_allowed_epoch_seconds\":";
    constexpr std::string_view nextFirstMiddle = ",\"status\":\"";

    if (value.size() < 2 || value.back() != '}')
        return std::nullopt;
    if (value.substr(0, statusFirstPrefix.size()) == statusFirstPrefix) {
        auto middle = value.find(statusFirstMiddle, statusFirstPrefix.size());
        if (middle == std::string_view::npos)
            return std::nullopt;
        auto status = parseStatus(value.substr(
            statusFirstPrefix.size(), middle - statusFirstPrefix.size()));
        auto next = value.substr(middle + statusFirstMiddle.size());
        next.remove_suffix(1);
        return status && validNextSync(next) ? status : std::nullopt;
    }
    if (value.substr(0, nextFirstPrefix.size()) == nextFirstPrefix) {
        auto middle = value.find(nextFirstMiddle, nextFirstPrefix.size());
        if (middle == std::string_view::npos || value.size() < middle + nextFirstMiddle.size() + 2
            || value[value.size() - 2] != '"')
            return std::nullopt;
        auto next = value.substr(
            nextFirstPrefix.size(), middle - nextFirstPrefix.size());
        auto statusText = value.substr(
            middle + nextFirstMiddle.size(),
            value.size() - (middle + nextFirstMiddle.size()) - 2);
        auto status = parseStatus(statusText);
        return status && validNextSync(next) ? status : std::nullopt;
    }
    return std::nullopt;
}

} // namespace XanhSyncResultParser
