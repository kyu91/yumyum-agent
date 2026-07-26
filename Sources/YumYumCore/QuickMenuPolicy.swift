import CoreGraphics

public struct QuickMenuLayout: Equatable, Sendable {
    public static let petGap: CGFloat = 8

    public init() {}

    public func panelFrame(
        petFrame: CGRect,
        panelSize: CGSize,
        visibleFrames: [CGRect]
    ) -> CGRect {
        guard let visibleFrame = bestVisibleFrame(
            for: petFrame,
            visibleFrames: visibleFrames
        ) else {
            return CGRect(origin: petFrame.origin, size: panelSize)
        }

        let width = min(max(0, panelSize.width), max(0, visibleFrame.width))
        let height = min(max(0, panelSize.height), max(0, visibleFrame.height))
        let preferredX = petFrame.maxX - width
        let preferredAboveY = petFrame.maxY + Self.petGap
        let preferredY: CGFloat
        if preferredAboveY + height <= visibleFrame.maxY {
            preferredY = preferredAboveY
        } else {
            preferredY = petFrame.minY - height - Self.petGap
        }

        return CGRect(
            x: min(max(preferredX, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(preferredY, visibleFrame.minY), visibleFrame.maxY - height),
            width: width,
            height: height
        )
    }

    private func bestVisibleFrame(
        for petFrame: CGRect,
        visibleFrames: [CGRect]
    ) -> CGRect? {
        visibleFrames.max { first, second in
            let firstArea = intersectionArea(first, petFrame)
            let secondArea = intersectionArea(second, petFrame)
            if firstArea == secondArea, firstArea == 0 {
                return distanceSquared(from: first, to: petFrame)
                    > distanceSquared(from: second, to: petFrame)
            }
            return firstArea < secondArea
        }
    }

    private func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else {
            return 0
        }
        return intersection.width * intersection.height
    }

    private func distanceSquared(from first: CGRect, to second: CGRect) -> CGFloat {
        let deltaX = first.midX - second.midX
        let deltaY = first.midY - second.midY
        return deltaX * deltaX + deltaY * deltaY
    }
}

public struct QuickMenuActionState: Equatable, Sendable {
    public let isInputEnabled: Bool
    public let statusText: String

    public init(snapshot: AgentRegistrySnapshot, isBusy: Bool) {
        isInputEnabled = snapshot.canSend && !isBusy
        if let selected = snapshot.selectedInstallation {
            statusText = "\(selected.definitionID.displayName) 준비됨 · \(selected.path ?? "")"
        } else if snapshot.requiresExplicitReselection {
            statusText = "기존 에이전트를 사용할 수 없습니다. 다시 선택하세요."
        } else {
            statusText = "검증된 기본 에이전트를 선택하세요."
        }
    }
}
