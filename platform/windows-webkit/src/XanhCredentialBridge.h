/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include "XanhCredentialPickerTypes.h"

#include <WebKit/WKRetainPtr.h>
#include <WebKit/WebKit2_C.h>
#include <functional>
#include <memory>
#include <optional>

class XanhCredentialBridge {
public:
    using Credential = XanhCredential;
    using PickerCompletion = XanhCredentialPickerCompletion;
    using Picker = XanhCredentialPicker;
    using ForegroundCheck = std::function<bool()>;
    using PickerCancellation = std::function<void()>;

    XanhCredentialBridge(
        WKPageConfigurationRef, bool isPrivate, Picker = { },
        ForegroundCheck = { }, PickerCancellation = { });
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
    PickerCancellation m_pickerCancellation;
    std::shared_ptr<Lifetime> m_lifetime;
    std::shared_ptr<PendingRequest> m_pendingRequest;
    bool m_enabled { false };
};
