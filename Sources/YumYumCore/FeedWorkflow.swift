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
    public let currentTurnText: String?
    public let fileURLs: [URL]
    public let temporaryFileURLs: Set<URL>
    public let cleanupTemporaryFilesAfterSubmit: Bool
    public let sourceRect: CGRect?

    public init(
        text: String = "",
        currentTurnText: String? = nil,
        fileURLs: [URL] = [],
        temporaryFileURLs: Set<URL> = [],
        cleanupTemporaryFilesAfterSubmit: Bool = true,
        sourceRect: CGRect? = nil
    ) {
        self.text = text
        self.currentTurnText = currentTurnText
        self.fileURLs = fileURLs
        self.temporaryFileURLs = temporaryFileURLs
        self.cleanupTemporaryFilesAfterSubmit = cleanupTemporaryFilesAfterSubmit
        self.sourceRect = sourceRect
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
            AppText.localized("대화 내용을 입력하거나 파일을 선택하세요.")
        case let .pathMustBeAbsolute(path):
            AppText.localized(english: "Attachment paths must be absolute: \(path)", korean: "첨부 파일 경로는 절대 경로여야 합니다: \(path)")
        case let .unavailableFile(path):
            AppText.localized(english: "The selected file cannot be used: \(path)", korean: "선택한 파일을 사용할 수 없습니다: \(path)")
        case let .unsupportedFile(path):
            AppText.localized(english: "Unsupported file type: \(path)", korean: "지원하지 않는 파일 형식입니다: \(path)")
        case let .oversizedFile(path, maximumBytes):
            AppText.localized(english: "Files cannot exceed \(maximumBytes / 1_048_576) MB each: \(path)", korean: "파일당 \(maximumBytes / 1_048_576)MB를 초과할 수 없습니다: \(path)")
        case let .credentialFileBlocked(path):
            AppText.localized(english: "Credential or security files cannot be attached: \(path)", korean: "자격증명 또는 보안 파일은 첨부할 수 없습니다: \(path)")
        }
    }
}

public struct ValidatedFeed: Equatable, Sendable {
    public let text: String
    public let currentTurnText: String?
    public let attachments: [PromptAttachment]

    public init(
        text: String,
        currentTurnText: String? = nil,
        attachments: [PromptAttachment]
    ) {
        self.text = text
        self.currentTurnText = currentTurnText
        self.attachments = attachments
    }
}

struct FileMetadata: Equatable, Sendable {
    let byteCount: Int64
    let isReadable: Bool
}

protocol FileMetadataProviding: Sendable {
    func metadata(for url: URL) throws -> FileMetadata
}

private struct FileManagerMetadataProvider: FileMetadataProviding {
    func metadata(for url: URL) throws -> FileMetadata {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw FeedValidationError.unavailableFile(url.path)
        }
        return FileMetadata(
            byteCount: size,
            isReadable: fileManager.isReadableFile(atPath: url.path)
        )
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

    private let metadataProvider: any FileMetadataProviding

    public init() {
        metadataProvider = FileManagerMetadataProvider()
    }

    init(metadataProvider: any FileMetadataProviding) {
        self.metadataProvider = metadataProvider
    }

    public func validate(_ input: FeedInput) throws -> ValidatedFeed {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !input.fileURLs.isEmpty else {
            throw FeedValidationError.blankInput
        }

        let inspectedFiles = try inspect(input.fileURLs)
        let attachments = inspectedFiles.map {
            PromptAttachment(
                url: $0.url,
                kind: $0.kind,
                byteCount: $0.byteCount,
                isTemporary: input.temporaryFileURLs.contains($0.originalURL)
                    || input.temporaryFileURLs.contains($0.url)
            )
        }
        return ValidatedFeed(
            text: text,
            currentTurnText: input.currentTurnText?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            attachments: attachments
        )
    }

