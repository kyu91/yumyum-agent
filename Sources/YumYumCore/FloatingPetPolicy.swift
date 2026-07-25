import CoreGraphics

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
