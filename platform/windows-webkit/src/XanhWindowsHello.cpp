/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "XanhWindowsHello.h"

#include <userconsentverifierinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Security.Credentials.UI.h>
#include <string_view>
#include <utility>

using ConsentResult = winrt::Windows::Security::Credentials::UI::UserConsentVerificationResult;
using ConsentVerifier = winrt::Windows::Security::Credentials::UI::UserConsentVerifier;
using ConsentOperation = winrt::Windows::Foundation::IAsyncOperation<ConsentResult>;

struct XanhWindowsHello::State {
    explicit State(HWND owner)
        : ownerWindow(owner)
    {
    }

    HWND ownerWindow { nullptr };
    uint64_t generation { 0 };
    bool disposed { false };
    ConsentOperation operation { nullptr };
};

namespace {

bool isSafeReason(std::wstring_view reason)
{
    if (reason.empty() || reason.size() > 256)
        return false;
    for (auto character : reason) {
        if (character <= 0x1F || character == 0x7F)
            return false;
    }
    return true;
}

template<typename StateType>
uint64_t nextGeneration(const std::shared_ptr<StateType>& state)
{
    if (++state->generation == 0)
        ++state->generation;
    return state->generation;
}

template<typename StateType>
winrt::fire_and_forget verifyForWindow(
    std::shared_ptr<StateType> state,
    uint64_t generation,
    winrt::hstring reason,
    XanhWindowsHello::Completion completion)
{
    bool verified = false;
    try {
        auto interop = winrt::get_activation_factory<ConsentVerifier, ::IUserConsentVerifierInterop>();
        auto operation = winrt::capture<ConsentOperation>(
            interop,
            &::IUserConsentVerifierInterop::RequestVerificationForWindowAsync,
            state->ownerWindow,
            reinterpret_cast<HSTRING>(winrt::get_abi(reason)));
        if (state->disposed || state->generation != generation) {
            operation.Cancel();
            co_return;
        }
        state->operation = operation;
        auto result = co_await operation;
        if (state->disposed || state->generation != generation)
            co_return;
        verified = result == ConsentResult::Verified;
    } catch (...) {
        if (state->disposed || state->generation != generation)
            co_return;
    }
    state->operation = nullptr;
    try {
        completion(verified);
    } catch (...) {
    }
}

} // namespace

XanhWindowsHello::XanhWindowsHello(HWND ownerWindow)
    : m_state(std::make_shared<State>(ownerWindow))
{
}

XanhWindowsHello::~XanhWindowsHello()
{
    m_state->disposed = true;
    cancel();
}

void XanhWindowsHello::verify(std::wstring reason, Completion completion)
{
    if (!completion)
        return;
    if (m_state->disposed || !m_state->ownerWindow || !IsWindow(m_state->ownerWindow)
        || GetForegroundWindow() != m_state->ownerWindow || !isSafeReason(reason)) {
        try {
            completion(false);
        } catch (...) {
        }
        return;
    }

    cancel();
    auto generation = nextGeneration(m_state);
    verifyForWindow(m_state, generation, winrt::hstring(reason), std::move(completion));
}

void XanhWindowsHello::cancel()
{
    nextGeneration(m_state);
    auto operation = std::exchange(m_state->operation, nullptr);
    if (operation) {
        try {
            operation.Cancel();
        } catch (...) {
        }
    }
}
