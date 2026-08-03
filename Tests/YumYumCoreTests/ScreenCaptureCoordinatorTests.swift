import CoreGraphics
import Testing
@testable import YumYumApp
@testable import YumYumCore

@Suite
@MainActor
struct ScreenCaptureCoordinatorTests {
    @Test
    func authorizationUsesPreflightWithoutRequesting() throws {
        var requestCount = 0
        var authorization = ScreenCaptureAuthorizationPolicy(
            preflight: { true },
            request: {
                requestCount += 1
                return false
            }
        )

        try authorization.authorize()

        #expect(requestCount == 0)
    }

    @Test
    func authorizationRequestsOnlyOnceAfterRepeatedDenial() {
        var requestCount = 0
        var authorization = ScreenCaptureAuthorizationPolicy(
            preflight: { false },
            request: {
                requestCount += 1
                return false
            }
        )

        for _ in 0..<2 {
            #expect(throws: ScreenCaptureCoordinatorError.permissionDenied) {
                try authorization.authorize()
            }
        }

        #expect(requestCount == 1)
    }

    @Test
    func authorizationContinuesWhenFirstRequestSucceeds() throws {
        var requestCount = 0
        var authorization = ScreenCaptureAuthorizationPolicy(
            preflight: { false },
            request: {
                requestCount += 1
                return true
            }
        )

        try authorization.authorize()

        #expect(requestCount == 1)
    }

    @Test
    func authorizationDoesNotRequestAgainWhenPreflightRemainsFalseAfterSuccess() throws {
        var requestCount = 0
        var authorization = ScreenCaptureAuthorizationPolicy(
            preflight: { false },
            request: {
                requestCount += 1
                return true
            }
        )

        try authorization.authorize()
        #expect(throws: ScreenCaptureCoordinatorError.permissionDenied) {
            try authorization.authorize()
        }

        #expect(requestCount == 1)
    }

    @Test
    func authorizationUsesPreflightAfterDeniedRequest() throws {
        var hasAccess = false
        var requestCount = 0
        var authorization = ScreenCaptureAuthorizationPolicy(
            preflight: { hasAccess },
            request: {
                requestCount += 1
                return false
            }
        )

        #expect(throws: ScreenCaptureCoordinatorError.permissionDenied) {
            try authorization.authorize()
        }
        hasAccess = true
        try authorization.authorize()

        #expect(requestCount == 1)
    }

    @Test
    func authorizationUsesPreflightAfterSuccessfulRequest() throws {
        var hasAccess = false
        var requestCount = 0
        var authorization = ScreenCaptureAuthorizationPolicy(
            preflight: { hasAccess },
            request: {
                requestCount += 1
                return true
            }
        )

        try authorization.authorize()
        hasAccess = true
        try authorization.authorize()

        #expect(requestCount == 1)
    }

    @Test
    func freshAuthorizationPolicyMayRequestAgain() {
        var requestCount = 0
        for _ in 0..<2 {
            var authorization = ScreenCaptureAuthorizationPolicy(
                preflight: { false },
                request: {
                    requestCount += 1
                    return false
                }
            )
            #expect(throws: ScreenCaptureCoordinatorError.permissionDenied) {
                try authorization.authorize()
            }
        }

        #expect(requestCount == 2)
    }

    @Test
    func macOS15SingleRegionUsesScreenCaptureKitCoordinatesForEveryDragDirection() async throws {
        let fixture = makeSplitImage(
            width: 20,
            height: 16,
            top: .yellow,
            bottom: .purple
        )
        let corners = [
            (CGPoint(x: -6, y: -4), CGPoint(x: 4, y: 4)),
            (CGPoint(x: 4, y: -4), CGPoint(x: -6, y: 4)),
            (CGPoint(x: -6, y: 4), CGPoint(x: 4, y: -4)),
            (CGPoint(x: 4, y: 4), CGPoint(x: -6, y: -4)),
        ]
        let expectedRegion = CGRect(x: -6, y: -4, width: 10, height: 8)
        let expectedScreenCaptureKitRegion = CGRect(
            x: -6,
            y: 96,
            width: 10,
            height: 8
        )
        var requests: [CGRect] = []

        for (start, end) in corners {
            let region = try #require(CaptureRegionPolicy().region(from: start, to: end))
            #expect(region == expectedRegion)
            let image = try await ScreenCaptureCoordinator.captureSingleRegion(
                in: region,
                primaryDisplayMaxY: 100
            ) { request in
                requests.append(request)
                return fixture
            }
            #expect(image.width == 20)
            #expect(image.height == 16)
            #expect(sample(image, x: 10, topY: 1) == .yellow)
            #expect(sample(image, x: 10, topY: 14) == .purple)
        }

        #expect(requests == Array(repeating: expectedScreenCaptureKitRegion, count: 4))
    }

    @Test
    func macOS14FragmentsPreserveMixedScaleOrientationAndCrossDisplaySeams() async throws {
        let displays = [
            CaptureDisplayGeometry(
                id: 10,
                frame: CGRect(x: -40, y: 0, width: 40, height: 40),
                scale: 1
            ),
            CaptureDisplayGeometry(
                id: 20,
                frame: CGRect(x: 0, y: 0, width: 40, height: 40),
                scale: 2
            ),
            CaptureDisplayGeometry(
                id: 30,
                frame: CGRect(x: 0, y: 40, width: 40, height: 20),
                scale: 1
            ),
        ]
        let fixtures = [
            UInt32(10): makeSplitImage(width: 20, height: 20, top: .orange, bottom: .red),
            UInt32(20): makeSplitImage(width: 40, height: 40, top: .cyan, bottom: .blue),
            UInt32(30): makeSolidImage(width: 20, height: 10, color: .green),
        ]
        var requests: [CapturePixelFragment] = []
        var compositeCount = 0

        let image = try await ScreenCaptureCoordinator.captureDisplayFragments(
            in: CGRect(x: -20, y: 20, width: 40, height: 30),
            displays: displays,
            capture: { fragment in
                requests.append(fragment)
                return try #require(fixtures[fragment.displayID])
            },
            composite: { fragments, size in
                compositeCount += 1
                return try ScreenCaptureCoordinator.composite(fragments, size: size)
            }
        )

        #expect(requests == [
            CapturePixelFragment(
                displayID: 10,
                sourcePointRect: CGRect(x: 20, y: 0, width: 20, height: 20),
                sourcePixelSize: CGSize(width: 20, height: 20),
                destinationPixelRect: CGRect(x: 0, y: 20, width: 40, height: 40)
            ),
            CapturePixelFragment(
                displayID: 20,
                sourcePointRect: CGRect(x: 0, y: 0, width: 20, height: 20),
                sourcePixelSize: CGSize(width: 40, height: 40),
                destinationPixelRect: CGRect(x: 40, y: 20, width: 40, height: 40)
            ),
            CapturePixelFragment(
                displayID: 30,
                sourcePointRect: CGRect(x: 0, y: 10, width: 20, height: 10),
                sourcePixelSize: CGSize(width: 20, height: 10),
                destinationPixelRect: CGRect(x: 40, y: 0, width: 40, height: 20)
            ),
        ])
        #expect(compositeCount == 1)
        #expect(image.width == 80)
        #expect(image.height == 60)
        #expect(sample(image, x: 10, topY: 0) == .clear)
        #expect(sample(image, x: 50, topY: 0) == .green)
        #expect(sample(image, x: 10, topY: 20) == .orange)
        #expect(sample(image, x: 10, topY: 59) == .red)
        #expect(sample(image, x: 50, topY: 20) == .cyan)
        #expect(sample(image, x: 50, topY: 59) == .blue)
        #expect(sample(image, x: 39, topY: 30).alpha == 255)
        #expect(sample(image, x: 40, topY: 30).alpha == 255)
    }

    @Test
    func cancellingSingleRegionCaptureRejectsTheLateImageCallback() async {
        let fixture = SuspendedImageCapture()
        let task = Task { @MainActor in
            try await ScreenCaptureCoordinator.captureSingleRegion(
                in: CGRect(x: 10, y: 20, width: 30, height: 40),
                primaryDisplayMaxY: 100,
                capture: fixture.capture
            )
        }
        await fixture.waitUntilStarted()

        task.cancel()
        fixture.resume(with: makeSolidImage(width: 60, height: 80, color: .red))

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }
}

