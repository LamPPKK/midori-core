/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <cstdint>
#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

class XanhNativeSyncLibrary;

class XanhSensitiveUTF8 {
public:
    XanhSensitiveUTF8() = default;
    ~XanhSensitiveUTF8() { clear(); }

    static XanhSensitiveUTF8 take(std::string&& value)
    {
        try {
            auto result = copyOf(value);
            wipe(value);
            return result;
        } catch (...) {
            wipe(value);
            throw;
        }
    }

    XanhSensitiveUTF8(XanhSensitiveUTF8&& other) noexcept
        : m_data(std::move(other.m_data))
        , m_size(std::exchange(other.m_size, 0))
    {
    }
    XanhSensitiveUTF8& operator=(XanhSensitiveUTF8&& other) noexcept
    {
        if (this != &other) {
            clear();
            m_data = std::move(other.m_data);
            m_size = std::exchange(other.m_size, 0);
        }
        return *this;
    }
    XanhSensitiveUTF8(const XanhSensitiveUTF8&) = delete;
    XanhSensitiveUTF8& operator=(const XanhSensitiveUTF8&) = delete;

    std::string_view view() const
    {
        return m_data ? std::string_view(m_data.get(), m_size) : std::string_view();
    }
    bool empty() const { return !m_size; }

private:
    friend class XanhNativeSyncRuntime;
    static void wipe(std::string& value)
    {
        if (!value.empty()) {
            volatile char* output = value.data();
            for (std::size_t index = 0; index < value.size(); ++index)
                output[index] = 0;
        }
        value.clear();
    }
    static XanhSensitiveUTF8 copyOf(std::string_view value)
    {
        XanhSensitiveUTF8 result;
        if (value.empty())
            return result;
        result.m_data = std::make_unique<char[]>(value.size() + 1);
        std::memcpy(result.m_data.get(), value.data(), value.size());
        result.m_data[value.size()] = '\0';
        result.m_size = value.size();
        return result;
    }
    void clear()
    {
        if (m_data && m_size) {
            volatile char* output = m_data.get();
            for (std::size_t index = 0; index < m_size; ++index)
                output[index] = 0;
        }
        m_data.reset();
        m_size = 0;
    }
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
    std::optional<XanhSensitiveUTF8> beginOAuth();
    std::optional<AccountState> completeOAuth(
        std::string_view code, std::string_view state);
    std::optional<XanhSensitiveUTF8> accountJSON();
    std::optional<XanhSensitiveUTF8> persistedState();
    std::optional<XanhSensitiveUTF8> generateLocalLoginsKey();
    std::optional<XanhSensitiveUTF8> sync(
        std::int32_t reason, std::string_view enginesJSON);
    bool disconnect(bool deleteLocal);
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
    static constexpr std::size_t maximumOAuthURLBytes = 64 * 1024;
    static constexpr std::size_t maximumOAuthComponentBytes = 8192;
    static constexpr std::size_t maximumEnginesJSONBytes = 4096;
    static constexpr std::size_t maximumSyncResultBytes = 64 * 1024;
    static constexpr std::size_t maximumErrorBytes = 64 * 1024;

private:
    struct Impl;
    explicit XanhNativeSyncRuntime(std::unique_ptr<Impl>);
    std::unique_ptr<Impl> m_impl;
};
