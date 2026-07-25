import Foundation
import Testing
@testable import YumYumCore

@Suite
struct AppShellViewModelTests {
    @Test
    @MainActor
    func startsWithAnEmptyUnsavedPathAndEnablesOnlyAnAbsolutePath() {
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("Hermes Fixture 0.0.0"))
        )

        #expect(viewModel.probeState == .idle)
        #expect(viewModel.connectionState == .idle)
        #expect(viewModel.hermesPath.isEmpty)
        #expect(viewModel.hermesPathStatus == .empty)
        #expect(!viewModel.canCheckHermesConnection)

        viewModel.hermesPath = "bin/hermes"
        #expect(viewModel.hermesPathStatus == .invalidAbsolutePath)
        #expect(!viewModel.canCheckHermesConnection)

        viewModel.hermesPath = "/opt/homebrew/bin/hermes"
        #expect(viewModel.hermesPathStatus == .absolutePathReady)
        #expect(viewModel.canCheckHermesConnection)
    }

    @Test
    @MainActor
    func reportsLoadingThenOriginalVersionOutputFromTheSelectedPath() async throws {
        let checker = ControlledHermesConnectionChecker()
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            connectionChecker: checker
        )
        viewModel.hermesPath = "  /custom/hermes  "

        let checkTask = Task { @MainActor in
            await viewModel.checkHermesConnection()
        }
        while !(await checker.hasStarted()) {
            await Task.yield()
        }

        #expect(viewModel.connectionState == .loading)
        #expect(!viewModel.canCheckHermesConnection)
        #expect(await checker.requestedPaths == ["/custom/hermes"])
        await checker.complete(returning: "Hermes 1.2.3\nbuild abc\n")
        await checkTask.value

        #expect(
            viewModel.connectionState
                == .success(version: "Hermes 1.2.3\nbuild abc\n")
        )
        #expect(viewModel.probeState == .idle)
    }

    @Test
    @MainActor
    func doesNotCheckAnInvalidPath() async {
        let checker = CountingHermesConnectionChecker()
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            connectionChecker: checker
        )
        viewModel.hermesPath = "bin/hermes"

        await viewModel.checkHermesConnection()

        #expect(viewModel.connectionState == .idle)
        #expect(await checker.callCount == 0)
    }

    @Test
    @MainActor
    func editingThePathClearsThePreviousConnectionResult() async {
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            connectionChecker: ImmediateHermesConnectionChecker(
                result: .success("Hermes 1.2.3\n")
            )
        )
        viewModel.hermesPath = "/first/hermes"
        await viewModel.checkHermesConnection()
        #expect(viewModel.connectionState == .success(version: "Hermes 1.2.3\n"))

        viewModel.hermesPath = "/second/hermes"

        #expect(viewModel.connectionState == .idle)
    }

    @Test(arguments: [
        (
            HermesConnectionError.pathMustBeAbsolute("bin/hermes"),
            HermesConnectionState.pathError(
                message: HermesConnectionError.pathMustBeAbsolute("bin/hermes")
                    .errorDescription!
            )
        ),
        (
            HermesConnectionError.executableUnavailable("/missing/hermes"),
            HermesConnectionState.pathError(
                message: HermesConnectionError.executableUnavailable("/missing/hermes")
                    .errorDescription!
            )
        ),
        (
            HermesConnectionError.executionFailed(
                exitStatus: 23,
                standardError: "permission denied\n"
            ),
            HermesConnectionState.executionError(
                message: HermesConnectionError.executionFailed(
                    exitStatus: 23,
                    standardError: "permission denied\n"
                ).errorDescription!
            )
        ),
        (
            HermesConnectionError.emptyVersionOutput,
            HermesConnectionState.executionError(
                message: HermesConnectionError.emptyVersionOutput.errorDescription!
            )
        ),
    ])
    @MainActor
    func mapsPathAndExecutionErrorsToDistinctStates(
        error: HermesConnectionError,
        expectedState: HermesConnectionState
    ) async {
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            connectionChecker: ImmediateHermesConnectionChecker(result: .failure(error))
        )
        viewModel.hermesPath = "/selected/hermes"

        await viewModel.checkHermesConnection()

        #expect(viewModel.connectionState == expectedState)
    }

    @Test
    @MainActor
    func reportsTimeoutSeparately() async {
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            connectionChecker: ImmediateHermesConnectionChecker(result: .failure(.timedOut))
        )
        viewModel.hermesPath = "/selected/hermes"

        await viewModel.checkHermesConnection()

        #expect(viewModel.connectionState == .timedOut)
    }

    @Test
    @MainActor
    func cancellationReturnsToIdle() async {
        let checker = CancellableHermesConnectionChecker()
        let viewModel = YumYumAppViewModel(
            fixtureProbe: ImmediateFixtureProbe(result: .success("unused")),
            connectionChecker: checker
        )
        viewModel.hermesPath = "/selected/hermes"
        let task = Task { @MainActor in
            await viewModel.checkHermesConnection()
        }
        while !(await checker.hasStarted) {
            await Task.yield()
        }

        task.cancel()
        await task.value

        #expect(viewModel.connectionState == .idle)
        #expect(await checker.wasCancelled)
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

private struct ImmediateHermesConnectionChecker: HermesConnectionChecking {
    let result: Result<String, HermesConnectionError>

    func check(executablePath: String) async throws -> String {
        try result.get()
    }
}

private actor CountingHermesConnectionChecker: HermesConnectionChecking {
    private(set) var callCount = 0

    func check(executablePath: String) async throws -> String {
        callCount += 1
        return "unused"
    }
}

private actor ControlledHermesConnectionChecker: HermesConnectionChecking {
    private(set) var requestedPaths: [String] = []
    private var continuation: CheckedContinuation<String, any Error>?

    func check(executablePath: String) async throws -> String {
        requestedPaths.append(executablePath)
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

private actor CancellableHermesConnectionChecker: HermesConnectionChecking {
    private(set) var hasStarted = false
    private(set) var wasCancelled = false

    func check(executablePath: String) async throws -> String {
        hasStarted = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
        return "unused"
    }
}
