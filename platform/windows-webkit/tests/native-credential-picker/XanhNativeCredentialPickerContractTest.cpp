#include "XanhNativeCredentialPicker.h"

#include <cstdlib>
#include <iostream>

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

} // namespace

int main()
{
    SetEnvironmentVariableW(L"XANH_WINCAIRO_FXA_ACCOUNTS_URL", nullptr);
    SetEnvironmentVariableW(L"XANH_WINCAIRO_FXA_TOKEN_SERVER_URL", nullptr);
    SetEnvironmentVariableW(L"XANH_WINCAIRO_FXA_CLIENT_ID", nullptr);

    auto picker = XanhNativeCredentialPicker::shared();
    auto samePicker = XanhNativeCredentialPicker::shared();
    expect(picker && picker == samePicker,
        "The credential picker was not process-wide.");

    unsigned completions = 0;
    bool returnedCredential = true;
    picker->pick(nullptr, { }, [&](std::optional<XanhCredential> credential) {
        ++completions;
        returnedCredential = credential.has_value();
    });
    expect(completions == 1,
        "The unconfigured picker did not complete exactly once.");
    expect(!returnedCredential,
        "The unconfigured picker returned a credential.");
    expect(!picker->canBeginOAuth(nullptr),
        "The unconfigured picker reported OAuth readiness.");
    expect(!picker->beginOAuth(nullptr),
        "The unconfigured picker started OAuth.");
    expect(!picker->abandonOAuth(nullptr),
        "The unconfigured picker abandoned an OAuth flow.");
    expect(!picker->canHandleOAuthCallback(nullptr),
        "The unconfigured picker claimed an OAuth callback owner.");
    unsigned oauthCompletions = 0;
    expect(!picker->completeOAuth(nullptr,
               L"xanh-browser-wincairo://accounts/oauth?code=a&state=b",
               [&](bool) { ++oauthCompletions; }),
        "The unconfigured picker accepted an OAuth callback.");
    expect(oauthCompletions == 0,
        "A rejected OAuth callback invoked an async completion.");
    unsigned syncCompletions = 0;
    bool syncReturnedStatus = true;
    picker->syncNow(nullptr, [&](auto status) {
        ++syncCompletions;
        syncReturnedStatus = status.has_value();
    });
    expect(syncCompletions == 1 && !syncReturnedStatus,
        "The unconfigured picker started Sync or failed to complete once.");
    expect(!picker->disconnect(false),
        "The unconfigured picker disconnected a nonexistent runtime.");
    expect(!picker->accountState(),
        "The unconfigured picker exposed an account state.");

    picker->cancel(nullptr);
    picker->applicationActivationChanged(nullptr, false, nullptr);
    expect(completions == 1,
        "Cancel or deactivation replayed a completed callback.");

    std::cout << "Xanh native credential-picker contract passed "
              << assertions << " assertions\n";
}
