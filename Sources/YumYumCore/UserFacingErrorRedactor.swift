import Foundation

public enum UserFacingErrorCategory: CaseIterable, Equatable, Sendable {
    case blankInput
    case invalidFile
    case blockedCredential
    case agentNotSelected
    case agentUnavailable
    case agentTimedOut
    case agentFailure
    case codexAuthenticationRequired
    case busy
    case capturePermission
    case captureFailure
    case cancelled
    case processingFailure

    public var message: String {
        message(language: AppText.language)
    }

    public func message(language: AppLanguage) -> String {
        switch self {
        case .blankInput:
            AppText.localized(english: "Type a message or choose a file.", korean: "대화 내용을 입력하거나 파일을 선택하세요.", language: language)
        case .invalidFile:
            AppText.localized(english: "The selected file cannot be used. Check its type and size.", korean: "선택한 파일을 사용할 수 없습니다. 파일 형식과 크기를 확인해 주세요.", language: language)
        case .blockedCredential:
            AppText.localized(english: "Security or credential files cannot be attached.", korean: "보안 또는 자격증명 파일은 첨부할 수 없습니다.", language: language)
        case .agentNotSelected:
            AppText.localized(english: "Select a default agent first.", korean: "기본 에이전트를 먼저 선택하세요.", language: language)
        case .agentUnavailable:
            AppText.localized(english: "The selected agent is unavailable and must be explicitly reselected.", korean: "선택한 에이전트를 사용할 수 없어 명시적으로 다시 선택해야 합니다.", language: language)
        case .agentTimedOut:
            AppText.localized(english: "The agent response timed out. Try again.", korean: "에이전트 응답 시간이 초과되었습니다. 다시 시도해 주세요.", language: language)
        case .agentFailure:
            AppText.localized(english: "The agent could not process the request. Try again.", korean: "에이전트가 요청을 처리하지 못했습니다. 다시 시도해 주세요.", language: language)
        case .codexAuthenticationRequired:
            AppText.localized(english: "ChatGPT sign-in expired. Sign in again, then retry when ready.", korean: "ChatGPT 로그인이 만료되었습니다. 다시 로그인한 뒤 준비되면 재시도하세요.", language: language)
        case .busy:
            AppText.localized(english: "Another input is already being processed.", korean: "이미 다른 입력을 처리하고 있습니다.", language: language)
        case .capturePermission:
            AppText.localized(english: "Screen recording permission is required.", korean: "화면 캡처 권한이 필요합니다.", language: language)
        case .captureFailure:
            AppText.localized(english: "Could not capture the screen. Try again.", korean: "화면을 캡처하지 못했습니다. 다시 시도해 주세요.", language: language)
        case .cancelled:
            AppText.localized(english: "Input processing was cancelled.", korean: "입력 처리를 취소했습니다.", language: language)
        case .processingFailure:
            AppText.localized(english: "Could not process the input. Try again.", korean: "입력을 처리하지 못했습니다. 다시 시도해 주세요.", language: language)
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
        case let error as AgentRuntimeError:
            return error == .codexAuthenticationRequired
                ? UserFacingErrorCategory.codexAuthenticationRequired.message
                : UserFacingErrorCategory.agentUnavailable.message
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
        category(forSafeMessage: text, fallback: fallback).message
    }

    public static func category(
        forSafeMessage text: String,
        fallback: UserFacingErrorCategory = .processingFailure
    ) -> UserFacingErrorCategory {
        UserFacingErrorCategory.allCases.first { category in
            AppLanguage.allCases.contains { category.message(language: $0) == text }
        } ?? fallback
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
