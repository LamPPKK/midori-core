/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

class XanhNativeSyncLibrary;

class XanhSensitiveUTF8 {
public:
    XanhSensitiveUTF8() = default;
    ~XanhSensitiveUTF8();

    static XanhSensitiveUTF8 take(std::string&&);

    XanhSensitiveUTF8(XanhSensitiveUTF8&&);
    XanhSensitiveUTF8& operator=(XanhSensitiveUTF8&&);
    XanhSensitiveUTF8(const XanhSensitiveUTF8&) = delete;
    XanhSensitiveUTF8& operator=(const XanhSensitiveUTF8&) = delete;

    std::string_view view() const
    {
        return m_data ? std::string_view(m_data.get(), m_size) : std::string_view();
    }
    bool empty() const { return !m_size; }

private:
    friend class XanhNativeSyncRuntime;
    static XanhSensitiveUTF8 copyOf(std::string_view);
    void clear();
    std::unique_ptr<char[]> m_data;
    std::size_t m_size { 0 };
};

class XanhNativeSyncRuntime {
public:
    enum class AccountState : std::int32_t {
        disconnected = 0,
        authenticating = 1,
        connected = 2,
        authIssues = 3,
    };

    struct OpenParameters {
        std::string configurationJSON;
        std::string profileDirectory;
        std::optional<XanhSensitiveUTF8> localLoginsKey;
        std::optional<XanhSensitiveUTF8> accountJSON;
        std::optional<XanhSensitiveUTF8> persistedSyncState;
    };

    static std::unique_ptr<XanhNativeSyncRuntime> open(
        std::unique_ptr<XanhNativeSyncLibrary>, OpenParameters, std::string& error);
    static std::optional<XanhSensitiveUTF8> generateLocalLoginsKey(
        const XanhNativeSyncLibrary&, std::string& error);

    ~XanhNativeSyncRuntime();
    XanhNativeSyncRuntime(const XanhNativeSyncRuntime&) = delete;
    XanhNativeSyncRuntime& operator=(const XanhNativeSyncRuntime&) = delete;

    std::optional<AccountState> initialize();
    std::optional<AccountState> accountState();
    bool vaultUnlocked();
    bool unlockVault(std::string_view localLoginsKey);
    bool lockVault();
    std::optional<XanhSensitiveUTF8> credentialsJSON(std::string_view contextJSON);
    bool touchCredential(std::string_view id, std::string_view contextJSON);
    std::string takeLastError();

    static constexpr std::size_t maximumConfigurationBytes = 64 * 1024;
    static constexpr std::size_t maximumProfileDirectoryBytes = 32 * 1024;
    static constexpr std::size_t maximumOpenSecretBytes = 4 * 1024 * 1024;
    static constexpr std::size_t maximumLoginsKeyBytes = 4096;
    static constexpr std::size_t maximumCredentialContextBytes = 64 * 1024;
    static constexpr std::size_t maximumCredentialOutputBytes = 4 * 1024 * 1024;
    static constexpr std::size_t maximumCredentialIDBytes = 128;
    static constexpr std::size_t maximumErrorBytes = 64 * 1024;

private:
    struct Impl;
    explicit XanhNativeSyncRuntime(std::unique_ptr<Impl>);
    std::unique_ptr<Impl> m_impl;
};
