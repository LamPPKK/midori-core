import Foundation
import WebKit

@available(iOS 26.0, macOS 26.0, *)
@MainActor
final class AppleAdblockContentBlocker {
    static let shared = AppleAdblockContentBlocker()

    private static let identifier = "io.github.lamppkk.xanhbrowser.adblock.baseline"

    private var compiledRuleList: WKContentRuleList?
    private var compilationTask: Task<WKContentRuleList?, Never>?
    private var compilationUnavailable = false

    private static func bundledRuleListJSON() -> String? {
        guard let url = Bundle.main.url(
            forResource: "xanh-adblock-baseline",
            withExtension: "json"
        ),
        let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
        !data.isEmpty,
        data.count <= AdblockHostPolicy.maximumCompiledRuleListBytes,
        let value = try? JSONSerialization.jsonObject(with: data),
        let rules = value as? [[String: Any]],
        !rules.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func ruleList() async -> WKContentRuleList? {
        if let compiledRuleList {
            return compiledRuleList
        }
        if compilationUnavailable {
            return nil
        }
        if let compilationTask {
            return await compilationTask.value
        }

        let task: Task<WKContentRuleList?, Never> = Task { @MainActor in
            let json: String?
            if let bundledJSON = Self.bundledRuleListJSON() {
                json = bundledJSON
            } else {
                let candidates = AdblockHostPolicy.nativeLibraryCandidates(
                    resourceURL: Bundle.main.resourceURL,
                    privateFrameworksURL: Bundle.main.privateFrameworksURL,
                    executableURL: Bundle.main.executableURL
                ).map(\.path)
                json = await Task.detached(priority: .utility) {
                    NativeAdblockCompiler.compileDefaultWebKitRuleList(libraryPaths: candidates)
                }.value
            }
            guard let json else { return nil }
            return await withCheckedContinuation { continuation in
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: Self.identifier,
                    encodedContentRuleList: json
                ) { ruleList, _ in
                    continuation.resume(returning: ruleList)
                }
            }
        }
        compilationTask = task
        let result = await task.value
        compilationTask = nil
        if let result {
            compiledRuleList = result
        } else {
            compilationUnavailable = true
        }
        return result
    }
}
