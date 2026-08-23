/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "stdafx.h"
#include "XanhCredentialBridge.h"

#include <WebKit/WKDictionary.h>
#include <WebKit/WKFrameInfoRef.h>
#include <WebKit/WKPage.h>
#include <WebKit/WKPageConfigurationRef.h>
#include <WebKit/WKScriptMessageRef.h>
#include <WebKit/WKString.h>
#include <WebKit/WKUserContentControllerRef.h>
#include <WebKit/WKUserScriptRef.h>
#include <bcrypt.h>
#include <array>
#include <sstream>
#include <utility>
#include <vector>

namespace {

constexpr auto handlerName = L"xanhCredentialBridge";
constexpr auto worldName = L"XanhCredentialWorld";

WKRetainPtr<WKStringRef> makeWKString(std::wstring_view value)
{
    if (value.empty())
        return adoptWK(WKStringCreateWithUTF8CString(""));
    auto required = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (required <= 0)
        return nullptr;
    std::string utf8(static_cast<size_t>(required), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), utf8.data(), required, nullptr, nullptr) != required)
        return nullptr;
    return adoptWK(WKStringCreateWithUTF8CStringWithLength(utf8.data(), utf8.size()));
}

std::optional<std::wstring> readWKString(WKTypeRef value, size_t maximumCharacters)
{
    if (!value || WKGetTypeID(value) != WKStringGetTypeID())
        return std::nullopt;
    auto string = static_cast<WKStringRef>(value);
    auto length = WKStringGetLength(string);
    if (length > maximumCharacters)
        return std::nullopt;
    std::wstring result(length, L'\0');
    if (length && WKStringGetCharacters(string, result.data(), length) != length)
        return std::nullopt;
    return result;
}

std::optional<std::wstring> dictionaryString(WKDictionaryRef dictionary, const wchar_t* key, size_t maximumCharacters)
{
    auto wkKey = makeWKString(key);
    if (!wkKey)
        return std::nullopt;
    return readWKString(WKDictionaryGetItemForKey(dictionary, wkKey.get()), maximumCharacters);
}

std::wstring activeURL(WKPageRef page)
{
    auto url = adoptWK(WKPageCopyActiveURL(page));
    if (!url)
        return { };
    auto value = adoptWK(WKURLCopyString(url.get()));
    auto result = readWKString(value.get(), XanhNavigationPolicy::maximumURLCharacters);
    return result.value_or(std::wstring { });
}

std::wstring randomHex()
{
    std::array<unsigned char, 16> bytes { };
    if (BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0)
        return { };
    constexpr wchar_t digits[] = L"0123456789abcdef";
    std::wstring result;
    result.reserve(bytes.size() * 2);
    for (auto byte : bytes) {
        result.push_back(digits[byte >> 4]);
        result.push_back(digits[byte & 0x0F]);
    }
    return result;
}

