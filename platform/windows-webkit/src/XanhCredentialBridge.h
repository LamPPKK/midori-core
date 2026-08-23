/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include "XanhCredentialBridgePolicy.h"

#include <WebKit/WKRetainPtr.h>
#include <WebKit/WebKit2_C.h>
#include <functional>
#include <memory>
#include <optional>

class XanhCredentialBridge {
public:
    struct Credential {
        std::wstring username;
        std::wstring password;
    };
    using PickerCompletion = std::function<void(std::optional<Credential>)>;
    using Picker = std::function<void(XanhCredentialBridgePolicy::Request, PickerCompletion)>;
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
    struct Lifetime;
    struct PendingRequest;

    static void didReceiveScriptMessage(WKScriptMessageRef, WKCompletionListenerRef, const void*);
    void handleScriptMessage(WKScriptMessageRef, WKCompletionListenerRef);
    void finishPendingRequest(const std::shared_ptr<PendingRequest>&, std::optional<Credential>);
    void cancelPendingRequest();

    WKRetainPtr<WKDictionaryRef> unavailableReply(std::wstring_view requestID) const;
    WKRetainPtr<WKDictionaryRef> credentialReply(std::wstring_view requestID, const Credential&) const;

    WKRetainPtr<WKUserContentControllerRef> m_controller;
    WKPageRef m_page { nullptr };
    XanhCredentialBridgePolicy::State m_state;
    XanhCredentialBridgePolicy::AsyncRequestGate m_asyncGate;
    Picker m_picker;
    ForegroundCheck m_foregroundCheck;
    std::shared_ptr<Lifetime> m_lifetime;
    std::shared_ptr<PendingRequest> m_pendingRequest;
    bool m_enabled { false };
};
