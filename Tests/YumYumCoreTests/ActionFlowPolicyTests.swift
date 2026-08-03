import CoreGraphics
import Foundation
import Testing
@testable import YumYumCore

@Suite
struct ActionFlowPolicyTests {
    @Test
    func actionBubbleHasExactlyTheApprovedOrderedRows() {
        #expect(ActionBubbleAction.allCases == [
            .capture,
            .findFile,
            .openChat,
            .settings,
        ])
        #expect(ActionBubbleAction.allCases.map(\.title) == [
            "캡처하기",
            "파일 찾기",
            "채팅 열기",
            "설정",
        ])
        #expect(ActionBubbleAction.allCases.map(\.symbolName) == [
            "camera.viewfinder",
            "folder",
            "bubble.left.and.bubble.right",
            "gearshape",
        ])
    }

    @Test
    func captureHidesEveryYumYumSurfaceBeforeRegionSelectionAndCancelReturnsPetOnly() {
        let generation = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        var flow = ActionFlowStateMachine()

        _ = flow.openActionBubble()
        let effects = flow.select(.capture, generation: generation)

        #expect(flow.surface == .selectingCapture(generation))
        #expect(effects == [
            .hideAllForCapture,
            .beginCapture(generation),
        ])

        let cancelEffects = flow.finishCapture(.cancelled, generation: generation)
        #expect(flow.surface == .petOnly)
        #expect(cancelEffects == [.showPet])
    }

    @Test
    func captureCallbackCreatesOneImmediateMealFromTheSelectedScreenRect() {
        let generation = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let url = URL(fileURLWithPath: "/private/tmp/YumYum-Capture-test.png")
        let region = CGRect(x: -420, y: 120, width: 640, height: 360)
        var flow = ActionFlowStateMachine()
        _ = flow.openActionBubble()
        _ = flow.select(.capture, generation: generation)

        let first = flow.finishCapture(
            .selected(url: url, region: region),
            generation: generation
        )
        let lateDuplicate = flow.finishCapture(
            .selected(url: url, region: region),
            generation: generation
        )

        #expect(flow.surface == .feeding(generation))
        #expect(first == [
            .showPet,
            .submitMeal(
                ActionMeal(
                    fileURLs: [url],
                    temporaryFileURLs: [url],
                    sourceRect: region
                ),
                generation
            ),
        ])
        #expect(lateDuplicate.isEmpty)
    }

    @Test
    func oneFileSelectionIsOneMealAndCancelOrStaleCallbacksStayPetOnly() {
        let firstGeneration = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let staleGeneration = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let files = [
            URL(fileURLWithPath: "/Users/person/a.pdf"),
            URL(fileURLWithPath: "/Users/person/b.swift"),
        ]
        var flow = ActionFlowStateMachine()

        _ = flow.openActionBubble()
        #expect(flow.select(.findFile, generation: firstGeneration) == [
            .hideActionBubble,
            .beginFileSelection(firstGeneration),
        ])
        #expect(
            flow.finishFiles(.selected(files), generation: staleGeneration).isEmpty
        )
        #expect(flow.finishFiles(.selected(files), generation: firstGeneration) == [
            .showPet,
            .submitMeal(
                ActionMeal(fileURLs: files),
                firstGeneration
            ),
        ])
        #expect(flow.finishFiles(.selected(files), generation: firstGeneration).isEmpty)

        _ = flow.openActionBubble()
        _ = flow.select(.findFile, generation: staleGeneration)
        #expect(flow.finishFiles(.cancelled, generation: staleGeneration) == [.showPet])
        #expect(flow.surface == .petOnly)
    }

    @Test
    func responseClickOpensChatAtTheLatestMessageAndChatHideDoesNotCancel() {
        var flow = ActionFlowStateMachine()
        flow.showResponse()

        #expect(flow.responseClicked() == [
            .hideResponseBubble,
            .showChat(scrollToLatest: true),
        ])
        #expect(flow.surface == .chat)
        #expect(flow.hideChat() == [.hideChat, .showPet])
        #expect(flow.surface == .petOnly)
    }

    @Test
    func chatAndSettingsActionsCloseTheActionBubbleBeforeTheirDestination() {
        var chatFlow = ActionFlowStateMachine()
        _ = chatFlow.openActionBubble()
        let chatEffects = chatFlow.select(.openChat)
        #expect(chatEffects == [
            .hideActionBubble,
            .showChat(scrollToLatest: false),
        ])
        #expect(chatFlow.surface == .chat)

        var settingsFlow = ActionFlowStateMachine()
        _ = settingsFlow.openActionBubble()
        let settingsEffects = settingsFlow.select(.settings)
        #expect(settingsEffects == [
            .hideActionBubble,
            .showPet,
            .openSettings,
        ])
        #expect(settingsFlow.surface == .petOnly)
    }

    @Test
    func capturePermissionAndFailureAlsoReturnToPetOnly() {
        for outcome in [
            ActionCaptureOutcome.permissionDenied,
            .failed("capture failed"),
        ] {
            let generation = UUID()
            var flow = ActionFlowStateMachine()
            _ = flow.openActionBubble()
            _ = flow.select(.capture, generation: generation)

            let effects = flow.finishCapture(outcome, generation: generation)

            #expect(effects == [.showPet])
            #expect(flow.surface == .petOnly)
        }
    }
}

