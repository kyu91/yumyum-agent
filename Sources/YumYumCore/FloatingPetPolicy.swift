import CoreGraphics
import Foundation

public struct FloatingPetLayout: Equatable, Sendable {
    public static let preferredSize = CGSize(width: 96, height: 96)
    public static let edgeInset: CGFloat = 20

    public init() {}

    public func initialFrame(in visibleFrame: CGRect) -> CGRect {
        let frame = CGRect(
            x: visibleFrame.maxX - Self.preferredSize.width - Self.edgeInset,
            y: visibleFrame.minY + Self.edgeInset,
            width: Self.preferredSize.width,
            height: Self.preferredSize.height
        )
        return clampedFrame(frame, inside: visibleFrame)
    }

    public func clampedFrame(_ frame: CGRect, inside visibleFrame: CGRect) -> CGRect {
        let width = min(max(frame.width, 0), max(visibleFrame.width, 0))
        let height = min(max(frame.height, 0), max(visibleFrame.height, 0))
        let x = min(
            max(frame.minX, visibleFrame.minX),
            visibleFrame.maxX - width
        )
        let y = min(
            max(frame.minY, visibleFrame.minY),
            visibleFrame.maxY - height
        )

        return CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct FloatingPetVisibilityPolicy: Equatable, Sendable {
    public private(set) var isVisible: Bool

    public init(isVisible: Bool = true) {
        self.isVisible = isVisible
    }

    public mutating func toggle() {
        isVisible.toggle()
    }

    public mutating func setVisible(_ isVisible: Bool) {
        self.isVisible = isVisible
    }
}

package struct PetDropLifecycle: Equatable, Sendable {
    private var generation: UUID?

    package init() {}

    package var isHovering: Bool { generation != nil }

    @discardableResult
    package mutating func enter(isAccepted: Bool) -> UUID? {
        generation = isAccepted ? UUID() : nil
        return generation
    }

    @discardableResult
    package mutating func exit(_ owner: UUID?) -> Bool {
        cancel(owner)
    }

    @discardableResult
    package mutating func cancel(_ owner: UUID?) -> Bool {
        guard generation == owner, owner != nil else {
            return false
        }
        generation = nil
        return true
    }

    package mutating func consume(_ candidate: UUID?) -> Bool {
        guard let candidate, candidate == generation else {
            return false
        }
        generation = nil
        return true
    }
}
