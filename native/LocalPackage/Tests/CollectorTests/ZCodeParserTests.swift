import DataSource
import Foundation
import Testing

@testable import Collector

// ZCode (Z.ai coding agent): model-io JSONL parsing. One file per session
// under ~/.zcode/cli/rollout, usage at response.usage in camelCase.

private func zcodeTempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "tokcat-zcode-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(nowMs())-\(UInt32.random(in: 0..<UInt32.max))"
        )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeZCodeRollout(home: URL, lines: [String], session: String = "session_abc") throws -> URL {
    let dir = home
        .appendingPathComponent(".zcode")
        .appendingPathComponent("cli")
        .appendingPathComponent("rollout")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("model-io-\(session).jsonl")
    try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

private func zcodeRequestLine(
    requestId: String,
    model: String = "GLM-5.3-Flash",
    provider: String = "account:zai-start-plan",
    completedAt: String = "2026-10-29T14:02:43.013Z",
    input: Int64 = 317_842,
    output: Int64 = 1_127,
    total: Int64 = 318_969,
    cacheRead: Int64 = 316_288,
    cacheWrite: Int64 = 0
) -> String {
    """
        {"type":"model_io","sessionId":"sess_abc","requestId":"\(requestId)","attempt":1,\
        "startedAt":"2026-10-29T14:02:11.123Z","completedAt":"\(completedAt)","durationMs":32546,\
        "model":{"modelId":"\(model)","providerId":"\(provider)"},\
        "request":{"body":{"model":"\(model)","max_tokens":128000}},\
        "response":{"usage":{"inputTokens":\(input),"outputTokens":\(output),\
        "totalTokens":\(total),"cacheReadTokens":\(cacheRead),"cacheWriteTokens":\(cacheWrite)}}}
        """
}

@Suite struct ZCodeParserTests {
    @Test func parsesNormalizedUsageWithModelAndProvider() throws {
        let home = try zcodeTempDir("basic")
        defer { try? FileManager.default.removeItem(at: home) }
        try writeZCodeRollout(home: home, lines: [
            zcodeRequestLine(requestId: "req-1"),
        ])

        let messages = ZCodeParser.parse(cache: nil, home: home.path)
        #expect(messages.count == 1)
        let msg = try #require(messages.first)
        #expect(msg.client == "zcode")
        #expect(msg.modelId == "GLM-5.3-Flash")
        #expect(msg.providerId == "account:zai-start-plan")
        // RFC 3339 with fractional seconds: 2026-10-29T14:02:43.013Z
        #expect(msg.timestampMs == 1_793_340_163_013)
        #expect(msg.tokens.input == 317_842)
        #expect(msg.tokens.output == 1_127)
        #expect(msg.tokens.cacheRead == 316_288)
        #expect(msg.tokens.cacheWrite == 0)
        #expect(msg.dedupKey == "zcode:req-1")
    }

    @Test func skipsLinesWithoutUsageOrModel() throws {
        let home = try zcodeTempDir("skip")
        defer { try? FileManager.default.removeItem(at: home) }
        try writeZCodeRollout(home: home, lines: [
            #"{"type":"model_io","requestId":"no-usage","completedAt":"2026-10-29T14:02:43.013Z"}"#,
            #"{"type":"model_io","response":{"usage":{"inputTokens":10,"outputTokens":1,"totalTokens":11,"cacheReadTokens":0,"cacheWriteTokens":0}}}"#,
            #"{"not json at all"{"broken"#,
        ])

        let messages = ZCodeParser.parse(cache: nil, home: home.path)
        #expect(messages.isEmpty)
    }

    @Test func aggregatesAcrossSessionFiles() throws {
        let home = try zcodeTempDir("multi")
        defer { try? FileManager.default.removeItem(at: home) }
        try writeZCodeRollout(home: home, session: "session_a", lines: [
            zcodeRequestLine(requestId: "a-1", input: 100, output: 10, total: 110, cacheRead: 0),
        ])
        try writeZCodeRollout(home: home, session: "session_b", lines: [
            zcodeRequestLine(requestId: "b-1", input: 200, output: 20, total: 220, cacheRead: 50),
        ])

        let messages = ZCodeParser.parse(cache: nil, home: home.path)
        #expect(messages.count == 2)
        #expect(messages.reduce(0) { $0 + $1.tokens.input } == 300)
        #expect(messages.reduce(0) { $0 + $1.tokens.output } == 30)
    }

    @Test func registryIncludesZCode() {
        #expect(UsageGraph.registry.contains { $0.name == "zcode" })
    }
}