@Suite
struct FeedPreviewFlightPolicyTests {
    @Test
    func capturePreviewAspectFitsThenRisesAndFliesIntoTheMouthIn420Milliseconds() throws {
        let policy = FeedPreviewFlightPolicy()
        let source = CGRect(x: -500, y: 100, width: 400, height: 200)
        let target = CGRect(x: 1_000, y: 50, width: 22, height: 14)

        let frames = policy.keyframes(
            contentSize: CGSize(width: 800, height: 400),
            sourceRect: source,
            targetRect: target,
            reduceMotion: false
        )

        #expect(frames.map(\.milliseconds) == [0, 100, 420])
        #expect(frames[0].frame == CGRect(x: -388, y: 156, width: 176, height: 88))
        #expect(abs(frames[1].frame.width - 154.88) < 0.001)
        #expect(abs(frames[1].frame.height - 77.44) < 0.001)
        #expect(abs(frames[1].frame.midX - source.midX) < 0.001)
        #expect(abs(frames[1].frame.midY - (source.midY + 6)) < 0.001)
        #expect(frames[2].frame == target)
        #expect(frames[2].alpha == 0.08)
    }

    @Test
    func reduceMotionUsesOnlyAOneHundredMillisecondFade() {
        let frames = FeedPreviewFlightPolicy().keyframes(
            contentSize: CGSize(width: 400, height: 300),
            sourceRect: CGRect(x: 20, y: 40, width: 200, height: 150),
            targetRect: CGRect(x: 800, y: 80, width: 22, height: 14),
            reduceMotion: true
        )

        #expect(frames.map(\.milliseconds) == [0, 100])
        #expect(frames[0].frame == frames[1].frame)
        #expect(frames.map(\.alpha) == [1, 0])
    }
}

@Suite
struct ThinkingAnimationPolicyTests {
    @Test
    func externalBubbleIsVisibleOnlyWhileThinkingWithChatClosed() {
        let policy = ThinkingAnimationPolicy()

        #expect(policy.showsExternalBubble(isThinking: true, isChatVisible: false))
        #expect(!policy.showsExternalBubble(isThinking: true, isChatVisible: true))
        #expect(!policy.showsExternalBubble(isThinking: false, isChatVisible: false))
    }

    @Test
    func chewUsesTheApprovedNineHundredMillisecondFramesAndHasAnExactReset() {
        let policy = ThinkingAnimationPolicy()

        #expect(PetChewFrame.resting.mouth == .closed)
        for millisecond in [0, 300, 600, 900] {
            #expect(policy.frame(at: millisecond, reduceMotion: false) == .mouthOpen)
        }
        for millisecond in [150, 450, 750] {
            #expect(policy.frame(at: millisecond, reduceMotion: false) == .mouthClosedChew)
        }
        #expect(PetChewFrame.mouthOpen.bodyScaleX == 0.985)
        #expect(PetChewFrame.mouthOpen.bodyScaleY == 1.025)
        #expect(PetChewFrame.mouthOpen.bodyOffsetY == -2)
        #expect(PetChewFrame.mouthOpen.cheekOffset == -1)
        #expect(PetChewFrame.mouthClosedChew.bodyScaleX == 1.035)
        #expect(PetChewFrame.mouthClosedChew.bodyScaleY == 0.955)
        #expect(PetChewFrame.mouthClosedChew.bodyOffsetY == 2)
        #expect(PetChewFrame.mouthClosedChew.cheekOffset == 3)
        #expect(policy.resetFrame == .resting)
        #expect(policy.resetFrame.mouth == .closed)
    }

