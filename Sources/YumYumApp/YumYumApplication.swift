import AppKit
import SwiftUI
import YumYumCore

@main
@MainActor
struct YumYumApplication: App {
    @StateObject private var viewModel: YumYumAppViewModel

    init() {
        let service = FixtureProbeService(fixtureURL: Self.fixtureURL)
        _viewModel = StateObject(
            wrappedValue: YumYumAppViewModel(fixtureProbe: service)
        )
    }

    var body: some Scene {
        Window("YumYum", id: "main") {
            YumYumContentView(viewModel: viewModel)
        }
        .defaultSize(width: 560, height: 570)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("YumYum", systemImage: "takeoutbag.and.cup.and.straw.fill") {
            YumYumMenu(viewModel: viewModel)
        }
    }

    private static var fixtureURL: URL {
        if Bundle.main.bundleURL.pathExtension == "app",
           let resourcesURL = Bundle.main.resourceURL {
            return resourcesURL.appendingPathComponent(
                FixtureProbeService.fixtureExecutableName,
                isDirectory: false
            )
        }
        if let executableURL = Bundle.main.executableURL {
            return executableURL.deletingLastPathComponent().appendingPathComponent(
                FixtureProbeService.fixtureExecutableName,
                isDirectory: false
            )
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug", isDirectory: true)
            .appendingPathComponent(
                FixtureProbeService.fixtureExecutableName,
                isDirectory: false
            )
    }
}

private struct YumYumMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var viewModel: YumYumAppViewModel

    var body: some View {
        Button("YumYum 열기") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Divider()

        Text(menuStatus)
        Text("외부 변경: 비활성화")

        Divider()

        Button("YumYum 종료") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var menuStatus: String {
        switch viewModel.probeState {
        case .idle:
            return "Fixture probe: 대기"
        case .loading:
            return "Fixture probe: 실행 중"
        case .success:
            return "Fixture probe: 성공"
        case .failure:
            return "Fixture probe: 오류"
        }
    }
}

private struct YumYumContentView: View {
    @ObservedObject var viewModel: YumYumAppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            hermesPathSection
            fixtureSection
            safetySection
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 520, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "takeoutbag.and.cup.and.straw.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("YumYum")
                    .font(.title.bold())
                Text("macOS 제품 셸")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("PHASE 0")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.orange.opacity(0.12), in: Capsule())
                .accessibilityLabel("Phase 0")
        }
    }

    private var hermesPathSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                TextField("/absolute/path/to/hermes", text: $viewModel.hermesPath)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Hermes 실행 파일 절대 경로")

                Label(pathStatusText, systemImage: pathStatusIcon)
                    .font(.callout)
                    .foregroundStyle(pathStatusColor)

                Text("경로는 현재 세션의 화면에만 유지되며 저장하거나 실행하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Label("Hermes 경로", systemImage: "terminal")
                .font(.headline)
        }
    }

    private var fixtureSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("실제 Hermes 대신 패키지의 결정적 fixture에 `--version`만 전달합니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(viewModel.fixturePath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(viewModel.fixturePath)

                probeStatus

                Button {
                    Task {
                        await viewModel.runFixtureProbe()
                    }
                } label: {
                    Label("안전한 Fixture Probe 실행", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.probeState == .loading)
                .accessibilityHint("패키지에 포함된 테스트 fixture의 버전만 확인합니다")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Label("로컬 안전 점검", systemImage: "checkmark.shield")
                .font(.headline)
        }
    }

    @ViewBuilder
    private var probeStatus: some View {
        switch viewModel.probeState {
        case .idle:
            Label("Probe 대기 중", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Fixture 확인 중…")
            }
            .accessibilityElement(children: .combine)
        case let .success(version):
            VStack(alignment: .leading, spacing: 4) {
                Label("Fixture probe 성공", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(version)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        case let .failure(message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Fixture probe 오류", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
    }

    private var safetySection: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("외부 변경 기능")
                        .font(.callout.weight(.semibold))
                    Text("DISABLED · FAIL-CLOSED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text("실제 Hermes, 네트워크, 캘린더와 자격증명에는 접근하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 2)
    }

    private var pathStatusText: String {
        switch viewModel.hermesPathStatus {
        case .empty:
            return "절대 경로 문자열을 직접 입력하세요. 자동 탐색은 꺼져 있습니다."
        case .invalidAbsolutePath:
            return "상대 경로는 허용하지 않습니다. `/`로 시작하는 경로를 입력하세요."
        case .absolutePathNotConnected:
            return "절대 경로 형식만 확인했습니다. 실제 연결은 비활성화되어 있습니다."
        }
    }

    private var pathStatusIcon: String {
        switch viewModel.hermesPathStatus {
        case .empty:
            return "info.circle"
        case .invalidAbsolutePath:
            return "exclamationmark.triangle"
        case .absolutePathNotConnected:
            return "lock.fill"
        }
    }

    private var pathStatusColor: Color {
        switch viewModel.hermesPathStatus {
        case .empty, .absolutePathNotConnected:
            return .secondary
        case .invalidAbsolutePath:
            return .orange
        }
    }
}
