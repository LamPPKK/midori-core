#include "XanhFrameStateRestorePolicy.h"

#include <cassert>
#include <vector>

struct FrameState;

struct FrameStateRef {
    FrameState* value;

    FrameState* ptr() const
    {
        return value;
    }
};

struct FrameState {
    bool httpBody { false };
    std::vector<FrameStateRef> children;
};

int main()
{
    FrameState root;
    assert(XanhProcessRecovery::canSafelyRestoreFrameTree(root));

    root.httpBody = true;
    assert(!XanhProcessRecovery::canSafelyRestoreFrameTree(root));
    root.httpBody = false;

    FrameState child;
    root.children.push_back({ &child });
    assert(XanhProcessRecovery::canSafelyRestoreFrameTree(root));
    child.httpBody = true;
    assert(!XanhProcessRecovery::canSafelyRestoreFrameTree(root));

    std::vector<FrameState> boundedTree(XanhProcessRecovery::maximumFrameStatesToInspect + 1);
    for (std::size_t index = 0; index + 1 < boundedTree.size(); ++index)
        boundedTree[index].children.push_back({ &boundedTree[index + 1] });
    assert(!XanhProcessRecovery::canSafelyRestoreFrameTree(boundedTree.front()));
    boundedTree.back().children.clear();
    boundedTree[boundedTree.size() - 2].children.clear();
    assert(XanhProcessRecovery::canSafelyRestoreFrameTree(boundedTree.front()));

    return 0;
}
