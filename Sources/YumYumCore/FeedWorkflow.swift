import Foundation

public enum CaptureTemporaryFileCleanup {
    public static let filenamePrefix = "YumYum-Capture-"

    public static func removeStaleFiles(
        in directory: URL = FileManager.default.temporaryDirectory
    ) {
        let fileManager = FileManager.default
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return
        }

        for candidate in candidates
        where candidate.lastPathComponent.hasPrefix(filenamePrefix) {
            let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else {
                continue
            }
            try? fileManager.removeItem(at: candidate)
        }
    }
}

public struct FeedInput: Equatable, Sendable {
    public let text: String
    public let fileURLs: [URL]
    public let temporaryFileURLs: Set<URL>
    public let cleanupTemporaryFilesAfterSubmit: Bool

    public init(
        text: String = "",
        fileURLs: [URL] = [],
        temporaryFileURLs: Set<URL> = [],
        cleanupTemporaryFilesAfterSubmit: Bool = true
    ) {
        self.text = text
        self.fileURLs = fileURLs
        self.temporaryFileURLs = temporaryFileURLs
        self.cleanupTemporaryFilesAfterSubmit = cleanupTemporaryFilesAfterSubmit
    }
}

public enum FeedValidationError: Error, Equatable, LocalizedError, Sendable {
    case blankInput
    case pathMustBeAbsolute(String)
    case unavailableFile(String)
    case unsupportedFile(String)
    case oversizedFile(path: String, maximumBytes: Int64)
    case credentialFileBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .blankInput:
            "대화 내용을 입력하거나 파일을 선택하세요."
        case let .pathMustBeAbsolute(path):
            "첨부 파일 경로는 절대 경로여야 합니다: \(path)"
        case let .unavailableFile(path):
            "선택한 파일을 사용할 수 없습니다: \(path)"
        case let .unsupportedFile(path):
            "지원하지 않는 파일 형식입니다: \(path)"
        case let .oversizedFile(path, maximumBytes):
            "파일당 \(maximumBytes / 1_048_576)MB를 초과할 수 없습니다: \(path)"
        case let .credentialFileBlocked(path):
            "자격증명 또는 보안 파일은 첨부할 수 없습니다: \(path)"
        }
    }
}

public struct ValidatedFeed: Equatable, Sendable {
    public let text: String
    public let attachments: [PromptAttachment]

    public init(text: String, attachments: [PromptAttachment]) {
        self.text = text
        self.attachments = attachments
    }
}

public struct FeedValidator: Sendable {
    public static let maximumAttachmentBytes = 20 * 1_024 * 1_024

    private static let imageExtensions: Set<String> = [
        "bmp", "gif", "heic", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ]
    private static let plainTextExtensions: Set<String> = ["md", "markdown", "txt"]
    private static let sourceExtensions: Set<String> = [
        "c", "cc", "cpp", "css", "cs", "fish", "go", "h", "hpp", "html",
        "java", "js", "json", "jsx", "kt", "kts", "m", "mm", "php", "py",
        "rb", "rs", "scss", "sh", "sql", "swift", "toml", "ts", "tsx",
        "xml", "yaml", "yml", "zsh",
    ]
    private static let blockedNames: Set<String> = [
        ".env", ".netrc", ".npmrc", ".pypirc", "credentials", "credentials.json",
        "id_dsa", "id_ecdsa", "id_ed25519", "id_rsa", "token", "token.json",
    ]
    private static let blockedExtensions: Set<String> = [
        "cer", "crt", "key", "mobileprovision", "p12", "pem",
    ]

    public init() {}

    public func validate(_ input: FeedInput) throws -> ValidatedFeed {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !input.fileURLs.isEmpty else {
            throw FeedValidationError.blankInput
        }

        var seen: Set<String> = []
        var attachments: [PromptAttachment] = []
        for originalURL in input.fileURLs {
            let url = originalURL.standardizedFileURL
            guard NSString(string: url.path).isAbsolutePath else {
                throw FeedValidationError.pathMustBeAbsolute(originalURL.path)
            }
            guard seen.insert(url.path).inserted else {
                continue
            }

            let name = url.lastPathComponent.lowercased()
            let fileExtension = url.pathExtension.lowercased()
            guard !Self.blockedNames.contains(name),
                  !Self.blockedExtensions.contains(fileExtension) else {
                throw FeedValidationError.credentialFileBlocked(url.path)
            }

            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            } catch {
                throw FeedValidationError.unavailableFile(url.path)
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value else {
                throw FeedValidationError.unavailableFile(url.path)
            }
            guard size <= Int64(Self.maximumAttachmentBytes) else {
                throw FeedValidationError.oversizedFile(
                    path: url.path,
                    maximumBytes: Int64(Self.maximumAttachmentBytes)
                )
            }
            guard let kind = attachmentKind(forExtension: fileExtension) else {
                throw FeedValidationError.unsupportedFile(url.path)
            }

            attachments.append(
                PromptAttachment(
                    url: url,
                    kind: kind,
                    byteCount: size,
                    isTemporary: input.temporaryFileURLs.contains(originalURL)
                        || input.temporaryFileURLs.contains(url)
                )
            )
        }
        return ValidatedFeed(text: text, attachments: attachments)
    }

