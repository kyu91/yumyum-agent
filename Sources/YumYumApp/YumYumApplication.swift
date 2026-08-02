import AppKit
import SwiftUI
import YumYumCore

@main
@MainActor
struct YumYumApplication: App {
    @NSApplicationDelegateAdaptor(YumYumAppDelegate.self) private var appDelegate
    @StateObject private var viewModel: YumYumAppViewModel

    init() {
        CaptureTemporaryFileCleanup.removeStaleFiles()
        let service = FixtureProbeService(fixtureURL: Self.fixtureURL)
        let viewModel = YumYumAppViewModel(fixtureProbe: service)
        _viewModel = StateObject(wrappedValue: viewModel)
        appDelegate.configure(viewModel: viewModel)
    }

    var body: some Scene {
        Window("YumYum Agent", id: "main") {
            YumYumContentView(viewModel: viewModel, appDelegate: appDelegate)
                .preferredColorScheme(appDelegate.currentTheme.colorScheme)
                .background {
                    MainWindowActionInstaller(
                        appDelegate: appDelegate,
                        viewModel: viewModel
                    )
                }
        }
        .defaultSize(width: 640, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("YumYum Agent", systemImage: "takeoutbag.and.cup.and.straw.fill") {
            YumYumMenu(viewModel: viewModel, appDelegate: appDelegate)
                .preferredColorScheme(appDelegate.currentTheme.colorScheme)
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

private struct MainWindowActionInstaller: View {
    @Environment(\.openWindow) private var openWindow

    let appDelegate: YumYumAppDelegate
    let viewModel: YumYumAppViewModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                appDelegate.configure(viewModel: viewModel)
                appDelegate.setOpenMainWindowAction {
                    openWindow(id: "main")
                }
            }
            .accessibilityHidden(true)
    }
}

private struct YumYumMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var viewModel: YumYumAppViewModel
    @ObservedObject var appDelegate: YumYumAppDelegate

    var body: some View {
        Button(AppText.localized("YumYum Agent 열기")) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Toggle(
            AppText.localized("플로팅 펫 보이기"),
            isOn: Binding(
                get: { appDelegate.petVisibility.isVisible },
                set: { appDelegate.setPetVisible($0) }
            )
        )
        .accessibilityHint(AppText.localized("화면 우하단의 YumYum Agent 펫 표시 여부를 전환합니다"))

        Button(AppText.localized("빠른 메뉴 열기")) {
            appDelegate.showQuickMenu()
        }

        Divider()

        Text(menuStatus)
        Text(AppText.localized("외부 변경: 비활성화"))

        Divider()

        Button(AppText.localized("YumYum Agent 종료")) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var menuStatus: String {
        if let selected = viewModel.agentSnapshot.selectedInstallation {
            return AppText.localized(
                english: "Default agent: \(selected.definitionID.displayName)",
                korean: "기본 에이전트: \(selected.definitionID.displayName)"
            )
        }
        if viewModel.agentSnapshot.requiresExplicitReselection {
            return AppText.localized("기본 에이전트: 다시 선택 필요")
        }
        switch viewModel.connectionState {
        case .idle:
            return AppText.localized("Hermes 연결: 확인 전")
        case .loading:
            return AppText.localized("Hermes 연결: 확인 중")
        case .success:
            return AppText.localized("Hermes 연결: 성공")
        case .pathError:
            return AppText.localized("Hermes 연결: 경로 오류")
        case .executionError:
            return AppText.localized("Hermes 연결: 실행 오류")
        case .timedOut:
            return AppText.localized("Hermes 연결: 시간 초과")
        }
    }
}

private struct YumYumContentView: View {
    @ObservedObject var viewModel: YumYumAppViewModel
    @ObservedObject var appDelegate: YumYumAppDelegate
    @State private var connectionTask: Task<Void, Never>?
    @State private var explicitAgentID = AgentDefinitionID.hermes
    @State private var explicitAgentPath = ""
    @State private var soulProfile = SoulProfile.empty
    @State private var soulSaveTask: Task<Void, Never>?
    @State private var confirmsSoulReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header.padding(.horizontal, 24).padding(.top, 18)
            TabView {
                settingsScroll {
                    languageSection
                    themeSection
                    shortcutSection
                    safetySection
                }
                .tabItem { Label(AppText.localized(english: "General", korean: "일반"), systemImage: "gearshape") }
                .accessibilityIdentifier("settings-tab-general")

                settingsScroll { agentSection }
                    .tabItem { Label(AppText.localized(english: "Agent", korean: "에이전트"), systemImage: "cpu") }
                    .accessibilityIdentifier("settings-tab-agent")

                settingsScroll { soulSection }
                    .tabItem { Label("Soul", systemImage: "heart.text.square") }
                    .accessibilityIdentifier("settings-tab-soul")

                settingsScroll {
                    hermesPathSection
                    fixtureSection
                }
                .tabItem { Label(AppText.localized(english: "Diagnostics", korean: "진단"), systemImage: "stethoscope") }
                .accessibilityIdentifier("settings-tab-diagnostics")
            }
        }
        .frame(minWidth: 560, minHeight: 620, alignment: .topLeading)
        .onAppear {
            appDelegate.configure(viewModel: viewModel)
        }
        .task {
            await viewModel.refreshAgents(trigger: .appStart)
            await viewModel.loadSoul()
            soulProfile = viewModel.soulProfile
        }
        .onDisappear {
            connectionTask?.cancel()
            soulSaveTask?.cancel()
            Task { await viewModel.flushSoul() }
        }
        .confirmationDialog(
            AppText.localized("Soul 설정을 초기화할까요?"),
            isPresented: $confirmsSoulReset,
            titleVisibility: .visible
        ) {
            Button(AppText.localized("초기화"), role: .destructive) {
                soulProfile = .empty
                viewModel.updateSoulDraft(.empty)
                soulSaveTask?.cancel()
                Task { await viewModel.resetSoul() }
            }
            Button(AppText.localized("취소"), role: .cancel) {}
        }
    }

