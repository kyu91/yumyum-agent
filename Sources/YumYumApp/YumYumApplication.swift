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
        .defaultSize(width: 600, height: 680)
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
        switch viewModel.connectionState {
        case .idle:
            return "Hermes 연결: 확인 전"
        case .loading:
            return "Hermes 연결: 확인 중"
        case .success:
            return "Hermes 연결: 성공"
        case .pathError:
            return "Hermes 연결: 경로 오류"
        case .executionError:
            return "Hermes 연결: 실행 오류"
        case .timedOut:
            return "Hermes 연결: 시간 초과"
        }
    }
}

private struct YumYumContentView: View {
    @ObservedObject var viewModel: YumYumAppViewModel
    @State private var connectionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            hermesPathSection
            safetySection
            fixtureSection
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 620, alignment: .topLeading)
        .onDisappear {
            connectionTask?.cancel()
        }
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
                Text("Hermes 로컬 연결 확인")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("LOCAL ONLY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.orange.opacity(0.12), in: Capsule())
                .accessibilityLabel("Local only")
        }
    }

    private var hermesPathSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                TextField("/absolute/path/to/hermes", text: $viewModel.hermesPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.connectionState == .loading)
                    .accessibilityLabel("Hermes 실행 파일 절대 경로")
                    .accessibilityIdentifier("hermes-path-field")

                Label(pathStatusText, systemImage: pathStatusIcon)
                    .font(.callout)
                    .foregroundStyle(pathStatusColor)

                connectionStatus
                    .accessibilityIdentifier("hermes-connection-status")

                HStack(spacing: 10) {
                    Button {
                        connectionTask = Task { @MainActor in
                            await viewModel.checkHermesConnection()
                            connectionTask = nil
                        }
                    } label: {
                        Label("연결 확인", systemImage: "bolt.horizontal.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canCheckHermesConnection)
                    .accessibilityIdentifier("check-hermes-connection-button")
                    .accessibilityHint("선택한 실행 파일에 --version 인자만 전달합니다")

                    if viewModel.connectionState == .loading {
                        Button("취소") {
                            connectionTask?.cancel()
                        }
                        .accessibilityIdentifier("cancel-hermes-connection-button")
                    }
                }

                Text("경로는 저장하지 않습니다. 연결 확인은 선택한 실행 파일에 `--version` 인자만 직접 전달합니다.")
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
                Text("주 연결과 분리된 패키지 fixture에 `--version`을 전달해 개발 환경만 점검합니다.")
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
                    Label("Fixture Probe 실행", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.probeState == .loading)
                .accessibilityHint("패키지에 포함된 테스트 fixture의 버전만 확인합니다")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Label("개발 진단", systemImage: "wrench.and.screwdriver")
                .font(.headline)
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch viewModel.connectionState {
        case .idle:
            Label("연결 확인 전", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Hermes --version 확인 중…")
            }
            .accessibilityElement(children: .combine)
        case let .success(version):
            VStack(alignment: .leading, spacing: 4) {
                Label("Hermes 연결 확인 성공", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(verbatim: version)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .pathError(message):
            connectionError(
                title: "Hermes 경로 오류",
                message: message,
                systemImage: "folder.badge.questionmark"
            )
        case let .executionError(message):
            connectionError(
                title: "Hermes 실행 오류",
                message: message,
                systemImage: "xmark.octagon.fill"
            )
        case .timedOut:
            connectionError(
                title: "Hermes 연결 확인 시간 초과",
                message: "Hermes가 제한 시간 안에 응답하지 않았습니다.",
                systemImage: "clock.badge.exclamationmark"
            )
        }
    }

    private func connectionError(
        title: String,
        message: String,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
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
                    Text("연결 확인 외 기능")
                        .font(.callout.weight(.semibold))
                    Text("DISABLED · FAIL-CLOSED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text("ACP, 네트워크, 캘린더, 자격증명 및 외부 변경 기능에는 접근하지 않습니다.")
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
        case .absolutePathReady:
            return "절대 경로 형식을 확인했습니다. 연결 확인을 실행할 수 있습니다."
        }
    }

    private var pathStatusIcon: String {
        switch viewModel.hermesPathStatus {
        case .empty:
            return "info.circle"
        case .invalidAbsolutePath:
            return "exclamationmark.triangle"
        case .absolutePathReady:
            return "checkmark.circle"
        }
    }

    private var pathStatusColor: Color {
        switch viewModel.hermesPathStatus {
        case .empty, .absolutePathReady:
            return .secondary
        case .invalidAbsolutePath:
            return .orange
        }
    }
}
