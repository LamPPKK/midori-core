#include "XanhOAuthCallback.h"

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

} // namespace

int main()
{
    unsigned assertions = 0;
    try {
        auto parsed = XanhOAuthCallbackParser::parse(
            L"xanh-browser-wincairo://accounts/oauth?state=test-state&code=test%2Dcode");
        expect(parsed.has_value(), "A valid callback was rejected.", assertions);
        expect(parsed->code.view() == "test-code", "The OAuth code was decoded incorrectly.", assertions);
        expect(parsed->state.view() == "test-state", "The OAuth state was decoded incorrectly.", assertions);
        expect(!XanhOAuthCallbackParser::parse(L"https://example.test/?code=a&state=b"), "A foreign callback origin was accepted.", assertions);
        expect(!XanhOAuthCallbackParser::parse(L"xanh-browser-wincairo://accounts/oauth?code=a"), "A callback without state was accepted.", assertions);
        expect(!XanhOAuthCallbackParser::parse(L"xanh-browser-wincairo://accounts/oauth?code=a&state=b&code=c"), "A duplicate OAuth code was accepted.", assertions);
        expect(!XanhOAuthCallbackParser::parse(L"xanh-browser-wincairo://accounts/oauth?code=a&state=b&extra=c"), "An unknown OAuth callback field was accepted.", assertions);
        expect(!XanhOAuthCallbackParser::parse(L"xanh-browser-wincairo://accounts/oauth?code=a%0d%0a&state=b"), "A control-bearing OAuth code was accepted.", assertions);
        expect(!XanhOAuthCallbackParser::parse(L"xanh-browser-wincairo://accounts/oauth?code=%c0%af&state=b"), "Invalid UTF-8 was accepted.", assertions);
        expect(!XanhOAuthCallbackParser::parse(L"xanh-browser-wincairo://accounts/oauth?code=%zz&state=b"), "An invalid percent escape was accepted.", assertions);
        expect(!XanhOAuthCallbackParser::parse(L"xanh-browser-wincairo://accounts/oauth?code=a&state=b#fragment"), "An OAuth callback fragment was accepted.", assertions);
        expect(!XanhOAuthCallbackParser::parse(
            L"xanh-browser-wincairo://accounts/oauth?code="
            + std::wstring(XanhNativeSyncRuntime::maximumOAuthComponentBytes + 1, L'a')
            + L"&state=b"), "An oversized OAuth code was accepted.", assertions);

        std::cout << assertions << " Xanh OAuth callback assertions passed\n";
        return 0;
    } catch (const std::exception& exception) {
        std::cerr << "Xanh OAuth callback test failed: " << exception.what() << '\n';
        return 1;
    }
}