std::wstring bootstrapSource(std::wstring_view tabID)
{
    std::wstringstream source;
    source << LR"JS((() => {
  'use strict';
  const handler = globalThis.webkit?.messageHandlers?.xanhCredentialBridge;
  if (!handler || !globalThis.crypto?.getRandomValues) return;
  const tabId = ')JS" << tabID << LR"JS(';
  const randomHex = () => {
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, value => value.toString(16).padStart(2, '0')).join('');
  };
  const challenge = randomHex();
  const pending = new WeakSet();
  const fieldName = input => input?.name || input?.id || '';
  const usernameFor = password => {
    const controls = password.form ? Array.from(password.form.elements) : Array.from(document.querySelectorAll('input'));
    let candidate = null;
    for (const control of controls) {
      if (control === password) break;
      if (control instanceof HTMLInputElement && ['text', 'email', 'username'].includes(control.type)) candidate = control;
    }
    return candidate;
  };
  const requestCredential = password => {
    if (!(password instanceof HTMLInputElement) || password.type !== 'password'
        || document.visibilityState !== 'visible' || pending.has(password)) return;
    const username = usernameFor(password);
    const documentUrl = location.href;
    const claimedOrigin = location.origin;
    const requestId = randomHex();
    pending.add(password);
    Promise.resolve(handler.postMessage({
      type: 'credential-request', tabId, challenge, requestId,
      documentUrl, claimedOrigin,
      usernameField: fieldName(username), passwordField: fieldName(password)
    })).then(reply => {
      if (!reply || reply.status !== 'fill' || reply.requestId !== requestId
          || location.href !== documentUrl || document.visibilityState !== 'visible'
          || typeof reply.username !== 'string' || typeof reply.password !== 'string') return;
      if (username) username.value = reply.username;
      password.value = reply.password;
      for (const input of username ? [username, password] : [password]) {
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
      }
    }).catch(() => { }).finally(() => pending.delete(password));
  };
  document.addEventListener('pointerdown', event => {
    if (event.isTrusted && event.isPrimary && event.button === 0) requestCredential(event.target);
  }, true);
  document.addEventListener('keydown', event => {
    if (event.isTrusted && event.key === 'Enter') requestCredential(event.target);
  }, true);
})();)JS";
    return source.str();
}

void secureClear(std::wstring& value)
{
    if (!value.empty())
        SecureZeroMemory(value.data(), value.size() * sizeof(wchar_t));
    value.clear();
}

WKRetainPtr<WKDictionaryRef> makeReply(
    std::initializer_list<std::pair<std::wstring_view, std::wstring_view>> fields)
{
    std::vector<WKRetainPtr<WKStringRef>> ownedKeys;
    std::vector<WKRetainPtr<WKStringRef>> ownedValues;
    std::vector<WKStringRef> keys;
    std::vector<WKTypeRef> values;
    ownedKeys.reserve(fields.size());
    ownedValues.reserve(fields.size());
    keys.reserve(fields.size());
    values.reserve(fields.size());
    for (const auto& [key, value] : fields) {
        auto wkKey = makeWKString(key);
        auto wkValue = makeWKString(value);
        if (!wkKey || !wkValue)
            return nullptr;
        keys.push_back(wkKey.get());
        values.push_back(wkValue.get());
        ownedKeys.push_back(std::move(wkKey));
        ownedValues.push_back(std::move(wkValue));
    }
    return adoptWK(WKDictionaryCreate(keys.data(), values.data(), values.size()));
}

} // namespace

struct XanhCredentialBridge::Lifetime {
    XanhCredentialBridge* owner { nullptr };
};

struct XanhCredentialBridge::PendingRequest {
    uint64_t asyncSequence { };
    std::wstring requestID;
    XanhCredentialBridgePolicy::Token token;
    WKRetainPtr<WKCompletionListenerRef> reply;
};

XanhCredentialBridge::XanhCredentialBridge(WKPageConfigurationRef configuration, bool isPrivate, Picker picker, ForegroundCheck foregroundCheck)
    : m_state(randomHex(), isPrivate)
    , m_picker(std::move(picker))
    , m_foregroundCheck(std::move(foregroundCheck))
    , m_lifetime(std::make_shared<Lifetime>())
{
    m_lifetime->owner = this;
    if (!configuration || !m_state.isEnabled())
        return;
    auto controller = WKPageConfigurationGetUserContentController(configuration);
    if (!controller) {
        auto created = adoptWK(WKUserContentControllerCreate());
        WKPageConfigurationSetUserContentController(configuration, created.get());
        m_controller = std::move(created);
    } else
        m_controller = retainWK(controller);

    auto name = makeWKString(handlerName);
    auto world = makeWKString(worldName);
    if (!name || !world || !WKXanhUserContentControllerAddScriptMessageHandlerInWorld(
        m_controller.get(), name.get(), world.get(), didReceiveScriptMessage, this))
        return;

    auto source = makeWKString(bootstrapSource(m_state.tabID()));
    auto script = source
        ? adoptWK(WKXanhUserScriptCreateWithSourceInWorld(source.get(), kWKInjectAtDocumentStart, true, world.get()))
        : nullptr;
    if (!script) {
        WKXanhUserContentControllerRemoveScriptMessageHandlerInWorld(m_controller.get(), name.get(), world.get());
        return;
    }
    WKUserContentControllerAddUserScript(m_controller.get(), script.get());
    m_enabled = true;
}

