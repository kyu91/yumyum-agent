import Foundation

public protocol HermesConnectionChecking: Sendable {
    func check(executablePath: String) async throws -> String
}

public enum HermesConnectionError: Error, Equatable, LocalizedError, Sendable {
    case pathMustBeAbsolute(String)
    case executableUnavailable(String)
    case timedOut
    case executionFailed(exitStatus: Int32?, standardError: String)
    case emptyVersionOutput
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .pathMustBeAbsolute(path):
            return "Hermes 경로는 `/`로 시작하는 절대 경로여야 합니다: \(path)"
        case let .executableUnavailable(path):
            return "실행 가능한 Hermes 파일을 찾을 수 없습니다: \(path)"
        case .timedOut:
            return "Hermes가 제한 시간 안에 응답하지 않았습니다."
        case let .executionFailed(exitStatus, standardError):
            let status = exitStatus.map(String.init) ?? "알 수 없음"
            let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !detail.isEmpty else {
                return "Hermes --version 실행이 실패했습니다. 종료 코드: \(status)"
            }
            return "Hermes --version 실행이 실패했습니다. 종료 코드: \(status), 오류: \(detail)"
        case .emptyVersionOutput:
            return "Hermes --version이 버전 문자열을 반환하지 않았습니다."
        case let .launchFailed(reason):
            return "Hermes --version을 시작하지 못했습니다: \(reason)"
        }
    }
}

public struct HermesConnectionService: HermesConnectionChecking, Sendable {
    private let locator: HermesExecutableLocator
    private let versionProbe: HermesVersionProbe

    public init(
        locator: HermesExecutableLocator = HermesExecutableLocator(
            allowedPATHDirectories: []
        ),
        processRunner: any ProcessRunning = ProcessRunner(),
        timeout: Duration = .seconds(2)
    ) {
        self.locator = locator
        versionProbe = HermesVersionProbe(processRunner: processRunner, timeout: timeout)
    }

    public func check(executablePath: String) async throws -> String {
        let executableURL: URL
        do {
            executableURL = try locator.locate(
                explicitPath: executablePath,
                pathEnvironment: nil
            )
        } catch let error as HermesExecutableLocationError {
            switch error {
            case let .explicitPathMustBeAbsolute(path):
                throw HermesConnectionError.pathMustBeAbsolute(path)
            case let .notExecutable(path):
                throw HermesConnectionError.executableUnavailable(path)
            case .notFound:
                throw HermesConnectionError.executableUnavailable(executablePath)
            }
        }

        let result: HermesVersionProbeResult
        do {
            result = try await versionProbe.probe(
                executableURL: executableURL,
                environment: AgentProcessEnvironment.make(
                    executableDirectory: executableURL.deletingLastPathComponent()
                ),
                outputByteLimit: 65_536
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HermesConnectionError.launchFailed(String(describing: error))
        }

        if result.timedOut {
            throw HermesConnectionError.timedOut
        }
        guard result.exitStatus == 0 else {
            throw HermesConnectionError.executionFailed(
                exitStatus: result.exitStatus,
                standardError: result.standardError
            )
        }
        guard !result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HermesConnectionError.emptyVersionOutput
        }
        return result.standardOutput
    }
}
