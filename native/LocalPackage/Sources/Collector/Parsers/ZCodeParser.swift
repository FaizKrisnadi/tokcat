import DataSource
import Foundation

// ZCode (Z.ai coding agent): one JSONL file per session under
// ~/.zcode/cli/rollout/model-io-*.jsonl. Each line is a completed model
// request with normalized usage at `response.usage` (camelCase):
// inputTokens / outputTokens / totalTokens / cacheReadTokens /
// cacheWriteTokens. `model.modelId` + `model.providerId` name the model,
// `completedAt` is RFC 3339 with fractional seconds, and `requestId` is
// unique per request (usable as a dedup key).

enum ZCodeParser: UsageParser {
    static let clientName = "zcode"

    static func parse(_ cache: UsageCache?) -> [UsageMessage] {
        guard let home = homeDir() else { return [] }
        return parse(cache: cache, home: home)
    }

    /// Testable core: `home` is the agent home (usually ~).
    static func parse(cache: UsageCache?, home: String) -> [UsageMessage] {
        let root = joinPath(joinPath(home, ".zcode"), "cli/rollout")
        let files = collectFiles(root) { path in
            rustExtension(path) == "jsonl" && stringLastPathComponent(path).hasPrefix("model-io-")
        }
        return parseFilesInOrder(files, cache: cache, parseZCodeFile)
    }
}

@Sendable func parseZCodeFile(_ path: String) -> [UsageMessage] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    let fallbackTs = fileModifiedTimestampMs(path)
    var out: [UsageMessage] = []
    forEachJSONLLine(data) { line in
        guard let value = parseTrimmedJSONLine(line) else { return }
        guard let usage = value["response"]?["usage"] else { return }
        guard let model = stringValue(value["model"]?["modelId"]) else { return }
        let tokens = TokenBreakdown(
            input: max(i64Value(usage["inputTokens"]) ?? 0, 0),
            output: max(i64Value(usage["outputTokens"]) ?? 0, 0),
            cacheRead: max(i64Value(usage["cacheReadTokens"]) ?? 0, 0),
            cacheWrite: max(i64Value(usage["cacheWriteTokens"]) ?? 0, 0),
            reasoning: 0
        )
        if tokens.total <= 0 { return }
        let ts = timestampMsFromValue(value["completedAt"]) ?? fallbackTs
        let provider = stringValue(value["model"]?["providerId"]) ?? "z.ai"
        var msg = UsageMessage(
            client: "zcode", modelId: model, providerId: provider,
            timestampMs: ts, tokens: tokens, cost: 0.0
        )
        if let requestId = stringValue(value["requestId"]) {
            msg.dedupKey = "zcode:" + requestId
        }
        out.append(msg)
    }
    return out
}

/// The rollout directory holds only model-io files; the model-io- prefix
/// keeps unrelated future logs out of the scan.
func stringLastPathComponent(_ path: String) -> String {
    (path as NSString).lastPathComponent
}
