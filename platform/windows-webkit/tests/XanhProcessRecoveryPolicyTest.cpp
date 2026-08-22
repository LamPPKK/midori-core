#include "XanhProcessRecoveryPolicy.h"

#include <cassert>

using XanhProcessRecovery::Action;
using XanhProcessRecovery::Policy;
using XanhProcessRecovery::State;

int main()
{
    Policy policy;
    assert(policy.state() == State::available);

    assert(policy.processTerminated(false, true) == Action::restorePage);
    assert(policy.state() == State::recoveryLoading);
    assert(policy.processTerminated(false, true) == Action::stopAutomaticRecovery);
    assert(policy.state() == State::exhausted);

    policy.navigationFinished();
    assert(policy.state() == State::exhausted);
    assert(policy.processTerminated(false, true) == Action::stopAutomaticRecovery);

    policy.userRequestedNavigation();
    assert(policy.state() == State::available);
    assert(policy.processTerminated(false, true) == Action::restorePage);
    assert(policy.state() == State::recoveryLoading);
    policy.navigationFinished();
    assert(policy.state() == State::exhausted);
    assert(policy.processTerminated(false, true) == Action::stopAutomaticRecovery);

    assert(policy.processTerminated(true, true) == Action::ignoreRequestedTermination);
    assert(policy.state() == State::exhausted);
    policy.userRequestedNavigation();
    assert(policy.processTerminated(true, true) == Action::ignoreRequestedTermination);
    assert(policy.state() == State::available);

    policy.navigationFinished();
    assert(policy.state() == State::available);

    assert(policy.processTerminated(false, false) == Action::refuseUnsafeRestore);
    assert(policy.state() == State::exhausted);
    assert(policy.processTerminated(false, true) == Action::stopAutomaticRecovery);
    policy.userRequestedNavigation();
    assert(policy.processTerminated(true, false) == Action::ignoreRequestedTermination);
    assert(policy.state() == State::available);

    return 0;
}
