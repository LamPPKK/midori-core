/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include "XanhCredentialPickerTypes.h"
#include "XanhNativeSyncRuntime.h"
#include "XanhSyncResult.h"

#include <functional>
#include <memory>
#include <windows.h>

class XanhNativeCredentialPicker final
    : public std::enable_shared_from_this<XanhNativeCredentialPicker> {
public:
    using SyncStatus = XanhSyncResultParser::Status;
    using OAuthCompletion = std::function<void(bool)>;
    using SyncCompletion =
        std::function<void(std::optional<SyncStatus>)>;

    static std::shared_ptr<XanhNativeCredentialPicker> shared();
    ~XanhNativeCredentialPicker();

    XanhNativeCredentialPicker(const XanhNativeCredentialPicker&) = delete;
    XanhNativeCredentialPicker& operator=(const XanhNativeCredentialPicker&) = delete;

    void pick(
        HWND ownerWindow,
        XanhCredentialBridgePolicy::Request,
        XanhCredentialPickerCompletion);
    void cancel(HWND ownerWindow);
    void windowClosed(HWND ownerWindow);
    void applicationActivationChanged(
        HWND ownerWindow, bool isActive, HWND otherWindow);
    bool canBeginOAuth(HWND ownerWindow);
    std::optional<XanhSensitiveWide> beginOAuth(HWND ownerWindow);
    bool abandonOAuth(HWND ownerWindow);
    bool canHandleOAuthCallback(HWND ownerWindow);
    bool completeOAuth(
        HWND ownerWindow, std::wstring_view callbackURL, OAuthCompletion);
    void syncNow(HWND ownerWindow, SyncCompletion);
    bool disconnect(bool deleteLocal);
    std::optional<XanhNativeSyncRuntime::AccountState> accountState();

private:
    XanhNativeCredentialPicker();

    struct Impl;
    std::unique_ptr<Impl> m_impl;
};