@MainActor
private final class SuspendedImageCapture {
    private var continuation: CheckedContinuation<CGImage, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func capture(_ rect: CGRect) async throws -> CGImage {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume(with image: CGImage) {
        continuation?.resume(returning: image)
        continuation = nil
    }
}

private struct Pixel: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    static let clear = Pixel(red: 0, green: 0, blue: 0, alpha: 0)
    static let red = Pixel(red: 255, green: 0, blue: 0, alpha: 255)
    static let orange = Pixel(red: 255, green: 128, blue: 0, alpha: 255)
    static let yellow = Pixel(red: 255, green: 255, blue: 0, alpha: 255)
    static let green = Pixel(red: 0, green: 255, blue: 0, alpha: 255)
    static let cyan = Pixel(red: 0, green: 255, blue: 255, alpha: 255)
    static let blue = Pixel(red: 0, green: 0, blue: 255, alpha: 255)
    static let purple = Pixel(red: 128, green: 0, blue: 255, alpha: 255)

    var components: [CGFloat] {
        [red, green, blue, alpha].map { CGFloat($0) / 255 }
    }
}

private func makeSolidImage(width: Int, height: Int, color: Pixel) -> CGImage {
    makeImage(width: width, height: height) { context in
        context.setFillColor(CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: color.components
        )!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

private func makeSplitImage(
    width: Int,
    height: Int,
    top: Pixel,
    bottom: Pixel
) -> CGImage {
    makeImage(width: width, height: height) { context in
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        context.setFillColor(CGColor(colorSpace: colorSpace, components: bottom.components)!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(colorSpace: colorSpace, components: top.components)!)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
    }
}

private func makeImage(
    width: Int,
    height: Int,
    draw: (CGContext) -> Void
) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .none
    draw(context)
    return context.makeImage()!
}

private func sample(_ image: CGImage, x: Int, topY: Int) -> Pixel {
    var bytes = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &bytes,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .none
    context.translateBy(
        x: -CGFloat(x),
        y: -CGFloat(image.height - topY - 1)
    )
    context.draw(
        image,
        in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
    return Pixel(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes[3])
}
