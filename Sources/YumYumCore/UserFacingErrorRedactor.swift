import Foundation

public enum UserFacingErrorCategory: CaseIterable, Equatable, Sendable {
    case blankInput
    case invalidFile
    case blockedCredential
    case agentNotSelected
    case agentUnavailable
    case agentTimedOut
    case agentFailure
    case busy
    case capturePermission
    case captureFailure
    case cancelled
    case processingFailure

    public var message: String {
        switch self {
        case .blankInput:
            "대화 내용을 입력하거나 파일을 선택하세요."
        case .invalidFile:
            "선택한 파일을 사용할 수 없습니다. 파일 형식과 크기를 확인해 주세요."
        case .blockedCredential:
            "보안 또는 자격증명 파일은 첨부할 수 없습니다."
        case .agentNotSelected:
            "기본 에이전트를 먼저 선택하세요."
        case .agentUnavailable:
            "선택한 에이전트를 사용할 수 없어 명시적으로 다시 선택해야 합니다."
        case .agentTimedOut:
            "에이전트 응답 시간이 초과되었습니다. 다시 시도해 주세요."
        case .agentFailure:
            "에이전트가 요청을 처리하지 못했습니다. 다시 시도해 주세요."
        case .busy:
            "이미 다른 입력을 처리하고 있습니다."
        case .capturePermission:
            "화면 캡처 권한이 필요합니다."
        case .captureFailure:
            "화면을 캡처하지 못했습니다. 다시 시도해 주세요."
        case .cancelled:
            "입력 처리를 취소했습니다."
        case .processingFailure:
            "입력을 처리하지 못했습니다. 다시 시도해 주세요."
        }
    }
}

public enum UserFacingErrorRedactor {
    public static func message(for error: any Error) -> String {
        if error is CancellationError {
            return UserFacingErrorCategory.cancelled.message
        }
        switch error {
        case let error as FeedValidationError:
            return validationCategory(for: error).message
        case let error as ChatBubbleStateError:
            switch error {
            case .blankDraft:
                return UserFacingErrorCategory.blankInput.message
            case .busy:
                return UserFacingErrorCategory.busy.message
            }
        case let error as AgentSelectionError:
            switch error {
            case .noSelection:
                return UserFacingErrorCategory.agentNotSelected.message
            case .unavailable, .explicitReselectionRequired:
                return UserFacingErrorCategory.agentUnavailable.message
            }
        case let error as AgentConnectorError:
            if case .timedOut = error {
                return UserFacingErrorCategory.agentTimedOut.message
            }
            return UserFacingErrorCategory.agentFailure.message
        case is AgentRuntimeError:
            return UserFacingErrorCategory.agentUnavailable.message
        case is FeedWorkflowError:
            return UserFacingErrorCategory.busy.message
        default:
            return UserFacingErrorCategory.processingFailure.message
        }
    }

    public static func sanitize(
        _ text: String,
        fallback: UserFacingErrorCategory = .processingFailure
    ) -> String {
        let safeMessages = Set(UserFacingErrorCategory.allCases.map(\.message))
        return safeMessages.contains(text) ? text : fallback.message
    }

    private static func validationCategory(
        for error: FeedValidationError
    ) -> UserFacingErrorCategory {
        switch error {
        case .blankInput:
            .blankInput
        case .credentialFileBlocked:
            .blockedCredential
        case .pathMustBeAbsolute,
             .unavailableFile,
             .unsupportedFile,
             .oversizedFile:
            .invalidFile
        }
    }
}