    private func inspect(
        _ fileURLs: [URL]
    ) throws -> [(originalURL: URL, url: URL, kind: PromptAttachmentKind, byteCount: Int64)] {
        var seen: Set<String> = []
        var files: [(URL, URL, PromptAttachmentKind, Int64)] = []
        for originalURL in fileURLs {
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
            if (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true {
                throw FeedValidationError.unavailableFile(url.path)
            }

            let metadata: FileMetadata
            do {
                metadata = try metadataProvider.metadata(for: url)
            } catch {
                throw FeedValidationError.unavailableFile(url.path)
            }
            guard metadata.isReadable else {
                throw FeedValidationError.unavailableFile(url.path)
            }
            guard metadata.byteCount <= Int64(Self.maximumAttachmentBytes) else {
                throw FeedValidationError.oversizedFile(
                    path: url.path,
                    maximumBytes: Int64(Self.maximumAttachmentBytes)
                )
            }
            guard let kind = attachmentKind(forExtension: fileExtension) else {
                throw FeedValidationError.unsupportedFile(url.path)
            }

            files.append((originalURL, url, kind, metadata.byteCount))
        }
        return files
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
    public let fileURLs: [URL]
    public let sourceRect: CGRect?

    public init(
        label: String,
        attachmentCount: Int,
        fileURLs: [URL] = [],
        sourceRect: CGRect? = nil
    ) {
        self.label = label
        self.attachmentCount = attachmentCount
        self.fileURLs = fileURLs
        self.sourceRect = sourceRect
    }
}

public enum FeedStatus: Equatable, Sendable {
    case idle
    case validating
    case animating(String)
    case sending
    case completed(String)
    case failed(String)
    case cancelled
}

public enum FeedMouthPresentation: Equatable, Sendable {
    case resting
    case open
    case reducedMotion
}

public protocol PromptSending: Sendable {
    func send(_ request: PromptRequest) async throws -> PromptResponse
    func sendEvents(_ request: PromptRequest) -> PromptResponseEventStream
}

extension AgentRuntime: PromptSending {}

public extension PromptSending {
    func sendEvents(_ request: PromptRequest) -> PromptResponseEventStream {
        completedPromptResponseEvents {
            try await send(request)
        }
    }
}

public protocol FeedSubmitting: Sendable {
    func submit(
        _ input: FeedInput,
        reduceMotion: Bool
    ) async throws -> PromptResponse

    func submitEvents(
        _ input: FeedInput,
        reduceMotion: Bool
    ) -> PromptResponseEventStream
}

public extension FeedSubmitting {
    func submitEvents(
        _ input: FeedInput,
        reduceMotion: Bool
    ) -> PromptResponseEventStream {
        completedPromptResponseEvents {
            try await submit(input, reduceMotion: reduceMotion)
        }
    }
}

public protocol FeedFeedback: Sendable {
    func setMouthPresentation(_ presentation: FeedMouthPresentation) async
    func animate(_ preview: FeedPreview, reduceMotion: Bool) async
    func setStatus(_ update: FeedStatusUpdate) async
}

public enum FeedWorkflowError: Error, Equatable, LocalizedError, Sendable {
    case busy

    public var errorDescription: String? {
        AppText.localized("이미 다른 입력을 처리하고 있습니다.")
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
        try await performSubmit(
            input,
            reduceMotion: reduceMotion,
            emit: { _ in }
        )
    }

    public nonisolated func submitEvents(
        _ input: FeedInput,
        reduceMotion: Bool
    ) -> PromptResponseEventStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await self.performSubmit(
                        input,
                        reduceMotion: reduceMotion,
                        emit: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func resetSession(
        _ reset: @escaping @Sendable () async -> Void
    ) async -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        await reset()
        return true
    }

    private func performSubmit(
        _ input: FeedInput,
        reduceMotion: Bool,
        emit: @escaping @Sendable (PromptResponseEvent) -> Void
    ) async throws -> PromptResponse {
        let generation = UUID()
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
        await feedback.setStatus(
            FeedStatusUpdate(generation: generation, status: .validating)
        )
        do {
            try Task.checkCancellation()
        } catch {
            await feedback.setStatus(
                FeedStatusUpdate(generation: generation, status: .cancelled)
            )
            throw error
        }
        let validated: ValidatedFeed
        do {
            validated = try validator.validate(input)
        } catch {
            await feedback.setStatus(
                FeedStatusUpdate(
                    generation: generation,
                    status: .failed(UserFacingErrorRedactor.message(for: error))
                )
            )
            throw error
        }

        let previewLabel: String
        if validated.attachments.count == 1 {
            previewLabel = validated.attachments[0].url.lastPathComponent
        } else if validated.attachments.count > 1 {
            previewLabel = AppText.files(validated.attachments.count)
        } else {
            previewLabel = AppText.localized("대화")
        }
        do {
            try Task.checkCancellation()
            await feedback.setStatus(
                FeedStatusUpdate(
                    generation: generation,
                    status: .animating(previewLabel)
                )
            )
            try Task.checkCancellation()
            await feedback.setMouthPresentation(
                reduceMotion ? .reducedMotion : .open
            )
            try Task.checkCancellation()
            await feedback.animate(
                FeedPreview(
                    label: previewLabel,
                    attachmentCount: validated.attachments.count,
                    fileURLs: validated.attachments.map(\.url),
                    sourceRect: input.sourceRect
                ),
                reduceMotion: reduceMotion
            )
            try Task.checkCancellation()
        } catch {
            await feedback.setMouthPresentation(.resting)
            await feedback.setStatus(
                FeedStatusUpdate(generation: generation, status: .cancelled)
            )
            throw error
        }
        if !reduceMotion {
            await feedback.setMouthPresentation(.resting)
        }

        let request = PromptRequest(
            text: validated.text,
            currentTurnText: validated.currentTurnText,
            attachments: validated.attachments
        )
        await feedback.setStatus(
            FeedStatusUpdate(generation: generation, status: .sending)
        )
        do {
            try Task.checkCancellation()
            var response: PromptResponse?
            for try await event in sender.sendEvents(request) {
                try Task.checkCancellation()
                emit(event)
                if case let .completed(finalResponse) = event {
                    response = finalResponse
                    break
                }
            }
            try Task.checkCancellation()
            guard let response else {
                throw AgentConnectorError.emptyResponse
            }
            await feedback.setMouthPresentation(.resting)
            await feedback.setStatus(
                FeedStatusUpdate(
                    generation: generation,
                    status: .completed(response.text)
                )
            )
            return response
        } catch is CancellationError {
            await feedback.setMouthPresentation(.resting)
            await feedback.setStatus(
                FeedStatusUpdate(generation: generation, status: .cancelled)
            )
            throw CancellationError()
        } catch {
            await feedback.setMouthPresentation(.resting)
            await feedback.setStatus(
                FeedStatusUpdate(
                    generation: generation,
                    status: .failed(UserFacingErrorRedactor.message(for: error))
                )
            )
            throw error
        }
    }
}