    @Test
    func thinkingTextCyclesOncePerNineHundredMillisecondsWithoutAnnouncements() {
        let policy = ThinkingAnimationPolicy()

        #expect(policy.thought(at: 0, reduceMotion: false) == "Yum.")
        #expect(policy.thought(at: 299, reduceMotion: false) == "Yum.")
        #expect(policy.thought(at: 300, reduceMotion: false) == "Yum..")
        #expect(policy.thought(at: 599, reduceMotion: false) == "Yum..")
        #expect(policy.thought(at: 600, reduceMotion: false) == "Yum...")
        #expect(policy.thought(at: 899, reduceMotion: false) == "Yum...")
        #expect(policy.thought(at: 900, reduceMotion: false) == "Yum.")
    }

    @Test
    func reduceMotionIsStaticHalfClosedAndNeverTransformsThePet() {
        let policy = ThinkingAnimationPolicy()
        let frame = policy.frame(at: 450, reduceMotion: true)

        #expect(policy.thought(at: 450, reduceMotion: true) == "Yum...")
        #expect(frame.mouth == .halfClosed)
        #expect(frame.bodyScaleX == 1)
        #expect(frame.bodyScaleY == 1)
        #expect(frame.bodyOffsetY == 0)
        #expect(frame.cheekOffset == 0)
    }
}

@Suite
struct PetResponsePolicyTests {
    @Test
    func shortKoreanAnswerIsShownInFull() {
        let answer = "선택한 화면에는 세 개의 일정이 있습니다. 가장 이른 일정은 오전 9시입니다."

        let content = PetResponsePolicy.content(for: answer)

        #expect(content.fullText == answer)
        #expect(content.displayText == answer)
        #expect(!content.isExcerpt)
        #expect(!content.showsOpenChat)
    }

    @Test
    func longMultilineAnswerRemainsCompleteForTheScrollablePetBubble() {
        let answer = (1...40)
            .map { "\($0)번째 줄: " + String(repeating: "긴 답변 ", count: 12) }
            .joined(separator: "\n")

        let content = PetResponsePolicy.content(for: answer)

        #expect(content.fullText == answer)
        #expect(content.displayText == answer)
        #expect(content.displayText.split(separator: "\n").count == 40)
        #expect(!content.isExcerpt)
        #expect(!content.showsOpenChat)
    }

    @Test
    func errorContentIsFriendlyRetryableAndDoesNotExposeLocalPaths() {
        let raw = "선택한 에이전트 경로를 사용할 수 없습니다: /Users/person/bin/agent"
        let content = PetResponsePolicy.error(message: raw)

        #expect(
            content.fullText
                == "입력을 처리하지 못했습니다. 다시 시도해 주세요."
        )
        #expect(content.isError)
        #expect(content.showsRetry)
        #expect(content.showsOpenChat)
        #expect(!content.displayText.contains("/Users/"))
    }
}

@Suite
struct FeedStatusGenerationGateTests {
    @Test
    func lateStatusFromAnOlderGenerationCannotReplaceTheCurrentPresentation() {
        let old = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        let current = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        var gate = FeedStatusGenerationGate()

        let acceptedOldStart = gate.apply(
            FeedStatusUpdate(generation: old, status: .validating)
        )
        let acceptedOldSending = gate.apply(
            FeedStatusUpdate(generation: old, status: .sending)
        )
        let acceptedCurrentStart = gate.apply(
            FeedStatusUpdate(generation: current, status: .validating)
        )
        let acceptedStaleCompletion = gate.apply(
            FeedStatusUpdate(generation: old, status: .completed("늦은 응답"))
        )
        let acceptedStaleRestart = gate.apply(
            FeedStatusUpdate(generation: old, status: .validating)
        )
        #expect(acceptedOldStart)
        #expect(acceptedOldSending)
        #expect(acceptedCurrentStart)
        #expect(!acceptedStaleCompletion)
        #expect(!acceptedStaleRestart)
        #expect(gate.status == .validating)
        let acceptedCurrentCompletion = gate.apply(
            FeedStatusUpdate(generation: current, status: .completed("최신 응답"))
        )
        #expect(acceptedCurrentCompletion)
        #expect(gate.status == .completed("최신 응답"))
    }

