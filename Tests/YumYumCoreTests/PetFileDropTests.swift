import AppKit
import Foundation
import SwiftUI
import Testing
@testable import YumYumCore
@testable import YumYumApp

extension AppGlobalStateTests {
@Suite
struct PetFileDropTests {
    @Test
    @MainActor
    func petSilhouetteIsOneClosedOuterContour() {
        var moveCount = 0
        var closeCount = 0
        let strokeRoles = YumYumPetView.contourStrokeRoles

        YumYumPetView.silhouettePath.cgPath.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { moveCount += 1 }
            if element.pointee.type == .closeSubpath { closeCount += 1 }
        }

        #expect(moveCount == 1)
        #expect(closeCount == 1)
        #expect(strokeRoles.count(where: { $0 == .outer }) == 1)
        #expect(strokeRoles.count(where: { $0 == .leftInnerEar || $0 == .rightInnerEar }) == 0)
    }

    @Test
    @MainActor
    func facialDetailsMatchEachMouthPose() {
        #expect(YumYumPetView.mouthDetails(for: .closed) == .init(noseCount: 1, mouthStrokeCount: 2, toothCount: 0, tongueCount: 0))
        #expect(YumYumPetView.mouthDetails(for: .halfClosed) == .init(noseCount: 0, mouthStrokeCount: 0, toothCount: 0, tongueCount: 0))
        #expect(YumYumPetView.mouthDetails(for: .open) == .init(noseCount: 0, mouthStrokeCount: 0, toothCount: 1, tongueCount: 1))
    }

    @Test
    @MainActor
    func languageRefreshChangesPetAccessibilityWithoutReplacingPresentationState() {
        _ = NSApplication.shared
        let controller = FloatingPetWindowController {}
        let frame = controller.panel.frame
        let model = controller.presentationModel
        model.chewFrame = .mouthClosedChew
        model.isFileDropTarget = true

        controller.applyLanguage(.english)
        #expect(model.accessibilityLabel == "YumYum Agent floating pet")
        #expect(model.accessibilityHint == "Click to open the quick menu. Drag to move.")
        #expect(controller.panel.contentView?.accessibilityLabel() == "YumYum Agent floating pet")
        #expect(controller.panel.contentView?.accessibilityHelp() == "Click to open the quick menu. Drag to move.")
        controller.applyLanguage(.korean)

        #expect(controller.presentationModel === model)
        #expect(controller.panel.frame == frame)
        #expect(model.chewFrame == .mouthClosedChew)
        #expect(model.isFileDropTarget)
        #expect(model.accessibilityLabel == "YumYum Agent 플로팅 펫")
        #expect(model.accessibilityHint == "클릭하면 빠른 메뉴를 엽니다. 드래그하여 이동할 수 있습니다.")
        #expect(controller.panel.contentView?.accessibilityLabel() == "YumYum Agent 플로팅 펫")
        #expect(controller.panel.contentView?.accessibilityHelp() == "클릭하면 빠른 메뉴를 엽니다. 드래그하여 이동할 수 있습니다.")
    }

    @Test
    func preflightAcceptsRegularFilesDeduplicatesAndRejectsInvalidBatches() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.pdf")
        let unsupported = directory.appendingPathComponent("archive.zip")
        let credential = directory.appendingPathComponent(".env")
        let oversized = directory.appendingPathComponent("large.md")
        let symlink = directory.appendingPathComponent("link.txt")
        let alias = directory.appendingPathComponent("alias.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        try Data("zip".utf8).write(to: unsupported)
        try Data("secret".utf8).write(to: credential)
        try Data(count: FeedValidator.maximumAttachmentBytes + 1).write(to: oversized)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: first)
        let bookmark = try first.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try URL.writeBookmarkData(bookmark, to: alias)

