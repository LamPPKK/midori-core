import Foundation

public enum ExternalNavigationPolicy {
    public static func allows(
        url: URL,
        isLinkActivated: Bool,
        sourceIsMainFrame: Bool,
        targetIsMainFrameOrNewWindow: Bool,
        hasTrustedButtonActivation: Bool,
        isContentRuleListRedirect: Bool
    ) -> Bool {
        AddressResolver.isAllowedExternalURL(url)
            && isLinkActivated
            && sourceIsMainFrame
            && targetIsMainFrameOrNewWindow
            && hasTrustedButtonActivation
            && !isContentRuleListRedirect
    }
}