    @Test
    func retainedGenerationHistoryStaysBoundedAcrossManyMeals() {
        var gate = FeedStatusGenerationGate()
        var recentGeneration: UUID?

        for _ in 0..<100 {
            recentGeneration = gate.activeGeneration
            let generation = UUID()
            _ = gate.apply(
                FeedStatusUpdate(generation: generation, status: .validating)
            )
            _ = gate.apply(
                FeedStatusUpdate(generation: generation, status: .completed("완료"))
            )
        }

        #expect(
            gate.retiredGenerationCount
                <= FeedStatusGenerationGate.retainedGenerationLimit
        )
        let staleAccepted = gate.apply(
            FeedStatusUpdate(
                generation: recentGeneration!,
                status: .validating
            )
        )
        #expect(!staleAccepted)
    }
}

@Suite
struct UserFacingErrorRedactorTests {
    @Test
    func arbitraryPathsStderrAndCredentialPatternsBecomeOneSafeMessage() {
        let unsafeErrors: [SensitiveFixtureError] = [
            SensitiveFixtureError("/Users/example/private/report.pdf"),
            SensitiveFixtureError("stderr: command failed with implementation detail"),
            SensitiveFixtureError("token=TEST_ONLY_TOKEN_VALUE"),
            SensitiveFixtureError("-----BEGIN PRIVATE KEY-----"),
        ]

        let messages = unsafeErrors.map(UserFacingErrorRedactor.message(for:))

        #expect(messages.allSatisfy {
            $0 == "입력을 처리하지 못했습니다. 다시 시도해 주세요."
        })
    }

    @Test
    func typedValidationErrorKeepsOnlyItsSafeCategory() {
        let message = UserFacingErrorRedactor.message(
            for: FeedValidationError.unavailableFile(
                "/Users/example/private/report.pdf"
            )
        )

        #expect(
            message
                == "선택한 파일을 사용할 수 없습니다. 파일 형식과 크기를 확인해 주세요."
        )
    }

    @Test
    func sanitizingUnknownStateTextNeverPassesItThrough() {
        let message = UserFacingErrorRedactor.sanitize(
            "stderr: token=TEST_ONLY_TOKEN_VALUE at /Users/example/tool",
            fallback: .processingFailure
        )

        #expect(message == "입력을 처리하지 못했습니다. 다시 시도해 주세요.")
    }
}

@Suite
struct ActionMenuFocusPolicyTests {
    @Test
    func firstFocusAndRehomingSkipDisabledFeedRows() {
        let disabledFeedRows = [false, false, true, true]

        #expect(
            ActionMenuFocusPolicy.firstEnabledIndex(in: disabledFeedRows) == 2
        )
        #expect(
            ActionMenuFocusPolicy.rehomedIndex(
                current: 0,
                enabled: disabledFeedRows
            ) == 2
        )
        #expect(
            ActionMenuFocusPolicy.nextEnabledIndex(
                from: 2,
                delta: -1,
                enabled: disabledFeedRows
            ) == 3
        )
        #expect(
            ActionMenuFocusPolicy.firstEnabledIndex(
                in: [true, true, true, true]
            ) == 0
        )
    }
}

@Suite
struct CallbackGenerationPolicyTests {
    @Test
    func invalidationRejectsLatePanelCompletionAndConsumeIsExactlyOnce() {
        let stale = UUID()
        let current = UUID()
        var gate = CallbackGenerationGate()

        let beganStale = gate.begin(stale)
        gate.invalidate()
        let consumedStale = gate.consume(stale)
        let beganCurrent = gate.begin(current)
        let consumedCurrent = gate.consume(current)
        let duplicateCurrent = gate.consume(current)

        #expect(beganStale)
        #expect(!consumedStale)
        #expect(beganCurrent)
        #expect(consumedCurrent)
        #expect(!duplicateCurrent)
    }
}

private struct SensitiveFixtureError: LocalizedError, Sendable {
    let raw: String

    init(_ raw: String) {
        self.raw = raw
    }

    var errorDescription: String? { raw }
}
