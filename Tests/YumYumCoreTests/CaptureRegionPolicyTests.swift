import CoreGraphics
import Dispatch
import Foundation
import Testing
@testable import YumYumCore

@Suite
struct CaptureRegionPolicyTests {
    @Test
    func normalizesEveryDragDirectionAndRejectsEitherDimensionBelowEightPoints() {
        let policy = CaptureRegionPolicy()
        let expected = CGRect(x: -40, y: 20, width: 120, height: 80)

        #expect(policy.region(from: CGPoint(x: -40, y: 20), to: CGPoint(x: 80, y: 100)) == expected)
        #expect(policy.region(from: CGPoint(x: 80, y: 20), to: CGPoint(x: -40, y: 100)) == expected)
        #expect(policy.region(from: CGPoint(x: -40, y: 100), to: CGPoint(x: 80, y: 20)) == expected)
        #expect(policy.region(from: CGPoint(x: 80, y: 100), to: CGPoint(x: -40, y: 20)) == expected)
        #expect(policy.region(from: .zero, to: CGPoint(x: 8, y: 8)) == CGRect(x: 0, y: 0, width: 8, height: 8))
        #expect(policy.region(from: .zero, to: CGPoint(x: 7.99, y: 20)) == nil)
        #expect(policy.region(from: .zero, to: CGPoint(x: 20, y: 7.99)) == nil)
    }

    @Test
    func plansNegativeVerticalAndMixedScaleDisplayFragmentsInOneOutputImage() throws {
        let policy = CaptureRegionPolicy()
        let displays = [
            CaptureDisplayGeometry(
                id: 10,
                frame: CGRect(x: -800, y: 0, width: 800, height: 600),
                scale: 1
            ),
            CaptureDisplayGeometry(
                id: 20,
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                scale: 2
            ),
            CaptureDisplayGeometry(
                id: 30,
                frame: CGRect(x: 0, y: 800, width: 1_000, height: 600),
                scale: 1
            ),
        ]

        let plan = try #require(
            policy.plan(
                region: CGRect(x: -100, y: 500, width: 300, height: 400),
                displays: displays
            )
        )

        #expect(plan.pixelSize == CGSize(width: 600, height: 800))
        #expect(plan.fragments == [
            CapturePixelFragment(
                displayID: 10,
                sourcePointRect: CGRect(x: 700, y: 0, width: 100, height: 100),
                sourcePixelSize: CGSize(width: 100, height: 100),
                destinationPixelRect: CGRect(x: 0, y: 600, width: 200, height: 200)
            ),
            CapturePixelFragment(
                displayID: 20,
                sourcePointRect: CGRect(x: 0, y: 0, width: 200, height: 300),
                sourcePixelSize: CGSize(width: 400, height: 600),
                destinationPixelRect: CGRect(x: 200, y: 200, width: 400, height: 600)
            ),
            CapturePixelFragment(
                displayID: 30,
                sourcePointRect: CGRect(x: 0, y: 500, width: 200, height: 100),
                sourcePixelSize: CGSize(width: 200, height: 100),
                destinationPixelRect: CGRect(x: 200, y: 0, width: 400, height: 200)
            ),
        ])
    }

    @Test
    func callbackAndCancellationCanEnterFromAPrivateQueueWithoutMainActorIsolation() async {
        let success = CaptureCallbackGate<CGRect>()
        let cancelled = CaptureCallbackGate<CGRect>()
        let queue = DispatchQueue(label: "CaptureRegionPolicyTests.private")

        queue.async {
            #expect(!Thread.isMainThread)
            success.resolve(.selected(CGRect(x: 1, y: 2, width: 30, height: 40)))
            cancelled.resolve(.cancelled)
        }

        #expect(await success.value() == .selected(CGRect(x: 1, y: 2, width: 30, height: 40)))
        #expect(await cancelled.value() == .cancelled)
    }

    @Test
    func cancellingTheWaitingTaskWinsOverLateSelectionCallbacks() async {
        let gate = CaptureCallbackGate<Int>()
        let task = Task {
            await gate.value()
        }

        await Task.yield()
        task.cancel()
        await Task.yield()
        gate.resolve(.selected(42))

        #expect(await task.value == .cancelled)
        gate.resolve(.cancelled)
        #expect(await gate.value() == .cancelled)
    }
}
