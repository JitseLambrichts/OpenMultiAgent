import Foundation
import Testing
@testable import OpenMultiAgent

struct SidecarClientTests {
    @Test func lineBufferHandlesSplitAndMultipleMessages() {
        var buffer = RPCLineBuffer()

        #expect(buffer.append(Data(#"{"id":1"#.utf8)).isEmpty)
        let messages = buffer.append(Data("}\n\n{\"id\":2}\npartial".utf8))

        #expect(messages.map { String(decoding: $0, as: UTF8.self) } == [
            #"{"id":1}"#,
            #"{"id":2}"#,
        ])
        #expect(String(decoding: buffer.flush()!, as: UTF8.self) == "partial")
    }

    @Test func requestEncoderUsesJSONRPCWireShape() throws {
        let data = try RPCRequest.encode(
            id: 17,
            method: "project.detail",
            params: ["project_id": .string("project-1")]
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let params = try #require(object["params"] as? [String: Any])

        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] as? Int == 17)
        #expect(object["method"] as? String == "project.detail")
        #expect(params["project_id"] as? String == "project-1")
        #expect(data.last == Character("\n").asciiValue)
    }

    @Test func clientCorrelatesAProcessResponse() async throws {
        let script = """
        IFS= read -r request
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocol_version":1,"app_version":"test","agents":["claude","codex"]}}'
        IFS= read -r shutdown
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"shutting_down":true}}'
        """
        let configuration = SidecarConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            workspaceRoot: URL(fileURLWithPath: "/"),
            source: .environment
        )
        let client = SidecarClient(configuration: configuration)

        let hello = try await client.hello()

        #expect(hello.protocolVersion == 1)
        #expect(hello.appVersion == "test")
        #expect(hello.agents == ["claude", "codex"])
        await client.shutdown()
    }
}

extension SidecarClientTests {
    /// End-to-end against a real Bun process: proves the socket-pair stdin keeps
    /// the request/response loop interactive (a pipe stalls on Bun 1.2).
    @Test func clientTalksToABunSidecarWhileStdinStaysOpen() async throws {
        let bun = ["/opt/homebrew/bin/bun", "\(NSHomeDirectory())/.bun/bin/bun", "/usr/local/bin/bun"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let bun else { return }
        let fixture = try #require(
            Bundle(for: SidecarTestBundleAnchor.self).url(forResource: "fixture-sidecar", withExtension: "ts"),
            "fixture-sidecar.ts missing from test bundle"
        )
        let client = SidecarClient(configuration: SidecarConfiguration(
            executableURL: URL(fileURLWithPath: bun),
            arguments: ["run", fixture.path],
            workspaceRoot: fixture.deletingLastPathComponent(),
            source: .environment
        ))

        let hello = try await withTimeout(seconds: 8) { try await client.hello() }
        #expect(hello.appVersion == "fixture")
        let projects = try await withTimeout(seconds: 8) { try await client.listProjects() }
        #expect(projects.first?.displayName == "OpenMultiAgent")
        await client.shutdown()
    }
}

private func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw SidecarClientError.disconnected("timed out after \(seconds)s")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private final class SidecarTestBundleAnchor {}
