import Combine
import Foundation

public enum HermesPathStatus: Equatable, Sendable {
    case empty
    case invalidAbsolutePath
    case absolutePathNotConnected
}

public enum FixtureProbeState: Equatable, Sendable {
    case idle
    case loading
    case success(version: String)
    case failure(message: String)
}

@MainActor
public final class YumYumAppViewModel: ObservableObject {
    @Published public var hermesPath = ""
    @Published public private(set) var probeState: FixtureProbeState = .idle

    public let fixturePath: String

    private let fixtureProbe: any FixtureProbing

    public init(fixtureProbe: any FixtureProbing) {
        self.fixtureProbe = fixtureProbe
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
        return .absolutePathNotConnected
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