    private func attachmentKind(forExtension fileExtension: String) -> PromptAttachmentKind? {
        if Self.imageExtensions.contains(fileExtension) {
            return .image
        }
        if fileExtension == "pdf" {
            return .pdf
        }
        if Self.plainTextExtensions.contains(fileExtension) {
            return .plainText
        }
        if Self.sourceExtensions.contains(fileExtension) {
            return .source
        }
        return nil
    }
}

public struct FeedPreview: Equatable, Sendable {
    public let label: String
    public let attachmentCount: Int

    public init(label: String, attachmentCount: Int) {
        self.label = label
        self.attachmentCount = attachmentCount
    }
}

public enum FeedStatus: Equatable, Sendable {
    case idle
    case validating
    case animating(String)
    case sending
    case completed(String)
    case failed(String)
}

public protocol PromptSending: Sendable {
    func send(_ request: PromptRequest) async throws -> PromptResponse
}

extension AgentRuntime: PromptSending {}

public protocol FeedSubmitting: Sendable {
    func submit(
        _ input: FeedInput,
        reduceMotion: Bool
    ) async throws -> PromptResponse
}

public protocol FeedFeedback: Sendable {
    func setMouthOpen(_ isOpen: Bool) async
    func animate(_ preview: FeedPreview, reduceMotion: Bool) async
    func setStatus(_ status: FeedStatus) async
}

public enum FeedWorkflowError: Error, Equatable, LocalizedError, Sendable {
    case busy

    public var errorDescription: String? {
        "이미 다른 입력을 처리하고 있습니다."
    }
}

public actor FeedWorkflow: FeedSubmitting {
    private let validator: FeedValidator
    private let sender: any PromptSending
    private let feedback: any FeedFeedback
    private var isSubmitting = false

    public init(
        validator: FeedValidator = FeedValidator(),
        sender: any PromptSending,
        feedback: any FeedFeedback
    ) {
        self.validator = validator
        self.sender = sender
        self.feedback = feedback
    }

    public func submit(
        _ input: FeedInput,
        reduceMotion: Bool
    ) async throws -> PromptResponse {
        defer {
            if input.cleanupTemporaryFilesAfterSubmit {
                for url in input.temporaryFileURLs {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        guard !isSubmitting else {
            throw FeedWorkflowError.busy
        }
        isSubmitting = true
        defer {
            isSubmitting = false
        }

        try Task.checkCancellation()
        await feedback.setStatus(.validating)
        do {
            try Task.checkCancellation()
        } catch {
            await feedback.setMouthOpen(false)
            await feedback.setStatus(.failed("입력 처리를 취소했습니다."))
            throw error
        }
        let validated: ValidatedFeed
        do {
            validated = try validator.validate(input)
        } catch {
            await feedback.setStatus(.failed((error as? LocalizedError)?.errorDescription ?? "입력을 확인할 수 없습니다."))
            throw error
        }

        let previewLabel: String
        if validated.attachments.count == 1 {
            previewLabel = validated.attachments[0].url.lastPathComponent
        } else if validated.attachments.count > 1 {
            previewLabel = "파일 \(validated.attachments.count)개"
        } else {
            previewLabel = "대화"
        }
        do {
            try Task.checkCancellation()
            await feedback.setStatus(.animating(previewLabel))
            try Task.checkCancellation()
            await feedback.setMouthOpen(true)
            try Task.checkCancellation()
            await feedback.animate(
                FeedPreview(
                    label: previewLabel,
                    attachmentCount: validated.attachments.count
                ),
                reduceMotion: reduceMotion
            )
            try Task.checkCancellation()
        } catch {
            await feedback.setMouthOpen(false)
            await feedback.setStatus(.failed("입력 처리를 취소했습니다."))
            throw error
        }
        await feedback.setMouthOpen(false)

        let request = PromptRequest(
            text: validated.text,
            attachments: validated.attachments
        )
        await feedback.setStatus(.sending)
        do {
            try Task.checkCancellation()
            let response = try await sender.send(request)
            try Task.checkCancellation()
            await feedback.setStatus(.completed(response.text))
            return response
        } catch is CancellationError {
            await feedback.setMouthOpen(false)
            await feedback.setStatus(.failed("입력 처리를 취소했습니다."))
            throw CancellationError()
        } catch {
            await feedback.setMouthOpen(false)
            await feedback.setStatus(.failed((error as? LocalizedError)?.errorDescription ?? "전송하지 못했습니다."))
            throw error
        }
    }
}
