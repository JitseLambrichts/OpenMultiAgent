import Foundation
import Testing
@testable import OpenMultiAgent

struct DTOContractTests {
    @Test func decodesProjectListContract() throws {
        let envelope: RPCResponse<[ProjectDTO]> = try fixture("project-list")

        #expect(envelope.result?.first?.displayName == "OpenMultiAgent")
        #expect(envelope.result?.first?.repoPath == "/Users/example/OpenMultiAgent")
    }

    @Test func decodesSessionStatusContract() throws {
        let envelope: RPCResponse<SessionStatusDTO> = try fixture("session-status")

        #expect(envelope.result?.session.title == "Build M4")
        #expect(envelope.result?.tmuxAlive == true)
        #expect(envelope.result?.changedFiles.first?.path == "README.md")
        #expect(envelope.result?.session.usesWorktree == true)
    }

    @Test func decodesSessionListContract() throws {
        let envelope: RPCResponse<[SessionViewDTO]> = try fixture("session-list")
        let sessions = try #require(envelope.result)

        #expect(sessions.map(\.id) == ["session-1", "session-2"])
        #expect(sessions[0].currentAgent == .claude)
        #expect(sessions[1].currentAgent == nil)
        #expect(sessions[1].session.displayTitle == "Naamloze sessie")
        #expect(sessions[1].session.isActive == false)
    }

    @Test func decodesTranscriptPageContract() throws {
        let envelope: RPCResponse<TranscriptPageDTO> = try fixture("transcript-page")

        #expect(envelope.result?.items.first?.identity == "run-1:1")
        #expect(envelope.result?.nextCursor == "WyJydW4tMSIsMV0")
    }

    @Test func decodesMemoryListContract() throws {
        let envelope: RPCResponse<[MemoryDTO]> = try fixture("memory-list")
        let memories = try #require(envelope.result)

        #expect(memories.map(\.kind) == [.decision, .invariant])
        #expect(memories[1].repoPath == nil)
        #expect(memories[0].confidence == 0.94)
    }

    @Test func decodesMixedSearchHits() throws {
        let envelope: RPCResponse<[SearchHitDTO]> = try fixture("search-hits")
        let hits = try #require(envelope.result)

        #expect(hits.count == 2)
        guard case .memory(let memory) = hits[0], case .event(let event) = hits[1] else {
            Issue.record("expected a memory hit followed by an event hit")
            return
        }
        #expect(memory.title == "Use native SwiftUI")
        #expect(event.sessionID == "session-1")
        #expect(hits.map(\.id) == ["memory:memory-1", "event:event-9"])
    }

    @Test func decodesDocsAndPromotionContracts() throws {
        let docs: RPCResponse<[LivingDocDTO]> = try fixture("docs-list")
        let preview: RPCResponse<PromotionPreviewDTO> = try fixture("promotion-preview")

        #expect(docs.result?.map(\.kind) == [.decision, .howto])
        #expect(preview.result?.candidateCount == 1)
        #expect(preview.result?.diff.contains("+++ .oma/docs/decisions.md") == true)
    }

    @Test func rpcErrorPreservesRecoveryCode() throws {
        let envelope: RPCResponse<EmptyResult> = try fixture("rpc-error")

        #expect(envelope.error?.code == -32002)
        #expect(envelope.error?.recovery == "install_tmux")
        #expect(envelope.error?.recoveryAction == .installTmux)
    }

    @Test func conflictErrorMapsToKeepWorktreeRecoveryWithoutParsingText() throws {
        let envelope: RPCResponse<EmptyResult> = try fixture("rpc-error-conflict")
        let error = try #require(envelope.error)

        #expect(error.recoveryAction == .keepWorktreeOrForce)
        #expect(error.detail?.contains("use --force") == true)
        #expect(RPCErrorDTO(code: -32004, message: "Not found").recoveryAction == .refresh)
        #expect(RPCErrorDTO(code: -32001, message: "Bad path").recoveryAction == .chooseAnotherFolder)
    }

    @Test func sidecarConfigurationPrefersEnvironmentThenBundleThenCheckout() {
        let fromEnvironment = SidecarConfiguration.resolve(
            environment: [
                SidecarConfiguration.environmentExecutableKey: "/usr/bin/env",
                SidecarConfiguration.environmentArgumentsKey: "bun\u{1F}run\u{1F}fixture.ts",
            ],
            bundle: Bundle(for: BundleAnchor.self)
        )
        #expect(fromEnvironment.source == .environment)
        #expect(fromEnvironment.arguments == ["bun", "run", "fixture.ts"])

        let fallback = SidecarConfiguration.resolve(
            environment: [:],
            bundle: Bundle(for: BundleAnchor.self),
            fileExists: { _ in false }
        )
        #expect(fallback.source == .development)
        #expect(fallback.arguments.last == "packages/desktop-api/src/index.ts")
        #expect(SidecarConfiguration.bunExecutable(environment: ["PATH": "/x/bin:/y/bin"], fileExists: { $0 == "/y/bin/bun" }) == "/y/bin/bun")
        #expect(SidecarConfiguration.bunExecutable(environment: [:], fileExists: { _ in false }) == "/usr/bin/env")
    }

    @Test func sidecarEnvironmentDropsLoaderAndTestInstrumentation() throws {
        let filtered = SidecarClient.childEnvironment(from: [
            "PATH": "/usr/bin",
            "OMA_HOME": "/tmp/oma",
            "DYLD_INSERT_LIBRARIES": "/x/libXCTestBundleInject.dylib",
            "XCTestConfigurationFilePath": "/x/config",
            "XCInjectBundleInto": "/x/app",
        ])
        #expect(filtered["OMA_HOME"] == "/tmp/oma")
        #expect(filtered["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(filtered["XCTestConfigurationFilePath"] == nil)
        let path = try #require(filtered["PATH"]).split(separator: ":").map(String.init)
        #expect(path.first == "/usr/bin")
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(Set(path).count == path.count, "PATH entries are deduplicated")
    }

    @Test func sidecarEnvironmentAppendsLoginShellPathAfterInherited() throws {
        let filtered = SidecarClient.childEnvironment(
            from: ["PATH": "/usr/bin:/bin"],
            loginShellPath: "/opt/homebrew/bin:/Users/me/.nvm/versions/node/v24/bin:/usr/bin",
            home: "/Users/me"
        )
        let path = try #require(filtered["PATH"]).split(separator: ":").map(String.init)
        #expect(path.prefix(4) == ["/usr/bin", "/bin", "/opt/homebrew/bin", "/Users/me/.nvm/versions/node/v24/bin"])
        #expect(path.contains("/Users/me/.bun/bin"))
    }
}

private final class BundleAnchor {}

/// Contract fixtures are copied into the test bundle by XcodeGen (see
/// project.yml); reading them from the checkout would block on a TCC prompt.
private func fixture<Result: Decodable & Sendable>(_ name: String) throws -> RPCResponse<Result> {
    let bundle = Bundle(for: BundleAnchor.self)
    let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "contracts")
        ?? bundle.url(forResource: name, withExtension: "json")
    let data = try Data(contentsOf: try #require(url, "fixture \(name).json missing from test bundle"))
    return try JSONDecoder.oma.decode(RPCResponse<Result>.self, from: data)
}
