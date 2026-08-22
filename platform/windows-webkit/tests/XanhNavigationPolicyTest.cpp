#include "XanhNavigationPolicy.h"

#include <cassert>
#include <string>

using XanhNavigationPolicy::Decision;
using XanhNavigationPolicy::decide;

int main()
{
    auto navigate = [](std::wstring_view url, bool gesture, bool redirect, bool externalPermission, bool trustedLinkClick = true) {
        return decide(url, gesture, trustedLinkClick, redirect, externalPermission);
    };

    assert(navigate(L"https://example.com/path?q=1#fragment", false, false, false) == Decision::allowInWebView);
    assert(navigate(L"HTTP://localhost:8080/", false, false, false) == Decision::allowInWebView);
    assert(navigate(L"https://[2001:db8::1]:443/", false, false, false) == Decision::allowInWebView);
    assert(navigate(L"about:blank#frame", false, false, false) == Decision::allowInWebView);
    assert(navigate(L"about:srcdoc", false, false, false) == Decision::allowInWebView);

    assert(navigate(L"https://user@example.com/", false, false, false) == Decision::block);
    assert(navigate(L"https://example.com:65536/", false, false, false) == Decision::block);
    assert(navigate(L"https://example.com:/", false, false, false) == Decision::block);
    assert(navigate(L"https://example..com/", false, false, false) == Decision::block);
    assert(navigate(L"https://999.1.1.1/", false, false, false) == Decision::block);
    assert(navigate(L"https://[:]/", false, false, false) == Decision::block);
    assert(navigate(L"https://[1:2:3:4:5:6:7:8:9]/", false, false, false) == Decision::block);
    assert(navigate(L"https://[1:2:3:4:5:6:7:8:]/", false, false, false) == Decision::block);
    assert(navigate(L"https://example.com\\attack", false, false, false) == Decision::block);
    assert(navigate(L"file:///C:/secret.txt", true, false, true) == Decision::block);
    assert(navigate(L"javascript:alert(1)", true, false, true) == Decision::block);
    assert(navigate(L"data:text/html,hello", true, false, true) == Decision::block);

    assert(navigate(L"mailto:user@example.com", true, false, true) == Decision::openExternal);
    assert(navigate(L"tel:+84123456789", true, false, true) == Decision::openExternal);
    assert(navigate(L"mailto:user@example.com", false, false, true) == Decision::block);
    assert(navigate(L"mailto:user@example.com", true, true, true) == Decision::block);
    assert(navigate(L"mailto:user@example.com", true, false, false) == Decision::block);
    assert(navigate(L"mailto:user@example.com", true, false, true, false) == Decision::block);
    assert(navigate(L"MAILTO:user@example.com", true, false, true) == Decision::openExternal);
    assert(navigate(L"mailto:", true, false, true) == Decision::block);
    assert(navigate(L"mailto:user@example.com%0d%0aBcc:evil@example.com", true, false, true) == Decision::block);
    assert(navigate(L"mailto:user@example.com%ZZ", true, false, true) == Decision::block);
    assert(navigate(L"mailto:\"user\"@example.com", true, false, true) == Decision::block);

    std::wstring overlong(XanhNavigationPolicy::maximumURLCharacters + 1, L'a');
    overlong.replace(0, 8, L"https://");
    assert(navigate(overlong, false, false, false) == Decision::block);
    std::wstring overlongExternal(XanhNavigationPolicy::maximumExternalURLCharacters + 1, L'a');
    overlongExternal.replace(0, 7, L"mailto:");
    assert(navigate(overlongExternal, true, false, true) == Decision::block);
    assert(navigate(L"https://example.com/\nnext", false, false, false) == Decision::block);

    return 0;
}
