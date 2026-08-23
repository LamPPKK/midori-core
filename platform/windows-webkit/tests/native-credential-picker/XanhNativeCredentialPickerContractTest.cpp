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

    picker->cancel(nullptr);
    picker->applicationActivationChanged(nullptr, false, nullptr);
    expect(completions == 1,
        "Cancel or deactivation replayed a completed callback.");

    std::cout << "Xanh native credential-picker contract passed "
              << assertions << " assertions\n";
}