    private func settingsScroll<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content() }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var soulSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                AppText.localized("비밀, 자격증명 또는 민감한 개인정보를 입력하지 마세요."),
                systemImage: "exclamationmark.shield"
            )
            .foregroundStyle(.orange)
            .accessibilityIdentifier("soul-sensitive-data-warning")

            soulField(AppText.localized("이름"), keyPath: \.name, identifier: "soul-name")
            soulField(AppText.localized("역할 / 정체성"), keyPath: \.role, identifier: "soul-role")
            soulField(AppText.localized("성격"), keyPath: \.personality, identifier: "soul-personality")
            soulField(AppText.localized("말투"), keyPath: \.speakingStyle, identifier: "soul-speaking-style")
            soulField(AppText.localized("핵심 가치"), keyPath: \.coreValues, identifier: "soul-core-values")
            soulField(AppText.localized("좋아하는 것"), keyPath: \.likes, identifier: "soul-likes")
            soulField(AppText.localized("싫어하거나 피할 것"), keyPath: \.dislikes, identifier: "soul-dislikes")
            soulField(AppText.localized("사용자를 부르는 호칭"), keyPath: \.userAddress, identifier: "soul-user-address")
            soulField(AppText.localized("행동 원칙"), keyPath: \.behaviorPrinciples, identifier: "soul-behavior-principles")
            soulField(AppText.localized("추가 지침"), keyPath: \.additionalInstructions, identifier: "soul-additional-instructions")

            if soulProfile != soulProfile.normalized {
                Text(AppText.localized("저장 시 공백을 정리하고 필드당 2,000자, 전체 12,000자로 제한합니다."))
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("soul-normalization-warning")
            }

            HStack {
                Label(soulSaveText, systemImage: soulSaveIcon)
                    .font(.callout)
                    .foregroundStyle(viewModel.soulSaveState == .failed ? .red : .secondary)
                    .accessibilityIdentifier("soul-save-status")
                Spacer()
                Button(AppText.localized("기본값으로 초기화"), role: .destructive) {
                    confirmsSoulReset = true
                }
                .accessibilityIdentifier("soul-reset-button")
            }
        }
        .disabled(!viewModel.isSoulLoaded)
    }

    private func soulField(
        _ title: String,
        keyPath: KeyPath<SoulProfile, String>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.semibold))
            TextEditor(text: Binding(
                get: { soulProfile[keyPath: keyPath] },
                set: { value in
                    soulProfile = replacingSoulField(keyPath, with: value)
                    viewModel.updateSoulDraft(soulProfile)
                    scheduleSoulSave()
                }
            ))
            .font(.body)
            .frame(minHeight: title == AppText.localized("이름") ? 38 : 64)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
        }
    }

    private func replacingSoulField(
        _ keyPath: KeyPath<SoulProfile, String>,
        with value: String
    ) -> SoulProfile {
        return SoulProfile(
            name: keyPath == \.name ? value : soulProfile.name,
            role: keyPath == \.role ? value : soulProfile.role,
            personality: keyPath == \.personality ? value : soulProfile.personality,
            speakingStyle: keyPath == \.speakingStyle ? value : soulProfile.speakingStyle,
            coreValues: keyPath == \.coreValues ? value : soulProfile.coreValues,
            likes: keyPath == \.likes ? value : soulProfile.likes,
            dislikes: keyPath == \.dislikes ? value : soulProfile.dislikes,
            userAddress: keyPath == \.userAddress ? value : soulProfile.userAddress,
            behaviorPrinciples: keyPath == \.behaviorPrinciples ? value : soulProfile.behaviorPrinciples,
            additionalInstructions: keyPath == \.additionalInstructions
                ? value
                : soulProfile.additionalInstructions
        )
    }

    private func scheduleSoulSave() {
        soulSaveTask?.cancel()
        soulSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await viewModel.saveSoul()
        }
    }

    private var soulSaveText: String {
        switch viewModel.soulSaveState {
        case .idle: AppText.localized("저장된 Soul을 불러왔습니다")
        case .saving: AppText.localized("저장 중…")
        case .saved: AppText.localized("저장됨")
        case .savedWithNormalization: AppText.localized("정리 및 길이 제한 후 저장됨")
        case .failed: AppText.localized("저장할 수 없습니다")
        }
    }

    private var soulSaveIcon: String {
        switch viewModel.soulSaveState {
        case .idle: "doc"
        case .saving: "arrow.triangle.2.circlepath"
        case .saved: "checkmark.circle"
        case .savedWithNormalization: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var themeSection: some View {
        GroupBox {
            Picker(
                AppText.localized("테마"),
                selection: Binding(
                    get: { appDelegate.currentTheme },
                    set: { appDelegate.setTheme($0) }
                )
            ) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .id(appDelegate.currentLanguage)
            .accessibilityHint(AppText.localized("YumYum Agent 화면의 밝은 테마와 어두운 테마를 전환합니다"))
            .padding(.top, 4)
        } label: {
            Label(AppText.localized("화면 테마"), systemImage: "circle.lefthalf.filled")
                .font(.headline)
        }
    }

    private var languageSection: some View {
        GroupBox {
            Picker(
                AppText.localized(english: "Language", korean: "언어"),
                selection: Binding(
                    get: { appDelegate.currentLanguage },
                    set: { appDelegate.setLanguage($0) }
                )
            ) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings-language-picker")
            .accessibilityHint(AppText.localized(
                english: "Changes the YumYum Agent interface language immediately.",
                korean: "YumYum Agent 화면 언어를 즉시 변경합니다."
            ))
            .padding(.top, 4)
        } label: {
            Label(
                AppText.localized(english: "Language", korean: "언어"),
                systemImage: "globe"
            )
            .font(.headline)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "takeoutbag.and.cup.and.straw.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("YumYum Agent")
                    .font(.title.bold())
                Text(AppText.localized("검증된 로컬 에이전트와 빠른 메뉴"))
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

    private var agentSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if viewModel.isDiscoveringAgents {
                    ProgressView(AppText.localized("안전한 설치 경로 확인 중…"))
                        .controlSize(.small)
                }

                ForEach(viewModel.agentSnapshot.installations) { installation in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: installation.availability == .available
                            ? "checkmark.circle.fill"
                            : "xmark.circle")
                            .foregroundStyle(installation.availability == .available ? .green : .secondary)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(installation.definitionID.displayName)
                                .font(.callout.weight(.semibold))
                            Text(installation.path ?? AppText.localized("안전한 설치 경로에서 찾지 못함"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(agentDetail(installation))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(
                            viewModel.agentSnapshot.selectedInstallation?.id == installation.id
                                ? AppText.localized("선택됨")
                                : AppText.localized("기본으로 선택")
                        ) {
                            guard let path = installation.path else { return }
                            Task {
                                try? await viewModel.selectAgent(
                                    installation.definitionID,
                                    path: path
                                )
                            }
                        }
                        .disabled(
                            installation.availability != .available
                                || viewModel.agentSnapshot.selectedInstallation?.id == installation.id
                        )
                    }
                    Divider()
                }

                HStack {
                    Picker(AppText.localized("에이전트"), selection: $explicitAgentID) {
                        ForEach(AgentDefinitionID.allCases, id: \.self) { definitionID in
                            Text(definitionID.displayName).tag(definitionID)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)

                    TextField("/absolute/path/to/executable", text: $explicitAgentPath)
                        .textFieldStyle(.roundedBorder)

                    Button(AppText.localized("경로 확인")) {
                        let path = explicitAgentPath.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard NSString(string: path).isAbsolutePath else { return }
                        Task {
                            await viewModel.addExplicitAgentPath(path, for: explicitAgentID)
                        }
                    }
                    .disabled(
                        !NSString(
                            string: explicitAgentPath.trimmingCharacters(in: .whitespacesAndNewlines)
                        ).isAbsolutePath
                    )
                }

                Button(AppText.localized("다시 검색")) {
                    Task { await viewModel.refreshAgents(trigger: .manualRescan) }
                }
                .disabled(viewModel.isDiscoveringAgents)
            }
            .padding(.top, 4)
        } label: {
            Label(AppText.localized("로컬 에이전트"), systemImage: "cpu")
                .font(.headline)
        }
    }

    private var shortcutSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker(
                    AppText.localized("빠른 메뉴 전역 단축키"),
                    selection: Binding(
                        get: { appDelegate.shortcutChoice },
                        set: { appDelegate.setShortcutChoice($0) }
                    )
                ) {
                    ForEach(GlobalShortcutChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint(AppText.localized("포커스를 강제로 가져오지 않고 펫 옆 빠른 메뉴를 엽니다"))

                Button(AppText.localized("빠른 메뉴 지금 열기")) {
                    appDelegate.showQuickMenu()
                }
            }
            .padding(.top, 4)
        } label: {
            Label(AppText.localized("빠른 메뉴"), systemImage: "keyboard")
                .font(.headline)
        }
    }

    private func agentDetail(_ installation: AgentInstallation) -> String {
        switch installation.availability {
        case .available:
            return installation.version ?? AppText.localized("버전 확인 완료")
        case let .unavailable(reason):
            return reason
        }
    }

    private var hermesPathSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                TextField("/absolute/path/to/hermes", text: $viewModel.hermesPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.connectionState == .loading)
                    .accessibilityLabel(AppText.localized("Hermes 실행 파일 절대 경로"))
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
                        Label(AppText.localized("연결 확인"), systemImage: "bolt.horizontal.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canCheckHermesConnection)
                    .accessibilityIdentifier("check-hermes-connection-button")
                    .accessibilityHint(AppText.localized("선택한 실행 파일에 --version 인자만 전달합니다"))

                    if viewModel.connectionState == .loading {
                        Button(AppText.localized("취소")) {
                            connectionTask?.cancel()
                        }
                        .accessibilityIdentifier("cancel-hermes-connection-button")
                    }
                }

                Text(AppText.localized("경로는 저장하지 않습니다. 연결 확인은 선택한 실행 파일에 `--version` 인자만 직접 전달합니다."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Label(AppText.localized("Hermes 수동 경로 진단"), systemImage: "terminal")
                .font(.headline)
        }
    }

    private var fixtureSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppText.localized("주 연결과 분리된 패키지 fixture에 `--version`을 전달해 개발 환경만 점검합니다."))
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
                    Label(AppText.localized("Fixture Probe 실행"), systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.probeState == .loading)
                .accessibilityHint(AppText.localized("패키지에 포함된 테스트 fixture의 버전만 확인합니다"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Label(AppText.localized("개발 진단"), systemImage: "wrench.and.screwdriver")
                .font(.headline)
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch viewModel.connectionState {
        case .idle:
            Label(AppText.localized("연결 확인 전"), systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(AppText.localized("Hermes --version 확인 중…"))
            }
            .accessibilityElement(children: .combine)
        case let .success(version):
            VStack(alignment: .leading, spacing: 4) {
                Label(AppText.localized("Hermes 연결 확인 성공"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(verbatim: version)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .pathError(message):
            connectionError(
                title: AppText.localized("Hermes 경로 오류"),
                message: message,
                systemImage: "folder.badge.questionmark"
            )
        case let .executionError(message):
            connectionError(
                title: AppText.localized("Hermes 실행 오류"),
                message: message,
                systemImage: "xmark.octagon.fill"
            )
        case .timedOut:
            connectionError(
                title: AppText.localized("Hermes 연결 확인 시간 초과"),
                message: AppText.localized("Hermes가 제한 시간 안에 응답하지 않았습니다."),
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
            Label(AppText.localized("Probe 대기 중"), systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(AppText.localized("Fixture 확인 중…"))
            }
            .accessibilityElement(children: .combine)
        case let .success(version):
            VStack(alignment: .leading, spacing: 4) {
                Label(AppText.localized("Fixture probe 성공"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(version)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        case let .failure(message):
            VStack(alignment: .leading, spacing: 4) {
                Label(AppText.localized("Fixture probe 오류"), systemImage: "xmark.octagon.fill")
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
                    Text(AppText.localized("외부 변경"))
                        .font(.callout.weight(.semibold))
                    Text("TASK-SCOPED APPROVAL · FAIL-CLOSED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text(AppText.localized("YumYum Agent는 자격증명을 읽지 않으며 외부 변경은 Task 한정 일회성 승인 전까지 차단합니다."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 2)
    }

    private var pathStatusText: String {
        switch viewModel.hermesPathStatus {
        case .empty:
            return AppText.localized("자동 발견 결과와 별개로 진단할 Hermes 절대 경로를 입력할 수 있습니다.")
        case .invalidAbsolutePath:
            return AppText.localized("상대 경로는 허용하지 않습니다. `/`로 시작하는 경로를 입력하세요.")
        case .absolutePathReady:
            return AppText.localized("절대 경로 형식을 확인했습니다. 연결 확인을 실행할 수 있습니다.")
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
