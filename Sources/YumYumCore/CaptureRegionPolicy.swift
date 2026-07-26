import CoreGraphics
import Foundation

public struct CaptureDisplayGeometry: Equatable, Sendable {
    public let id: UInt32
    public let frame: CGRect
    public let scale: CGFloat

    public init(id: UInt32, frame: CGRect, scale: CGFloat) {
        self.id = id
        self.frame = frame
        self.scale = scale
    }
}

public struct CapturePixelFragment: Equatable, Sendable {
    public let displayID: UInt32
    public let sourcePointRect: CGRect
    public let sourcePixelSize: CGSize
    public let destinationPixelRect: CGRect

    public init(
        displayID: UInt32,
        sourcePointRect: CGRect,
        sourcePixelSize: CGSize,
        destinationPixelRect: CGRect
    ) {
        self.displayID = displayID
        self.sourcePointRect = sourcePointRect
        self.sourcePixelSize = sourcePixelSize
        self.destinationPixelRect = destinationPixelRect
    }
}

public struct CaptureRegionPlan: Equatable, Sendable {
    public let region: CGRect
    public let pixelSize: CGSize
    public let fragments: [CapturePixelFragment]

    public init(
        region: CGRect,
        pixelSize: CGSize,
        fragments: [CapturePixelFragment]
    ) {
        self.region = region
        self.pixelSize = pixelSize
        self.fragments = fragments
    }
}

public struct CaptureRegionPolicy: Equatable, Sendable {
    public static let minimumDimension: CGFloat = 8

    public init() {}

    public func region(from start: CGPoint, to end: CGPoint) -> CGRect? {
        let region = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        guard region.width >= Self.minimumDimension,
              region.height >= Self.minimumDimension else {
            return nil
        }
        return region
    }

    public func plan(
        region rawRegion: CGRect,
        displays: [CaptureDisplayGeometry]
    ) -> CaptureRegionPlan? {
        let region = rawRegion.standardized
        guard region.width >= Self.minimumDimension,
              region.height >= Self.minimumDimension else {
            return nil
        }

        let intersections = displays.compactMap { display -> (CaptureDisplayGeometry, CGRect)? in
            guard display.scale > 0,
                  display.frame.width > 0,
                  display.frame.height > 0 else {
                return nil
            }
            let intersection = region.intersection(display.frame)
            guard !intersection.isNull,
                  intersection.width > 0,
                  intersection.height > 0 else {
                return nil
            }
            return (display, intersection)
        }
        guard let outputScale = intersections.map({ $0.0.scale }).max() else {
            return nil
        }

        let fragments = intersections.map { display, intersection in
            CapturePixelFragment(
                displayID: display.id,
                sourcePointRect: CGRect(
                    x: intersection.minX - display.frame.minX,
                    y: display.frame.maxY - intersection.maxY,
                    width: intersection.width,
                    height: intersection.height
                ),
                sourcePixelSize: CGSize(
                    width: ceil(intersection.width * display.scale),
                    height: ceil(intersection.height * display.scale)
                ),
                destinationPixelRect: pixelAlignedRect(
                    CGRect(
                        x: (intersection.minX - region.minX) * outputScale,
                        y: (region.maxY - intersection.maxY) * outputScale,
                        width: intersection.width * outputScale,
                        height: intersection.height * outputScale
                    )
                )
            )
        }

        return CaptureRegionPlan(
            region: region,
            pixelSize: CGSize(
                width: ceil(region.width * outputScale),
                height: ceil(region.height * outputScale)
            ),
            fragments: fragments
        )
    }

    private func pixelAlignedRect(_ rect: CGRect) -> CGRect {
        let minX = floor(rect.minX)
        let minY = floor(rect.minY)
        return CGRect(
            x: minX,
            y: minY,
            width: ceil(rect.maxX) - minX,
            height: ceil(rect.maxY) - minY
        )
    }
}

public enum CaptureCallbackOutcome<Value: Sendable>: Sendable {
    case selected(Value)
    case cancelled
}

extension CaptureCallbackOutcome: Equatable where Value: Equatable {}

public final class CaptureCallbackGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: CaptureCallbackOutcome<Value>?
    private var waiters: [CheckedContinuation<CaptureCallbackOutcome<Value>, Never>] = []

    public init() {}

    @discardableResult
    public func resolve(_ outcome: CaptureCallbackOutcome<Value>) -> Bool {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return false
        }
        self.outcome = outcome
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()

        for waiter in waiters {
            waiter.resume(returning: outcome)
        }
        return true
    }

    public func value() async -> CaptureCallbackOutcome<Value> {
        await withTaskCancellationHandler {
            if Task.isCancelled {
                resolve(.cancelled)
            }
            return await withCheckedContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(returning: outcome)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            self.resolve(.cancelled)
        }
    }
}