XanhCredentialBridge::~XanhCredentialBridge()
{
    m_state.rendererTerminated();
    cancelPendingRequest();
    m_lifetime->owner = nullptr;
    if (!m_controller)
        return;
    auto name = makeWKString(handlerName);
    auto world = makeWKString(worldName);
    if (name && world) {
        WKXanhUserContentControllerRemoveScriptMessageHandlerInWorld(m_controller.get(), name.get(), world.get());
        WKXanhUserContentControllerRemoveAllUserScriptsInWorld(m_controller.get(), world.get());
    }
}

void XanhCredentialBridge::attachPage(WKPageRef page)
{
    if (!m_page)
        m_page = page;
}

void XanhCredentialBridge::navigationStarted(WKPageRef page)
{
    if (page == m_page) {
        m_state.navigationStarted();
        cancelPendingRequest();
    }
}

void XanhCredentialBridge::navigationFinished(WKPageRef page)
{
    if (m_enabled && page == m_page) {
        cancelPendingRequest();
        m_state.navigationFinished(activeURL(page));
    }
}

void XanhCredentialBridge::activeURLChanged(WKPageRef page)
{
    if (m_enabled && page == m_page) {
        cancelPendingRequest();
        m_state.navigationFinished(activeURL(page));
    }
}

void XanhCredentialBridge::rendererTerminated(WKPageRef page)
{
    if (page == m_page) {
        m_state.rendererTerminated();
        cancelPendingRequest();
    }
}

void XanhCredentialBridge::didReceiveScriptMessage(WKScriptMessageRef message, WKCompletionListenerRef reply, const void* context)
{
    if (!context || !reply)
        return;
    static_cast<XanhCredentialBridge*>(const_cast<void*>(context))->handleScriptMessage(message, reply);
}

void XanhCredentialBridge::handleScriptMessage(WKScriptMessageRef message, WKCompletionListenerRef reply)
{
    std::wstring requestID;
    auto finishUnavailable = [&] {
        auto response = unavailableReply(requestID);
        WKCompletionListenerComplete(reply, response.get());
    };
    if (!m_enabled || !message) {
        finishUnavailable();
        return;
    }
    auto body = WKScriptMessageGetBody(message);
    if (!body || WKGetTypeID(body) != WKDictionaryGetTypeID()) {
        finishUnavailable();
        return;
    }
    auto dictionary = static_cast<WKDictionaryRef>(body);
    if (WKDictionaryGetSize(dictionary) != 8) {
        finishUnavailable();
        return;
    }

    auto type = dictionaryString(dictionary, L"type", 128);
    auto tabID = dictionaryString(dictionary, L"tabId", XanhCredentialBridgePolicy::maximumTabIDBytes);
    auto challenge = dictionaryString(dictionary, L"challenge", XanhCredentialBridgePolicy::challengeHexCharacters);
    auto parsedRequestID = dictionaryString(dictionary, L"requestId", XanhCredentialBridgePolicy::requestIDHexCharacters);
    auto documentURL = dictionaryString(dictionary, L"documentUrl", XanhNavigationPolicy::maximumURLCharacters);
    auto claimedOrigin = dictionaryString(dictionary, L"claimedOrigin", XanhNavigationPolicy::maximumURLCharacters);
    auto usernameField = dictionaryString(dictionary, L"usernameField", XanhCredentialBridgePolicy::maximumFieldUTF8Bytes);
    auto passwordField = dictionaryString(dictionary, L"passwordField", XanhCredentialBridgePolicy::maximumFieldUTF8Bytes);
    if (!type || !tabID || !challenge || !parsedRequestID || !documentURL || !claimedOrigin || !usernameField || !passwordField) {
        finishUnavailable();
        return;
    }
    requestID = *parsedRequestID;

    auto frame = WKScriptMessageGetFrameInfo(message);
    bool isMainFrame = frame && WKFrameInfoGetIsMainFrame(frame) && WKFrameInfoGetPage(frame) == m_page;
    XanhCredentialBridgePolicy::Request request {
        std::move(*type), std::move(*tabID), std::move(*challenge), std::move(*parsedRequestID),
        std::move(*documentURL), std::move(*claimedOrigin), std::move(*usernameField), std::move(*passwordField)
    };
    auto token = m_state.validate(request, isMainFrame);
    auto asyncSequence = token ? m_asyncGate.begin() : std::nullopt;
    if (!token || !asyncSequence || !m_picker || !m_foregroundCheck || !m_foregroundCheck()) {
        if (asyncSequence)
            m_asyncGate.cancel();
        finishUnavailable();
        return;
    }

    auto pending = std::make_shared<PendingRequest>(PendingRequest {
        *asyncSequence,
        requestID,
        std::move(*token),
        retainWK(reply),
    });
    m_pendingRequest = pending;
    std::weak_ptr<Lifetime> lifetime = m_lifetime;
    std::weak_ptr<PendingRequest> weakPending = pending;
    try {
        m_picker(std::move(request), [lifetime, weakPending](std::optional<Credential> selected) mutable {
            auto live = lifetime.lock();
            auto pendingRequest = weakPending.lock();
            if (!live || !live->owner || !pendingRequest) {
                if (selected) {
                    secureClear(selected->username);
                    secureClear(selected->password);
                }
                return;
            }
            live->owner->finishPendingRequest(pendingRequest, std::move(selected));
        });
    } catch (...) {
        if (m_pendingRequest == pending)
            cancelPendingRequest();
    }
}

