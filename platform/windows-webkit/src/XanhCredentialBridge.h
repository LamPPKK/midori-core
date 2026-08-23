/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include "XanhCredentialBridgePolicy.h"

#include <WebKit/WKRetainPtr.h>
#include <WebKit/WebKit2_C.h>
#include <functional>
#include <optional>

class XanhCredentialBridge {
public:
    struct Credential {
        std::wstring username;
        std::wstring password;
    };
    using Picker = std::function<std::optional<Credential>(const XanhCredentialBridgePolicy::Request&)>;
    using ForegroundCheck = std::function<bool()>;

    XanhCredentialBridge(WKPageConfigurationRef, bool isPrivate, Picker = { }, ForegroundCheck = { });
    ~XanhCredentialBridge();

    XanhCredentialBridge(const XanhCredentialBridge&) = delete;
    XanhCredentialBridge& operator=(const XanhCredentialBridge&) = delete;

    bool enabled() const { return m_enabled; }
    void attachPage(WKPageRef);
    void navigationStarted(WKPageRef);
    void navigationFinished(WKPageRef);
    void activeURLChanged(WKPageRef);
    void rendererTerminated(WKPageRef);

private:
    static void didReceiveScriptMessage(WKScriptMessageRef, WKCompletionListenerRef, const void*);
    void handleScriptMessage(WKScriptMessageRef, WKCompletionListenerRef);

    WKRetainPtr<WKDictionaryRef> unavailableReply(std::wstring_view requestID) const;
    WKRetainPtr<WKDictionaryRef> credentialReply(std::wstring_view requestID, const Credential&) const;

    WKRetainPtr<WKUserContentControllerRef> m_controller;
    WKPageRef m_page { nullptr };
    XanhCredentialBridgePolicy::State m_state;
    Picker m_picker;
    ForegroundCheck m_foregroundCheck;
    bool m_requestInFlight { false };
    bool m_enabled { false };
};