        let validator = FeedValidator()
        #expect(try validator.validate(
            FeedInput(fileURLs: [first, first, second])
        ).attachments.map(\.url) == [first, second])
        #expect(throws: FeedValidationError.self) {
            try validator.validate(FeedInput(fileURLs: [directory]))
        }
        #expect(throws: FeedValidationError.self) {
            try validator.validate(FeedInput(fileURLs: [symlink]))
        }
        #expect(throws: FeedValidationError.self) {
            try validator.validate(FeedInput(fileURLs: [alias]))
        }
        #expect(throws: FeedValidationError.self) {
            try validator.validate(FeedInput(fileURLs: [unsupported]))
        }
        #expect(throws: FeedValidationError.self) {
            try validator.validate(FeedInput(fileURLs: [credential]))
        }
        #expect(throws: FeedValidationError.self) {
            try validator.validate(FeedInput(fileURLs: [oversized]))
        }
        #expect(throws: FeedValidationError.self) {
            try validator.validate(FeedInput(fileURLs: [first, unsupported]))
        }
    }

    @Test
    func metadataValidationRejectsUnreadableRegularFilesWithoutReadingTheirBody() throws {
        let file = URL(fileURLWithPath: "/tmp/unreadable.txt")
        let validator = FeedValidator(
            metadataProvider: StubFileMetadataProvider(
                metadata: FileMetadata(byteCount: 13, isReadable: false)
            )
        )

        #expect(throws: FeedValidationError.unavailableFile(file.path)) {
            try validator.validate(FeedInput(fileURLs: [file]))
        }
    }

    @Test
    func lifecycleResetsOnExitCancelAndConsumesEachDropOnce() {
        var lifecycle = PetDropLifecycle()
        let first = lifecycle.enter(isAccepted: true)
        #expect(first != nil)
        #expect(lifecycle.isHovering)
        let didExit = lifecycle.exit(first)
        #expect(didExit)
        #expect(!lifecycle.isHovering)

        let second = lifecycle.enter(isAccepted: true)
        let didCancel = lifecycle.cancel(second)
        #expect(didCancel)
        #expect(second != nil)
        #expect(!lifecycle.isHovering)

        let generation = lifecycle.enter(isAccepted: true)
        #expect(generation != nil)
        let firstConsume = lifecycle.consume(generation)
        let secondConsume = lifecycle.consume(generation)
        #expect(firstConsume)
        #expect(!secondConsume)
        #expect(!lifecycle.isHovering)
        #expect(lifecycle.enter(isAccepted: false) == nil)
        #expect(!lifecycle.isHovering)
    }

    @Test
    func lifecycleOnlyLetsTheCurrentAcceptedHoverRestorePresentation() {
        var lifecycle = PetDropLifecycle()
        let first = lifecycle.enter(isAccepted: true)
        let second = lifecycle.enter(isAccepted: true)

        let staleCancel = lifecycle.cancel(first)
        #expect(!staleCancel)
        #expect(lifecycle.isHovering)
        let currentCancel = lifecycle.cancel(second)
        #expect(currentCancel)
        #expect(!lifecycle.isHovering)
        let emptyCancel = lifecycle.cancel(nil)
        #expect(!emptyCancel)
    }

    @Test
    @MainActor
    func dragDestinationOverridesAcceptFinderFileURLsAndConsumeTheDropOnce() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.pdf")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        let model = PetPresentationModel()
        let view = FloatingPetHostingView(
            rootView: YumYumPetView(presentationModel: model, onClick: {}),
            onClick: {}
        )
        var performed: [[URL]] = []
        view.canAcceptFileDrop = { $0 == [first, second] }
        view.performFileDrop = {
            performed.append($0)
            return true
        }
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.writeObjects([
            first as NSURL,
            NSURL(string: "https://example.com/not-a-file")!,
            second as NSURL,
        ])
        let draggingInfo = StubDraggingInfo(pasteboard: pasteboard)

        #expect(view.registeredDraggedTypes.contains(.fileURL))
        model.chewFrame = .mouthClosedChew
        #expect(view.draggingEntered(draggingInfo) == .copy)
        #expect(model.isFileDropTarget)
        #expect(model.chewFrame == .mouthOpen)
        #expect(view.draggingUpdated(draggingInfo) == .copy)
        #expect(view.prepareForDragOperation(draggingInfo))
        #expect(view.performDragOperation(draggingInfo))
        #expect(!view.performDragOperation(draggingInfo))
        #expect(performed == [[first, second]])
        #expect(!model.isFileDropTarget)
        #expect(model.chewFrame == .mouthClosedChew)
        view.concludeDragOperation(draggingInfo)
        #expect(performed == [[first, second]])
    }

    @Test
    @MainActor
    func dragExitEndAndConclusionPreserveNewPresentationOwnership() throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).txt")
        try Data("file".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let model = PetPresentationModel()
        let view = FloatingPetHostingView(
            rootView: YumYumPetView(presentationModel: model, onClick: {}),
            onClick: {}
        )
        view.canAcceptFileDrop = { $0 == [file] }
        let draggingInfo = StubDraggingInfo(fileURLs: [file])

        #expect(view.draggingEntered(draggingInfo) == .copy)
        model.chewFrame = .reducedMotion
        view.draggingExited(draggingInfo)
        #expect(!model.isFileDropTarget)
        #expect(model.chewFrame == .reducedMotion)

        #expect(view.draggingEntered(draggingInfo) == .copy)
        view.draggingEnded(draggingInfo)
        #expect(!model.isFileDropTarget)
        #expect(model.chewFrame == .reducedMotion)

        #expect(view.draggingEntered(draggingInfo) == .copy)
        view.concludeDragOperation(draggingInfo)
        #expect(!model.isFileDropTarget)
        #expect(model.chewFrame == .reducedMotion)
    }

    @Test
    @MainActor
    func invalidAndNonFileDragOverridesNeverChangePetPresentation() throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).txt")
        try Data("file".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let model = PetPresentationModel()
        model.chewFrame = .reducedMotion
        let view = FloatingPetHostingView(
            rootView: YumYumPetView(presentationModel: model, onClick: {}),
            onClick: {}
        )
        view.canAcceptFileDrop = { _ in false }
        let invalidFile = StubDraggingInfo(fileURLs: [file])
        let nonFile = StubDraggingInfo(string: "/private/tmp/secret.txt")

        #expect(view.draggingEntered(invalidFile).isEmpty)
        #expect(view.draggingUpdated(invalidFile).isEmpty)
        #expect(!view.prepareForDragOperation(invalidFile))
        #expect(!view.performDragOperation(invalidFile))
        #expect(view.draggingEntered(nonFile).isEmpty)
        #expect(view.draggingUpdated(nonFile).isEmpty)
        #expect(!view.prepareForDragOperation(nonFile))
        #expect(!view.performDragOperation(nonFile))
        #expect(!model.isFileDropTarget)
        #expect(model.chewFrame == .reducedMotion)
        #expect(view.accessibilityLabel()?.contains("/private/tmp") != true)
    }
}
}

private struct StubFileMetadataProvider: FileMetadataProviding {
    let metadata: FileMetadata

    func metadata(for url: URL) throws -> FileMetadata {
        metadata
    }
}

@MainActor
private final class StubDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow? = nil
    let draggingSourceOperationMask: NSDragOperation = .copy
    let draggingLocation = NSPoint.zero
    let draggedImageLocation = NSPoint.zero
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 0
    var draggingFormation = NSDraggingFormation.default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    let springLoadingHighlight = NSSpringLoadingHighlight.none

    init(pasteboard: NSPasteboard) {
        draggingPasteboard = pasteboard
    }

    convenience init(fileURLs: [URL]) {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.writeObjects(fileURLs as [NSURL])
        self.init(pasteboard: pasteboard)
    }

    convenience init(string: String) {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        self.init(pasteboard: pasteboard)
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
        nil
    }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}
