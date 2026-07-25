import Combine
import Foundation

public enum HermesPathStatus: Equatable, Sendable {
    case empty
    case invalidAbsolutePath
    case absolutePathReady
}

public enum HermesConnectionState: Equatable, Sendable {
    case idle
    case loading
    case success(version: String)
    case pathError(message: String)
    case executionError(message: String)
    case timedOut
}

public enum FixtureProbeState: Equatable, Sendable {
    case idle
    case loading
    case success(version: String)
    case failure(message: String)
}

@MainActor
public final class YumYumAppViewModel: ObservableObject {
    @Published public private(set) var connectionState: HermesConnectionState = .idle
    @Published public var hermesPath = "" {
        didSet {
            if hermesPath != oldValue, connectionState != .loading {
                connectionState = .idle
            }
        }
    }
    @Published public private(set) var probeState: FixtureProbeState = .idle

    public let fixturePath: String

    private let fixtureProbe: any FixtureProbing
    private let connectionChecker: any HermesConnectionChecking

    public init(
        fixtureProbe: any FixtureProbing,
        connectionChecker: any HermesConnectionChecking = HermesConnectionService()
    ) {
        self.fixtureProbe = fixtureProbe
        self.connectionChecker = connectionChecker
        fixturePath = fixtureProbe.fixturePath
    }

    public var hermesPathStatus: HermesPathStatus {
        let path = hermesPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return .empty
        }
        guard NSString(string: path).isAbsolutePath else {
            return .invalidAbsolutePath
        }
        return .absolutePathReady
    }

    public var canCheckHermesConnection: Bool {
        hermesPathStatus == .absolutePathReady && connectionState != .loading
    }

    public func checkHermesConnection() async {
        guard canCheckHermesConnection else {
            return
        }

        let executablePath = hermesPath.trimmingCharacters(in: .whitespacesAndNewlines)
        connectionState = .loading
        do {
            let version = try await connectionChecker.check(executablePath: executablePath)
            try Task.checkCancellation()
            connectionState = .success(version: version)
        } catch is CancellationError {
            connectionState = .idle
        } catch let error as HermesConnectionError {
            switch error {
            case .pathMustBeAbsolute, .executableUnavailable:
                connectionState = .pathError(
                    message: error.errorDescription ?? "Hermes 경로를 확인할 수 없습니다."
                )
            case .timedOut:
                connectionState = .timedOut
            case .executionFailed, .emptyVersionOutput, .launchFailed:
                connectionState = .executionError(
                    message: error.errorDescription ?? "Hermes 연결 확인을 완료하지 못했습니다."
                )
            }
        } catch {
            connectionState = .executionError(
                message: "Hermes 연결 확인을 완료하지 못했습니다."
            )
        }
    }

    public func runFixtureProbe() async {
        guard probeState != .loading else {
            return
        }

        probeState = .loading
        do {
            probeState = .success(version: try await fixtureProbe.probe())
        } catch is CancellationError {
            probeState = .idle
        } catch let error as FixtureProbeError {
            probeState = .failure(
                message: error.errorDescription ?? "안전한 fixture probe를 완료하지 못했습니다."
            )
        } catch {
            probeState = .failure(message: "안전한 fixture probe를 완료하지 못했습니다.")
        }
    }
}
