#include "XanhCredentialRecords.h"

#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void expect(bool condition, const char* message, unsigned& assertions)
{
    ++assertions;
    if (!condition)
        throw std::runtime_error(message);
}

std::string record(
    std::string id = "login_1",
    std::string origin = "https://example.test",
    std::string username = "alice",
    std::string password = "secret",
    std::string created = "0")
{
    return "{\"id\":\"" + id
        + "\",\"origin\":\"" + origin
        + "\",\"form_action_origin\":\"" + origin
        + "\",\"username_field\":\"username\""
          ",\"password_field\":\"password\""
          ",\"username\":\"" + username
        + "\",\"password\":\"" + password
        + "\",\"time_created_epoch_millis\":" + created
        + ",\"time_password_changed_epoch_millis\":1"
          ",\"time_last_used_epoch_millis\":2"
          ",\"times_used\":3}";
}

std::string arrayOf(std::size_t count)
{
    std::string result = "[";
    for (std::size_t index = 0; index < count; ++index) {
        if (index)
            result += ',';
        result += record("login_" + std::to_string(index));
    }
    result += ']';
    return result;
}

std::string replaceOnce(std::string input, std::string_view from, std::string_view to)
{
    auto offset = input.find(from);
    if (offset == std::string::npos)
        throw std::runtime_error("Broken credential test fixture.");
    input.replace(offset, from.size(), to);
    return input;
}

} // namespace

int main()
{
    unsigned assertions = 0;
    try {
        constexpr std::wstring_view origin = L"https://example.test";
        auto parsed = XanhCredentialRecords::parse(
            "[" + record("login_1", "https://example.test", "al\\u0069ce", "s\\u00e9cret") + "]",
            origin);
        expect(parsed && parsed->size() == 1, "A valid credential array was rejected.", assertions);
        expect((*parsed)[0].id == "login_1", "Credential ID changed during parsing.", assertions);
        expect((*parsed)[0].username.view() == L"alice", "Escaped username was decoded incorrectly.", assertions);
        expect((*parsed)[0].password.view() == L"s\u00e9cret", "Escaped password was decoded incorrectly.", assertions);
        auto escapedLabel = XanhSensitiveWide::forNativeLabel(L"A&B");
        expect(escapedLabel && escapedLabel->view() == L"A&&B", "Task Dialog metacharacters were not escaped.", assertions);
        expect(!XanhSensitiveWide::forNativeLabel(L"alice\u202eexample"), "A bidi-control username was accepted for native display.", assertions);
        expect(!XanhSensitiveWide::forNativeLabel(L"alice\u061cexample"), "An Arabic letter mark was accepted for native display.", assertions);

        auto rawUnicode = XanhCredentialRecords::parse(
            "[" + record("login_2", "https://example.test", "\xf0\x9f\x91\xa4", "p\xf0\x9f\x94\x91") + "]",
            origin);
        expect(rawUnicode && !(*rawUnicode)[0].username.empty(), "Valid four-byte UTF-8 was rejected.", assertions);
        expect(XanhCredentialRecords::parse("[]", origin)->empty(), "An empty credential array was rejected.", assertions);
        expect(XanhCredentialRecords::parse(arrayOf(100), origin)->size() == 100, "The 100-record boundary was rejected.", assertions);
        expect(!XanhCredentialRecords::parse(arrayOf(101), origin), "More than 100 credentials were accepted.", assertions);
        expect(!XanhCredentialRecords::parse(std::string(XanhCredentialRecords::maximumJSONBytes + 1, 'x'), origin), "Oversized credential JSON was accepted.", assertions);

        auto valid = "[" + record() + "]";
        expect(!XanhCredentialRecords::parse(valid, L"http://example.test"), "A non-HTTPS expected origin was accepted.", assertions);
        expect(!XanhCredentialRecords::parse(valid, L"https://EXAMPLE.test"), "A non-canonical expected origin was accepted.", assertions);
        expect(!XanhCredentialRecords::parse("[" + record("login_1", "https://other.test") + "]", origin), "A cross-origin credential was accepted.", assertions);
        expect(!XanhCredentialRecords::parse("[" + record("bad id") + "]", origin), "An unsafe credential ID was accepted.", assertions);
        expect(!XanhCredentialRecords::parse("[" + record("login_1") + "," + record("login_1") + "]", origin), "A duplicate credential ID was accepted.", assertions);
        expect(!XanhCredentialRecords::parse("[" + record("login_1", "https://example.test", "alice", "") + "]", origin), "An empty password was accepted.", assertions);
        expect(!XanhCredentialRecords::parse("[" + record("login_1", "https://example.test", "a\\u0000b") + "]", origin), "A NUL username was accepted.", assertions);
        expect(!XanhCredentialRecords::parse("[" + record("login_1", "https://example.test", "alice", "x", "-1") + "]", origin), "A negative timestamp was accepted.", assertions);
        expect(!XanhCredentialRecords::parse("[" + record("login_1", "https://example.test", "alice", "x", "1.5") + "]", origin), "A fractional timestamp was accepted.", assertions);
        expect(!XanhCredentialRecords::parse("[" + record("login_1", "https://example.test", "alice", "x", "00") + "]", origin), "A non-canonical integer was accepted.", assertions);
        expect(!XanhCredentialRecords::parse("[" + record("login_1", "https://example.test", "alice", "x", "9223372036854775808") + "]", origin), "An overflowing timestamp was accepted.", assertions);
        expect(!XanhCredentialRecords::parse(valid + "x", origin), "Trailing JSON data was accepted.", assertions);
        expect(!XanhCredentialRecords::parse(replaceOnce(valid, "\"origin\"", "\"unexpected\""), origin), "An unknown record field was accepted.", assertions);
        expect(!XanhCredentialRecords::parse(replaceOnce(valid, "\"username_field\":\"username\"", "\"username_field\":\"bad\\nfield\""), origin), "A control-bearing field name was accepted.", assertions);
        expect(!XanhCredentialRecords::parse("[" + record("login_1", "https://example.test", "\\ud800") + "]", origin), "An unpaired JSON surrogate was accepted.", assertions);

        auto invalidUTF8 = valid;
        invalidUTF8 = replaceOnce(std::move(invalidUTF8), "alice", std::string("\xc0\xaf", 2));
        expect(!XanhCredentialRecords::parse(invalidUTF8, origin), "Overlong UTF-8 was accepted.", assertions);

        auto wrongAction = replaceOnce(valid,
            "\"form_action_origin\":\"https://example.test\"",
            "\"form_action_origin\":\"https://other.test\"");
        expect(!XanhCredentialRecords::parse(wrongAction, origin), "A cross-origin form action was accepted.", assertions);

        std::cout << assertions << " Xanh credential-record assertions passed\n";
        return 0;
    } catch (const std::exception& exception) {
        std::cerr << "Xanh credential-record test failed: " << exception.what() << '\n';
        return 1;
    }
}