void XanhCredentialBridge::finishPendingRequest(
    const std::shared_ptr<PendingRequest>& pending,
    std::optional<Credential> selected)
{
    if (m_pendingRequest != pending || !m_asyncGate.finish(pending->asyncSequence)) {
        if (selected) {
            secureClear(selected->username);
            secureClear(selected->password);
        }
        return;
    }
    m_pendingRequest.reset();

    if (!selected || !m_foregroundCheck || !m_foregroundCheck() || !m_state.isCurrent(pending->token)
        || activeURL(m_page) != pending->token.documentURL
        || !XanhCredentialBridgePolicy::isBoundedText(selected->username, XanhCredentialBridgePolicy::maximumUsernameUTF8Bytes)
        || !XanhCredentialBridgePolicy::isBoundedText(selected->password, XanhCredentialBridgePolicy::maximumPasswordUTF8Bytes)) {
        if (selected) {
            secureClear(selected->username);
            secureClear(selected->password);
        }
        auto response = unavailableReply(pending->requestID);
        WKCompletionListenerComplete(pending->reply.get(), response.get());
        return;
    }
    auto response = credentialReply(pending->requestID, *selected);
    WKCompletionListenerComplete(pending->reply.get(), response.get());
    secureClear(selected->username);
    secureClear(selected->password);
}

void XanhCredentialBridge::cancelPendingRequest()
{
    auto pending = std::exchange(m_pendingRequest, { });
    m_asyncGate.cancel();
    if (!pending)
        return;
    auto response = unavailableReply(pending->requestID);
    WKCompletionListenerComplete(pending->reply.get(), response.get());
}

WKRetainPtr<WKDictionaryRef> XanhCredentialBridge::unavailableReply(std::wstring_view requestID) const
{
    return makeReply({ { L"status", L"unavailable" }, { L"requestId", requestID } });
}

WKRetainPtr<WKDictionaryRef> XanhCredentialBridge::credentialReply(std::wstring_view requestID, const Credential& credential) const
{
    return makeReply({
        { L"status", L"fill" },
        { L"requestId", requestID },
        { L"username", credential.username },
        { L"password", credential.password },
    });
}
