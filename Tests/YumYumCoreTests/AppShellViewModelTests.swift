import Foundation
import Testing
@testable import YumYumCore

@Suite
struct AppShellViewModelTests {
    @Test
    @MainActor
    func startsFailClosedAndOnlyRecognizesAbsolutePathSyntax() {
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("Hermes Fixture 0.0.0"))
        )

        #expect(viewModel.probeState == .idle)
        #expect(viewModel.hermesPathStatus == .empty)

        viewModel.hermesPath = "bin/hermes"
        #expect(viewModel.hermesPathStatus == .invalidAbsolutePath)

        viewModel.hermesPath = "/opt/homebrew/bin/hermes"
        #expect(viewModel.hermesPathStatus == .absolutePathNotConnected)
    }

    @Test
    @MainActor
    func reportsLoadingThenFixtureSuccessWithoutUsingTheHermesPath() async {
        let probe = ControlledFixtureProbe()
        let viewModel = YumYumAppViewModel(fixtureProbe: probe)
        viewModel.hermesPath = "/do/not/run/hermes"

        let probeTask = Task { @MainActor in
            await viewModel.runFixtureProbe()
        }
        while !(await probe.hasStarted()) {
            await Task.yield()
        }

        #expect(viewModel.probeState == .loading)
        await probe.complete(returning: "Hermes Fixture 0.0.0")
        await probeTask.value

        #expect(viewModel.probeState == .success(version: "Hermes Fixture 0.0.0"))
        #expect(viewModel.hermesPath == "/do/not/run/hermes")
        #expect(await probe.callCount == 1)
    }

    @Test
    @MainActor
    func presentsAStableFixtureError() async {
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .failure(.timedOut))
        )

        await viewModel.runFixtureProbe()

        #expect(
            viewModel.probeState
                == .failure(message: "안전한 fixture가 제한 시간 안에 응답하지 않았습니다.")
        )
    }
}

private struct ImmediateFixtureProbe: FixtureProbing {
    let fixturePath = "/test/yumyum-process-fixture"
    let result: Result<String, FixtureProbeError>

    func probe() async throws -> String {
        try result.get()
    }
}

private actor ControlledFixtureProbe: FixtureProbing {
    nonisolated let fixturePath = "/test/yumyum-process-fixture"
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<String, any Error>?

    func probe() async throws -> String {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        continuation != nil
    }

    func complete(returning version: String) {
        continuation?.resume(returning: version)
        continuation = nil
    }
}
