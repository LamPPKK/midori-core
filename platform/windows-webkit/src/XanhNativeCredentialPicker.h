/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include "XanhCredentialPickerTypes.h"

#include <memory>
#include <windows.h>

class XanhNativeCredentialPicker final
    : public std::enable_shared_from_this<XanhNativeCredentialPicker> {
public:
    static std::shared_ptr<XanhNativeCredentialPicker> shared();
    ~XanhNativeCredentialPicker();

    XanhNativeCredentialPicker(const XanhNativeCredentialPicker&) = delete;
    XanhNativeCredentialPicker& operator=(const XanhNativeCredentialPicker&) = delete;

    void pick(
        HWND ownerWindow,
        XanhCredentialBridgePolicy::Request,
        XanhCredentialPickerCompletion);
    void cancel(HWND ownerWindow);
    void applicationActivationChanged(
        HWND ownerWindow, bool isActive, HWND otherWindow);

private:
    XanhNativeCredentialPicker();

    struct Impl;
    std::unique_ptr<Impl> m_impl;
};
