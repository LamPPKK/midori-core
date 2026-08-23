/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include "XanhCredentialBridgePolicy.h"

#include <functional>
#include <memory>
#include <optional>
#include <string_view>

class XanhSensitiveWide {
public:
    XanhSensitiveWide() = default;
    ~XanhSensitiveWide();

    XanhSensitiveWide(XanhSensitiveWide&&) noexcept;
    XanhSensitiveWide& operator=(XanhSensitiveWide&&) noexcept;
    XanhSensitiveWide(const XanhSensitiveWide&) = delete;
    XanhSensitiveWide& operator=(const XanhSensitiveWide&) = delete;

    std::wstring_view view() const
    {
        return m_data ? std::wstring_view(m_data.get(), m_size) : std::wstring_view();
    }
    bool empty() const { return !m_size; }
    static std::optional<XanhSensitiveWide> fromUTF8(std::string_view);
    static std::optional<XanhSensitiveWide> forNativeLabel(std::wstring_view);

private:
    void clear();

    std::unique_ptr<wchar_t[]> m_data;
    std::size_t m_size { 0 };
};

struct XanhCredential {
    XanhSensitiveWide username;
    XanhSensitiveWide password;
};

using XanhCredentialPickerCompletion =
    std::function<void(std::optional<XanhCredential>)>;
using XanhCredentialPicker = std::function<void(
    XanhCredentialBridgePolicy::Request,
    XanhCredentialPickerCompletion)>;
