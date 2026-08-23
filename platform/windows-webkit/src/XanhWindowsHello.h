/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <functional>
#include <memory>
#include <string>
#include <windows.h>

class XanhWindowsHello {
public:
    using Completion = std::function<void(bool)>;

    explicit XanhWindowsHello(HWND ownerWindow);
    ~XanhWindowsHello();

    XanhWindowsHello(const XanhWindowsHello&) = delete;
    XanhWindowsHello& operator=(const XanhWindowsHello&) = delete;

    void verify(std::wstring reason, Completion);
    void cancel();

private:
    struct State;
    std::shared_ptr<State> m_state;
};
