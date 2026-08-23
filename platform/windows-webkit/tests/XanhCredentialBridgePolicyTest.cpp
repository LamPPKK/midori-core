#include "../src/XanhCredentialBridgePolicy.h"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {

unsigned assertions;

void expect(bool condition, const char* message)
{
    ++assertions;
    if (condition)
        return;
    std::cerr << message << '\n';
    std::exit(1);
}

XanhCredentialBridgePolicy::Request requestFor(const XanhCredentialBridgePolicy::State& state)
{
    return {
        L"credential-request",
        state.tabID(),
        L"0123456789abcdef0123456789abcdef",
        L"fedcba9876543210fedcba9876543210",
        L"https://example.test/login",
        L"https://example.test",
        L"email",
        L"password",
    };
}

std::wstring requestIDFor(unsigned value)
{
    constexpr wchar_t digits[] = L"0123456789abcdef";
    std::wstring result(32, L'0');
    result[30] = digits[(value >> 4) & 0xF];
    result[31] = digits[value & 0xF];
    return result;
}

} // namespace

int main()
{
    using XanhCredentialBridgePolicy::State;

    State state(L"tab_0123456789abcdef", false);
    expect(state.isEnabled(), "Regular bridge state was not enabled.");
    auto request = requestFor(state);
    expect(!state.validate(request, true), "An uncommitted document was accepted.");
    expect(state.navigationFinished(request.documentURL), "A valid HTTPS document was rejected.");
    auto token = state.validate(request, true);
    expect(token.has_value(), "A valid committed request was rejected.");
    expect(state.isCurrent(*token), "A fresh request token was not current.");
    expect(!state.validate(request, true), "A replayed request ID was accepted.");

    auto forged = request;
    forged.requestID = std::wstring(32, L'a');
    forged.claimedOrigin = L"https://evil.test";
    expect(!state.validate(forged, true), "A forged origin was accepted.");
    forged = request;
    forged.requestID = std::wstring(32, L'b');
    forged.claimedOrigin = L"https://example.test/path";
    expect(!state.validate(forged, true), "A path-bearing origin was accepted.");
    forged = request;
    forged.requestID = std::wstring(32, L'c');
    forged.documentURL = L"https://user:secret@example.test/login";
    expect(!state.validate(forged, true), "A credential-bearing URL was accepted.");
    forged = request;
    forged.requestID = std::wstring(32, L'd');
    forged.tabID = L"other-tab";
    expect(!state.validate(forged, true), "A forged tab ID was accepted.");
    forged = request;
    forged.requestID = std::wstring(32, L'e');
    forged.challenge = L"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    expect(!state.validate(forged, true), "A second document challenge was accepted.");
    forged = request;
    forged.requestID = L"not-hex";
    expect(!state.validate(forged, true), "An invalid request ID was accepted.");
    forged = request;
    forged.requestID = std::wstring(32, L'1');
    expect(!state.validate(forged, false), "A subframe request was accepted.");

    state.navigationStarted();
    expect(!state.isCurrent(*token), "A navigation did not invalidate the request token.");
    expect(!state.validate(request, true), "A request was accepted during provisional navigation.");
    expect(state.navigationFinished(L"https://example.test/next"), "A second safe document was rejected.");
    request.documentURL = L"https://example.test/next";
    auto next = state.validate(request, true);
    expect(next.has_value(), "A request after navigation was rejected.");
    state.rendererTerminated();
    expect(!state.isCurrent(*next), "Renderer termination did not invalidate the request.");

    State privateState(L"private-tab", true);
    expect(!privateState.isEnabled(), "Private bridge state was enabled.");
    expect(privateState.navigationFinished(L"https://example.test/login"), "Private state did not track navigation safely.");
    auto privateRequest = requestFor(privateState);
    expect(!privateState.validate(privateRequest, true), "Private credential request was accepted.");

    State invalidTab(L"bad tab", false);
    expect(!invalidTab.isEnabled(), "An invalid native tab ID was enabled.");
    expect(!state.navigationFinished(L"http://example.test/"), "HTTP was accepted for credential access.");
    expect(!state.navigationFinished(L"https://@example.test/"), "Empty userinfo was accepted.");

    expect(XanhCredentialBridgePolicy::canonicalHTTPSOrigin(L"HTTPS://EXAMPLE.TEST:443/login") == std::optional<std::wstring>(L"https://example.test"), "Default HTTPS port was not canonicalized.");
    expect(XanhCredentialBridgePolicy::canonicalHTTPSOrigin(L"https://[2001:db8::1]:8443/login") == std::optional<std::wstring>(L"https://[2001:db8::1]:8443"), "IPv6 origin was not canonicalized.");
    expect(XanhCredentialBridgePolicy::isBoundedText(L"mật-khẩu", XanhCredentialBridgePolicy::maximumFieldUTF8Bytes), "Bounded Unicode field was rejected.");
    expect(!XanhCredentialBridgePolicy::isBoundedText(std::wstring(257, L'a'), XanhCredentialBridgePolicy::maximumFieldUTF8Bytes), "Oversized field was accepted.");
    expect(!XanhCredentialBridgePolicy::isBoundedText(std::wstring(129, L'é'), XanhCredentialBridgePolicy::maximumFieldUTF8Bytes), "Oversized multibyte field was accepted.");
    expect(!XanhCredentialBridgePolicy::isBoundedText(L"bad\nfield", XanhCredentialBridgePolicy::maximumFieldUTF8Bytes), "Control-bearing field was accepted.");

    State boundedState(L"bounded-tab", false);
    auto boundedRequest = requestFor(boundedState);
    expect(boundedState.navigationFinished(boundedRequest.documentURL), "Bounded-request document was rejected.");
    for (unsigned index = 0; index < XanhCredentialBridgePolicy::maximumRequestsPerDocument; ++index) {
        boundedRequest.requestID = requestIDFor(index);
        expect(boundedState.validate(boundedRequest, true).has_value(), "A request inside the per-document cap was rejected.");
    }
    boundedRequest.requestID = requestIDFor(XanhCredentialBridgePolicy::maximumRequestsPerDocument);
    expect(!boundedState.validate(boundedRequest, true), "A request above the per-document cap was accepted.");

    XanhCredentialBridgePolicy::AsyncRequestGate asyncGate;
    auto firstAsync = asyncGate.begin();
    expect(firstAsync.has_value(), "The first asynchronous picker request was rejected.");
    expect(asyncGate.hasActiveRequest(), "The asynchronous picker request was not tracked.");
    expect(!asyncGate.begin(), "A concurrent asynchronous picker request was accepted.");
    expect(asyncGate.finish(*firstAsync), "The live asynchronous picker request was not completed.");
    expect(!asyncGate.finish(*firstAsync), "An asynchronous picker completion was replayed.");
    auto canceledAsync = asyncGate.begin();
    expect(canceledAsync.has_value(), "A request after completion was rejected.");
    asyncGate.cancel();
    expect(!asyncGate.hasActiveRequest(), "Cancellation left an asynchronous picker request active.");
    expect(!asyncGate.finish(*canceledAsync), "A stale completion survived cancellation.");
    auto reopenedAsync = asyncGate.begin();
    expect(reopenedAsync.has_value(), "Cancellation did not reopen the asynchronous picker gate.");
    expect(*reopenedAsync != *canceledAsync, "Cancellation reused a stale asynchronous request token.");

    std::cout << "Xanh WinCairo credential bridge policy passed " << assertions << " assertions\n";
}
