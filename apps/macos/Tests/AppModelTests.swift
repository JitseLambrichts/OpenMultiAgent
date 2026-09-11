import Foundation
import Testing
@testable import OpenMultiAgent

@MainActor
struct AppModelTests {
    @Test func refreshingUpdatesThePendingPromotionCount() async {
        let client = AppModelClientStub(pendingCount: 3)
        let model = AppModel(client: client)
        await model.connect()

        await model.refreshPendingPromotionCount()

        #expect(model.pendingPromotionCount == 3)
    }

    @Test func theBackgroundLoopRefreshesWithoutAnExplicitReconcile() async {
        let client = AppModelClientStub(pendingCount: 2)
        let model = AppModel(client: client, pendingPromotionCountInterval: .milliseconds(10))
        await model.connect()

        model.startPendingPromotionCountLoop()
        try? await Task.sleep(for: .milliseconds(40))

        #expect(model.pendingPromotionCount == 2)
    }
}

private actor AppModelClientStub: DesktopAPI {
    let pendingCount: Int

    init(pendingCount: Int = 0) {
        self.pendingCount = pendingCount
    }

    func hello() async throws -> HelloDTO {
        HelloDTO(protocolVersion: 1, appVersion: "test", agents: [])
    }
    func health() async throws -> HealthDTO {
        HealthDTO(ok: true, tmuxAvailable: true)
    }
    func listProjects() async throws -> [ProjectDTO] { [] }
    func addProject(repoPath: String, displayName: String?) async throws -> ProjectDTO {
        throw SidecarClientError.invalidResponse
    }
    func removeProject(id: String) async throws {}

    func pendingPromotionCount() async throws -> PendingPromotionCountDTO {
        PendingPromotionCountDTO(count: pendingCount)
    }
}
