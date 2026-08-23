/*
 * Copyright (C) 2026 Xanh Browser contributors.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "XanhCredentialRecords.h"

#include "XanhCredentialBridgePolicy.h"

#include <climits>
#include <cstdint>
#include <cstring>
#include <limits>
#include <unordered_set>
#include <utility>

namespace {

void secureZero(void* value, std::size_t bytes)
{
    auto* output = static_cast<volatile unsigned char*>(value);
    while (bytes--)
        *output++ = 0;
}

class SensitiveBytes {
public:
    explicit SensitiveBytes(std::size_t capacity)
    {
        m_bytes.reserve(capacity);
    }
    ~SensitiveBytes()
    {
        if (!m_bytes.empty())
            secureZero(m_bytes.data(), m_bytes.size());
    }

    SensitiveBytes(SensitiveBytes&&) noexcept = default;
    SensitiveBytes& operator=(SensitiveBytes&&) noexcept = default;
    SensitiveBytes(const SensitiveBytes&) = delete;
    SensitiveBytes& operator=(const SensitiveBytes&) = delete;

    bool append(unsigned char value, std::size_t maximum)
    {
        if (m_bytes.size() >= maximum)
            return false;
        m_bytes.push_back(static_cast<char>(value));
        return true;
    }

    bool appendScalar(std::uint32_t scalar, std::size_t maximum)
    {
        if (scalar <= 0x7f)
            return append(static_cast<unsigned char>(scalar), maximum);
        if (scalar <= 0x7ff)
            return append(static_cast<unsigned char>(0xc0 | (scalar >> 6)), maximum)
                && append(static_cast<unsigned char>(0x80 | (scalar & 0x3f)), maximum);
        if (scalar <= 0xffff)
            return append(static_cast<unsigned char>(0xe0 | (scalar >> 12)), maximum)
                && append(static_cast<unsigned char>(0x80 | ((scalar >> 6) & 0x3f)), maximum)
                && append(static_cast<unsigned char>(0x80 | (scalar & 0x3f)), maximum);
        return scalar <= 0x10ffff
            && append(static_cast<unsigned char>(0xf0 | (scalar >> 18)), maximum)
            && append(static_cast<unsigned char>(0x80 | ((scalar >> 12) & 0x3f)), maximum)
            && append(static_cast<unsigned char>(0x80 | ((scalar >> 6) & 0x3f)), maximum)
            && append(static_cast<unsigned char>(0x80 | (scalar & 0x3f)), maximum);
    }

    std::string_view view() const { return { m_bytes.data(), m_bytes.size() }; }

private:
    std::vector<char> m_bytes;
};

std::optional<std::uint32_t> decodeScalar(std::string_view value, std::size_t& offset)
{
    if (offset >= value.size())
        return std::nullopt;
    auto first = static_cast<unsigned char>(value[offset++]);
    if (first <= 0x7f)
        return first;

    unsigned continuations = 0;
    std::uint32_t scalar = 0;
    std::uint32_t minimum = 0;
    if ((first & 0xe0) == 0xc0) {
        continuations = 1;
        scalar = first & 0x1f;
        minimum = 0x80;
    } else if ((first & 0xf0) == 0xe0) {
        continuations = 2;
        scalar = first & 0x0f;
        minimum = 0x800;
    } else if ((first & 0xf8) == 0xf0) {
        continuations = 3;
        scalar = first & 0x07;
        minimum = 0x10000;
    } else
        return std::nullopt;

    if (value.size() - offset < continuations)
        return std::nullopt;
    for (unsigned index = 0; index < continuations; ++index) {
        auto next = static_cast<unsigned char>(value[offset++]);
        if ((next & 0xc0) != 0x80)
            return std::nullopt;
        scalar = (scalar << 6) | (next & 0x3f);
    }
    if (scalar < minimum || scalar > 0x10ffff
        || (scalar >= 0xd800 && scalar <= 0xdfff))
        return std::nullopt;
    return scalar;
}

bool appendWideScalar(std::wstring& output, std::uint32_t scalar)
{
#if WCHAR_MAX <= 0xffff
    if (scalar > 0xffff) {
        scalar -= 0x10000;
        output.push_back(static_cast<wchar_t>(0xd800 + (scalar >> 10)));
        output.push_back(static_cast<wchar_t>(0xdc00 + (scalar & 0x3ff)));
        return true;
    }
#endif
    output.push_back(static_cast<wchar_t>(scalar));
    return true;
}

bool appendWideScalar(std::vector<wchar_t>& output, std::uint32_t scalar)
{
#if WCHAR_MAX <= 0xffff
    if (scalar > 0xffff) {
        scalar -= 0x10000;
        output.push_back(static_cast<wchar_t>(0xd800 + (scalar >> 10)));
        output.push_back(static_cast<wchar_t>(0xdc00 + (scalar & 0x3ff)));
        return true;
    }
#endif
    output.push_back(static_cast<wchar_t>(scalar));
    return true;
}

std::optional<std::wstring> wideFromUTF8(std::string_view value)
{
    std::wstring output;
    output.reserve(value.size());
    std::size_t offset = 0;
    while (offset < value.size()) {
        auto scalar = decodeScalar(value, offset);
        if (!scalar || !appendWideScalar(output, *scalar))
            return std::nullopt;
    }
    return output;
}

bool isCredentialID(std::string_view value)
{
    if (value.empty() || value.size() > XanhCredentialRecords::maximumIDBytes)
        return false;
    for (unsigned char character : value) {
        if (!(character >= 'a' && character <= 'z')
            && !(character >= 'A' && character <= 'Z')
            && !(character >= '0' && character <= '9')
            && character != '-' && character != '_')
            return false;
    }
    return true;
}

class Parser {
public:
    explicit Parser(std::string_view input)
        : m_input(input)
    {
    }

    std::optional<std::vector<XanhCredentialRecord>> parse(std::wstring_view expectedOrigin)
    {
        if (!consume('['))
            return std::nullopt;
        std::vector<XanhCredentialRecord> records;
        skipWhitespace();
        if (consume(']'))
            return finish(std::move(records));
        std::unordered_set<std::string> identifiers;
        while (records.size() < XanhCredentialRecords::maximumRecords) {
            auto record = parseRecord(expectedOrigin);
            if (!record || !identifiers.insert(record->id).second)
                return std::nullopt;
            records.push_back(std::move(*record));
            skipWhitespace();
            if (consume(']'))
                return finish(std::move(records));
            if (!consume(','))
                return std::nullopt;
        }
        return std::nullopt;
    }

private:
    std::optional<std::vector<XanhCredentialRecord>> finish(
        std::vector<XanhCredentialRecord> records)
    {
        skipWhitespace();
        if (m_offset != m_input.size())
            return std::nullopt;
        return records;
    }

    std::optional<XanhCredentialRecord> parseRecord(std::wstring_view expectedOrigin)
    {
        if (!consume('{'))
            return std::nullopt;
        auto id = namedString("id", XanhCredentialRecords::maximumIDBytes);
        if (!id || !consume(','))
            return std::nullopt;
        auto origin = namedString("origin", XanhCredentialRecords::maximumOriginBytes);
        if (!origin || !consume(','))
            return std::nullopt;
        auto action = namedString("form_action_origin", XanhCredentialRecords::maximumOriginBytes);
        if (!action || !consume(','))
            return std::nullopt;
        auto usernameField = namedString("username_field", XanhCredentialRecords::maximumFieldBytes);
        if (!usernameField || !consume(','))
            return std::nullopt;
        auto passwordField = namedString("password_field", XanhCredentialRecords::maximumFieldBytes);
        if (!passwordField || !consume(','))
            return std::nullopt;
        auto username = namedString("username", XanhCredentialRecords::maximumUsernameBytes);
        if (!username || !consume(','))
            return std::nullopt;
        auto password = namedString("password", XanhCredentialRecords::maximumPasswordBytes);
        if (!password || !consume(','))
            return std::nullopt;
        if (!namedInteger("time_created_epoch_millis") || !consume(',')
            || !namedInteger("time_password_changed_epoch_millis") || !consume(',')
            || !namedInteger("time_last_used_epoch_millis") || !consume(',')
            || !namedInteger("times_used") || !consume('}'))
            return std::nullopt;

        auto idString = std::string(id->view());
        auto originWide = wideFromUTF8(origin->view());
        auto actionWide = wideFromUTF8(action->view());
        auto usernameFieldWide = wideFromUTF8(usernameField->view());
        auto passwordFieldWide = wideFromUTF8(passwordField->view());
        auto usernameWide = XanhSensitiveWide::fromUTF8(username->view());
        auto passwordWide = XanhSensitiveWide::fromUTF8(password->view());
        if (!isCredentialID(idString) || !originWide || !actionWide
            || *originWide != expectedOrigin || *actionWide != expectedOrigin
            || !usernameFieldWide || !passwordFieldWide || !usernameWide || !passwordWide
            || !XanhCredentialBridgePolicy::isBoundedText(
                *usernameFieldWide, XanhCredentialRecords::maximumFieldBytes)
            || !XanhCredentialBridgePolicy::isBoundedText(
                *passwordFieldWide, XanhCredentialRecords::maximumFieldBytes)
            || !XanhCredentialBridgePolicy::isBoundedText(
                usernameWide->view(), XanhCredentialRecords::maximumUsernameBytes)
            || passwordWide->empty()
            || !XanhCredentialBridgePolicy::isBoundedText(
                passwordWide->view(), XanhCredentialRecords::maximumPasswordBytes))
            return std::nullopt;
        return XanhCredentialRecord {
            std::move(idString), std::move(*usernameWide), std::move(*passwordWide)
        };
    }

    std::optional<SensitiveBytes> namedString(
        std::string_view expectedName, std::size_t maximumBytes)
    {
        auto name = string(64);
        if (!name || name->view() != expectedName || !consume(':'))
            return std::nullopt;
        return string(maximumBytes);
    }

    bool namedInteger(std::string_view expectedName)
    {
        auto name = string(64);
        if (!name || name->view() != expectedName || !consume(':'))
            return false;
        return integer();
    }

    std::optional<SensitiveBytes> string(std::size_t maximumBytes)
    {
        skipWhitespace();
        if (m_offset >= m_input.size() || m_input[m_offset++] != '"')
            return std::nullopt;
        SensitiveBytes result(maximumBytes);
        while (m_offset < m_input.size()) {
            auto character = static_cast<unsigned char>(m_input[m_offset++]);
            if (character == '"')
                return result;
            if (character < 0x20)
                return std::nullopt;
            if (character != '\\') {
                if (!result.append(character, maximumBytes))
                    return std::nullopt;
                continue;
            }
            if (m_offset >= m_input.size())
                return std::nullopt;
            auto escape = m_input[m_offset++];
            switch (escape) {
            case '"': case '\\': case '/':
                if (!result.append(static_cast<unsigned char>(escape), maximumBytes))
                    return std::nullopt;
                break;
            case 'b': case 'f': case 'n': case 'r': case 't': {
                unsigned char decoded = escape == 'b' ? '\b' : escape == 'f' ? '\f'
                    : escape == 'n' ? '\n' : escape == 'r' ? '\r' : '\t';
                if (!result.append(decoded, maximumBytes))
                    return std::nullopt;
                break;
            }
            case 'u': {
                auto scalar = hexQuad();
                if (!scalar)
                    return std::nullopt;
                if (*scalar >= 0xd800 && *scalar <= 0xdbff) {
                    if (m_input.size() - m_offset < 6 || m_input[m_offset] != '\\'
                        || m_input[m_offset + 1] != 'u')
                        return std::nullopt;
                    m_offset += 2;
                    auto low = hexQuad();
                    if (!low || *low < 0xdc00 || *low > 0xdfff)
                        return std::nullopt;
                    *scalar = 0x10000 + ((*scalar - 0xd800) << 10) + (*low - 0xdc00);
                } else if (*scalar >= 0xdc00 && *scalar <= 0xdfff)
                    return std::nullopt;
                if (!result.appendScalar(*scalar, maximumBytes))
                    return std::nullopt;
                break;
            }
            default:
                return std::nullopt;
            }
        }
        return std::nullopt;
    }

    std::optional<std::uint32_t> hexQuad()
    {
        if (m_input.size() - m_offset < 4)
            return std::nullopt;
        std::uint32_t value = 0;
        for (unsigned index = 0; index < 4; ++index) {
            auto character = m_input[m_offset++];
            value <<= 4;
            if (character >= '0' && character <= '9')
                value |= character - '0';
            else if (character >= 'a' && character <= 'f')
                value |= character - 'a' + 10;
            else if (character >= 'A' && character <= 'F')
                value |= character - 'A' + 10;
            else
                return std::nullopt;
        }
        return value;
    }

    bool integer()
    {
        skipWhitespace();
        if (m_offset >= m_input.size() || m_input[m_offset] < '0' || m_input[m_offset] > '9')
            return false;
        auto start = m_offset;
        bool leadingZero = m_input[m_offset] == '0';
        std::uint64_t value = 0;
        do {
            auto digit = static_cast<unsigned>(m_input[m_offset++] - '0');
            if (value > (static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()) - digit) / 10)
                return false;
            value = value * 10 + digit;
        } while (m_offset < m_input.size() && m_input[m_offset] >= '0' && m_input[m_offset] <= '9');
        return !leadingZero || m_offset - start == 1;
    }

    bool consume(char expected)
    {
        skipWhitespace();
        if (m_offset >= m_input.size() || m_input[m_offset] != expected)
            return false;
        ++m_offset;
        return true;
    }

    void skipWhitespace()
    {
        while (m_offset < m_input.size()
            && (m_input[m_offset] == ' ' || m_input[m_offset] == '\t'
                || m_input[m_offset] == '\r' || m_input[m_offset] == '\n'))
            ++m_offset;
    }

    std::string_view m_input;
    std::size_t m_offset { 0 };
};

} // namespace

std::optional<XanhSensitiveWide> XanhSensitiveWide::fromUTF8(std::string_view value)
{
    std::vector<wchar_t> wide;
    try {
        wide.reserve(value.size());
        std::size_t offset = 0;
        while (offset < value.size()) {
            auto scalar = decodeScalar(value, offset);
            if (!scalar || !appendWideScalar(wide, *scalar)) {
                if (!wide.empty())
                    secureZero(wide.data(), wide.size() * sizeof(wchar_t));
                return std::nullopt;
            }
        }
        XanhSensitiveWide result;
        if (!wide.empty()) {
            result.m_data = std::make_unique<wchar_t[]>(wide.size() + 1);
            std::memcpy(result.m_data.get(), wide.data(), wide.size() * sizeof(wchar_t));
            result.m_data[wide.size()] = L'\0';
            result.m_size = wide.size();
            secureZero(wide.data(), wide.size() * sizeof(wchar_t));
        }
        return result;
    } catch (...) {
        if (!wide.empty())
            secureZero(wide.data(), wide.size() * sizeof(wchar_t));
        throw;
    }
}

XanhSensitiveWide XanhSensitiveWide::take(std::wstring&& value)
{
    XanhSensitiveWide result;
    try {
        if (!value.empty()) {
            result.m_data = std::make_unique<wchar_t[]>(value.size() + 1);
            std::memcpy(result.m_data.get(), value.data(),
                value.size() * sizeof(wchar_t));
            result.m_data[value.size()] = L'\0';
            result.m_size = value.size();
            secureZero(value.data(), value.size() * sizeof(wchar_t));
            value.clear();
        }
        return result;
    } catch (...) {
        if (!value.empty())
            secureZero(value.data(), value.size() * sizeof(wchar_t));
        value.clear();
        throw;
    }
}

std::optional<XanhSensitiveWide> XanhSensitiveWide::forNativeLabel(
    std::wstring_view value)
{
    if (!XanhCredentialBridgePolicy::isBoundedText(
            value, XanhCredentialRecords::maximumUsernameBytes)
        || value.size() > (std::numeric_limits<std::size_t>::max() - 1) / 2)
        return std::nullopt;
    XanhSensitiveWide result;
    if (value.empty())
        return result;
    result.m_data = std::make_unique<wchar_t[]>(value.size() * 2 + 1);
    for (auto character : value) {
        auto scalar = static_cast<std::uint32_t>(character);
        if (scalar == 0x061c
            || (scalar >= 0x200b && scalar <= 0x200f)
            || (scalar >= 0x2028 && scalar <= 0x202e)
            || (scalar >= 0x2060 && scalar <= 0x206f)
            || scalar == 0xfeff) {
            result.clear();
            return std::nullopt;
        }
        result.m_data[result.m_size++] = character;
        if (character == L'&')
            result.m_data[result.m_size++] = L'&';
    }
    result.m_data[result.m_size] = L'\0';
    return result;
}

XanhSensitiveWide::~XanhSensitiveWide()
{
    clear();
}

XanhSensitiveWide::XanhSensitiveWide(XanhSensitiveWide&& other) noexcept
    : m_data(std::move(other.m_data))
    , m_size(std::exchange(other.m_size, 0))
{
}

XanhSensitiveWide& XanhSensitiveWide::operator=(XanhSensitiveWide&& other) noexcept
{
    if (this != &other) {
        clear();
        m_data = std::move(other.m_data);
        m_size = std::exchange(other.m_size, 0);
    }
    return *this;
}

void XanhSensitiveWide::clear()
{
    if (m_data && m_size)
        secureZero(m_data.get(), m_size * sizeof(wchar_t));
    m_data.reset();
    m_size = 0;
}

std::optional<std::vector<XanhCredentialRecord>> XanhCredentialRecords::parse(
    std::string_view json, std::wstring_view expectedOrigin)
{
    if (json.size() > maximumJSONBytes
        || !XanhCredentialBridgePolicy::canonicalHTTPSOrigin(expectedOrigin)
        || *XanhCredentialBridgePolicy::canonicalHTTPSOrigin(expectedOrigin) != expectedOrigin)
        return std::nullopt;
    return Parser(json).parse(expectedOrigin);
}
