import CoreGraphics
import Testing
@testable import YumYumCore

@Suite
struct FloatingPetLayoutTests {
    @Test
    func placesThePetAtTheVisibleFrameBottomRightWithTwentyPointInsets() {
        let visibleFrame = CGRect(x: 0, y: 40, width: 1_440, height: 860)

        let frame = FloatingPetLayout().initialFrame(in: visibleFrame)

        #expect(frame == CGRect(x: 1_324, y: 60, width: 96, height: 96))
    }

    @Test
    func placesThePetCorrectlyOnANegativeCoordinateScreen() {
        let visibleFrame = CGRect(x: -1_728, y: -80, width: 1_728, height: 1_080)

        let frame = FloatingPetLayout().initialFrame(in: visibleFrame)

        #expect(frame == CGRect(x: -116, y: -60, width: 96, height: 96))
    }

    @Test
    func fitsThePetInsideAVisibleFrameSmallerThanThePreferredSize() {
        let visibleFrame = CGRect(x: 10, y: 20, width: 80, height: 70)

        let frame = FloatingPetLayout().initialFrame(in: visibleFrame)

        #expect(frame == visibleFrame)
    }

    @Test
    func clampsAnOffscreenFrameIntoTheVisibleFrame() {
        let visibleFrame = CGRect(x: -1_280, y: 23, width: 1_280, height: 777)
        let offscreenFrame = CGRect(x: 80, y: -100, width: 96, height: 96)

        let frame = FloatingPetLayout().clampedFrame(
            offscreenFrame,
            inside: visibleFrame
        )

        #expect(frame == CGRect(x: -96, y: 23, width: 96, height: 96))
    }

    @Test
    func leavesAnAlreadyVisibleDraggedFrameUnchanged() {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1_440, height: 875)
        let draggedFrame = CGRect(x: 500, y: 300, width: 96, height: 96)

        let frame = FloatingPetLayout().clampedFrame(
            draggedFrame,
            inside: visibleFrame
        )

        #expect(frame == draggedFrame)
    }
}

@Suite
struct FloatingPetVisibilityPolicyTests {
    @Test
    func startsVisibleAndTogglesBothWays() {
        var policy = FloatingPetVisibilityPolicy()

        #expect(policy.isVisible)
        policy.toggle()
        #expect(!policy.isVisible)
        policy.toggle()
        #expect(policy.isVisible)
    }

    @Test
    func doesNotCarryVisibilityIntoANewPolicyInstance() {
        var currentRun = FloatingPetVisibilityPolicy()
        currentRun.setVisible(false)

        let nextRun = FloatingPetVisibilityPolicy()

        #expect(!currentRun.isVisible)
        #expect(nextRun.isVisible)
    }
}
