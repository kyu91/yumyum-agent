import Foundation

public protocol FixtureProbing: Sendable {
    var fixturePath: String { get }

    func probe() async throws -> String
}

public enum FixtureProbeError: Error, Equatable, LocalizedError, Sendable {
    case unsafeFixturePath(String)
    case fixtureUnavailable(String)
    case timedOut
    case failed(exitStatus: Int32?, standardError: String)
    case emptyVersionOutput
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsafeFixturePath(path):
            return AppText.localized(english: "Fixture path is not allowed: \(path)", korean: "허용되지 않은 fixture 경로입니다: \(path)")
        case let .fixtureUnavailable(path):
            return AppText.localized(english: "Safe fixture executable not found: \(path)", korean: "안전한 fixture 실행 파일을 찾을 수 없습니다: \(path)")
        case .timedOut:
            return AppText.localized("안전한 fixture가 제한 시간 안에 응답하지 않았습니다.")
        case let .failed(exitStatus, standardError):
            let status = exitStatus.map(String.init) ?? AppText.localized("알 수 없음")
            if standardError.isEmpty {
                return AppText.localized(english: "Safe fixture execution failed. Exit code: \(status)", korean: "안전한 fixture 실행이 실패했습니다. 종료 코드: \(status)")
            }
            return AppText.localized(english: "Safe fixture execution failed. Exit code: \(status), error: \(standardError)", korean: "안전한 fixture 실행이 실패했습니다. 종료 코드: \(status), 오류: \(standardError)")
        case .emptyVersionOutput:
            return AppText.localized("안전한 fixture가 버전 문자열을 반환하지 않았습니다.")
        case let .launchFailed(reason):
            return AppText.localized(english: "Could not start the safe fixture: \(reason)", korean: "안전한 fixture를 시작하지 못했습니다: \(reason)")
        }
    }
}

public struct FixtureProbeService: FixtureProbing, Sendable {
    public static let fixtureExecutableName = "yumyum-process-fixture"

    private let fixtureURL: URL
    private let processRunner: any ProcessRunning
    private let timeout: Duration

    public var fixturePath: String {
        fixtureURL.standardizedFileURL.path
    }

    public init(
        fixtureURL: URL,
        processRunner: any ProcessRunning = ProcessRunner(),
        timeout: Duration = .seconds(2)
    ) {
        self.fixtureURL = fixtureURL
        self.processRunner = processRunner
        self.timeout = timeout
    }

    public func probe() async throws -> String {
        let fixtureURL = fixtureURL.standardizedFileURL
        guard fixtureURL.lastPathComponent == Self.fixtureExecutableName else {
            throw FixtureProbeError.unsafeFixturePath(fixtureURL.path)
        }

        let executableURL: URL
        do {
            executableURL = try HermesExecutableLocator(allowedPATHDirectories: []).locate(
                explicitPath: fixtureURL.path,
                pathEnvironment: nil
            )
        } catch {
            throw FixtureProbeError.fixtureUnavailable(fixtureURL.path)
        }

        let result: HermesVersionProbeResult
        do {
            result = try await HermesVersionProbe(
                processRunner: processRunner,
                timeout: timeout
            ).probe(executableURL: executableURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FixtureProbeError.launchFailed(String(describing: error))
        }

        if result.timedOut {
            throw FixtureProbeError.timedOut
        }
        let standardError = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitStatus == 0 else {
            throw FixtureProbeError.failed(
                exitStatus: result.exitStatus,
                standardError: standardError
            )
        }

        let version = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw FixtureProbeError.emptyVersionOutput
        }
        return version
    }
}
