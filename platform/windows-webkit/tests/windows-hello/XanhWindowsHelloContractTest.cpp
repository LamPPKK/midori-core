#include "XanhWindowsHello.h"

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
    XanhWindowsHello verifier(nullptr);
    unsigned completions = 0;
    bool verified = true;
    verifier.verify(L"Unlock Xanh Browser passwords", [&](bool value) {
        ++completions;
        verified = value;
    });
    expect(completions == 1, "An invalid owner HWND did not complete exactly once.");
    expect(!verified, "An invalid owner HWND did not fail closed.");

    verifier.cancel();
    verifier.cancel();
    expect(completions == 1, "Cancel replayed a completed verification callback.");

    bool throwingCompletionRan = false;
    verifier.verify(L"Unlock Xanh Browser passwords", [&](bool) {
        throwingCompletionRan = true;
        throw 1;
    });
    expect(throwingCompletionRan, "The invalid-window denial callback did not run.");

    std::cout << "Xanh Windows Hello contract passed " << assertions << " assertions\n";
}
