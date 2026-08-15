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

        MenuBarExtra {
            YumYumMenu(viewModel: viewModel, appDelegate: appDelegate)
                .preferredColorScheme(appDelegate.currentTheme.colorScheme)
        } label: {
            Image(nsImage: Self.menuBarMascotImage)
                .accessibilityLabel("YumYum Agent")
        }
    }

    fileprivate static let menuBarMascotImage: NSImage = {
        let image = NSImage(named: "MenuBarMascot") ?? NSImage()
        image.isTemplate = true
        return image
    }()

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
        MainWindowRegistrationViewRepresentable(appDelegate: appDelegate)
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

struct MainWindowRegistrationViewRepresentable: NSViewRepresentable {
    let appDelegate: YumYumAppDelegate

    func makeNSView(context: Context) -> MainWindowRegistrationView {
        MainWindowRegistrationView { [weak appDelegate] window in
            appDelegate?.registerMainWindow(window)
        }
    }

    func updateNSView(_ nsView: MainWindowRegistrationView, context: Context) {}
}

@MainActor
final class MainWindowRegistrationView: NSView {
    private let register: @MainActor (NSWindow) -> Void

    init(register: @escaping @MainActor (NSWindow) -> Void) {
        self.register = register
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            register(window)
        }
    }
}

private struct YumYumMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var viewModel: YumYumAppViewModel
    @ObservedObject var appDelegate: YumYumAppDelegate

    var body: some View {
        Button(AppText.localized("설정…")) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        .keyboardShortcut(",", modifiers: .command)

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
    @State private var agentExecutablePanel: NSOpenPanel?
    @State private var agentToRegister = AgentDefinitionID.hermes
    @State private var soulProfile = SoulProfile.empty
    @State private var soulSaveTask: Task<Void, Never>?
    @State private var confirmsSoulReset = false
    @State private var confirmsCodexLogin = false
    @State private var codexLoginApproval: CodexLoginApprovalRequest?
    @State private var showsPermissionOnboarding = false

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
                .tabItem {
                    Label {
                        Text(AppText.localized(english: "General", korean: "일반"))
                    } icon: {
                        Image(nsImage: YumYumApplication.menuBarMascotImage)
                    }
                }
                .accessibilityIdentifier("settings-tab-general")

                settingsScroll { agentSection }
                    .tabItem { Label(AppText.localized(english: "Agent", korean: "에이전트"), systemImage: "pawprint") }
                    .accessibilityIdentifier("settings-tab-agent")

                settingsScroll { soulSection }
                    .tabItem { Label("Soul", systemImage: "heart.fill") }
                    .accessibilityIdentifier("settings-tab-soul")

                settingsScroll {
                    hermesPathSection
                    fixtureSection
                }
                .tabItem { Label(AppText.localized(english: "Diagnostics", korean: "진단"), systemImage: "wrench.adjustable") }
                .accessibilityIdentifier("settings-tab-diagnostics")
            }
        }
        .preferredColorScheme(appDelegate.currentTheme.colorScheme)
        .frame(minWidth: 560, minHeight: 620, alignment: .topLeading)
        .onAppear {
            appDelegate.configure(viewModel: viewModel)
        }
        .task {
            await viewModel.refreshAgents(trigger: .appStart)
            await viewModel.loadSoul()
            soulProfile = viewModel.soulProfile
            showsPermissionOnboarding = !PermissionOnboardingView(
                theme: appDelegate.currentTheme
            ).allRequiredPermissionsGranted
        }
        .onDisappear {
            connectionTask?.cancel()
            agentExecutablePanel?.cancel(nil)
            agentExecutablePanel = nil
            soulSaveTask?.cancel()
            if let codexLoginApproval {
                viewModel.cancelCodexLoginApproval(codexLoginApproval)
                self.codexLoginApproval = nil
            }
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
        .confirmationDialog(
            codexConfirmationTitle,
            isPresented: $confirmsCodexLogin,
            titleVisibility: .visible
        ) {
            Button(codexConfirmationButton, role: codexLoginApproval?.operation == .logout ? .destructive : nil) {
                guard let codexLoginApproval else { return }
                self.codexLoginApproval = nil
                Task { await viewModel.confirmCodexLogin(codexLoginApproval) }
            }
            Button(AppText.localized("취소"), role: .cancel) {
                guard let codexLoginApproval else { return }
                viewModel.cancelCodexLoginApproval(codexLoginApproval)
                self.codexLoginApproval = nil
            }
        } message: {
            Text(codexConfirmationMessage)
        }
        .sheet(isPresented: $showsPermissionOnboarding) {
            PermissionOnboardingView(theme: appDelegate.currentTheme)
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

    private func mascotSectionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            MascotMark()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Label(title, systemImage: symbol)
        }
        .font(.headline)
    }

    private var soulSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                AppText.localized("비밀, 자격증명 또는 민감한 개인정보를 입력하지 마세요."),
                systemImage: "exclamationmark.shield"
            )
            .foregroundStyle(.orange)
            .accessibilityIdentifier("soul-sensitive-data-warning")

            VStack(alignment: .leading, spacing: 5) {
                Text(AppText.localized(english: "Response Style", korean: "응답 스타일"))
                    .font(.callout.weight(.semibold))
                Picker(
                    AppText.localized(english: "Response Style", korean: "응답 스타일"),
                    selection: Binding(
                        get: { soulProfile.responseStyle },
                        set: { style in
                            soulProfile = replacingSoulResponseStyle(with: style)
                            viewModel.updateSoulDraft(soulProfile)
                            scheduleSoulSave()
                        }
                    )
                ) {
                    Text(AppText.localized(english: "Urgent", korean: "급함"))
                        .tag(SoulResponseStyle.urgent)
                    Text(AppText.localized(english: "Normal", korean: "보통"))
                        .tag(SoulResponseStyle.normal)
                    Text(AppText.localized(english: "Relaxed", korean: "느긋함"))
                        .tag(SoulResponseStyle.relaxed)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("soul-response-style")
                .accessibilityHint(AppText.localized(
                    english: "Controls response directness, context, and detail, not processing speed.",
                    korean: "처리 속도가 아니라 응답의 직접성, 맥락, 분량을 조절합니다."
                ))
            }

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
                : soulProfile.additionalInstructions,
            responseStyle: soulProfile.responseStyle
        )
    }

    private func replacingSoulResponseStyle(with style: SoulResponseStyle) -> SoulProfile {
        SoulProfile(
            name: soulProfile.name,
            role: soulProfile.role,
            personality: soulProfile.personality,
            speakingStyle: soulProfile.speakingStyle,
            coreValues: soulProfile.coreValues,
            likes: soulProfile.likes,
            dislikes: soulProfile.dislikes,
            userAddress: soulProfile.userAddress,
            behaviorPrinciples: soulProfile.behaviorPrinciples,
            additionalInstructions: soulProfile.additionalInstructions,
            responseStyle: style
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
            mascotSectionLabel(AppText.localized("화면 테마"), symbol: "circle.lefthalf.filled")
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
            mascotSectionLabel(
                AppText.localized(english: "Language", korean: "언어"),
                symbol: "globe"
            )
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            MascotMark()
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("YumYum Agent")
                    .font(.title.bold())
                Text(AppText.localized("검증된 로컬 에이전트와 빠른 메뉴"))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(AppText.localized(english: "LOCAL CLI", korean: "로컬 CLI"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.orange.opacity(0.12), in: Capsule())
                .accessibilityLabel(AppText.localized(english: "Local CLI", korean: "로컬 CLI"))
        }
    }

    private var agentSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.isDiscoveringAgents {
                    ProgressView(AppText.localized("안전한 설치 경로 확인 중…"))
                        .controlSize(.small)
                }

                agentSetupCard

                ForEach(viewModel.agentSnapshot.installations) { installation in
                    agentRow(installation)
                    Divider()
                }

                Text(AppText.localized(
                    english: "Agents run on this Mac and may send selected content under their own network and authentication policies.",
                    korean: "에이전트는 이 Mac에서 실행되며, 선택한 콘텐츠는 각 에이전트의 네트워크 및 인증 정책에 따라 전송될 수 있습니다."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        } label: {
            mascotSectionLabel(AppText.localized("로컬 에이전트"), symbol: "cpu")
        }
    }

    private var agentSetupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                AppText.localized(
                    english: "Register your locally installed agent",
                    korean: "로컬에 설치된 에이전트를 등록해 주세요"
                ),
                systemImage: "pawprint.fill"
            )
            .font(.callout.weight(.semibold))

            Text(AppText.localized(
                english: "Choose an agent and find it in safe default locations to register it.",
                korean: "연결할 에이전트를 선택해 안전한 기본 설치 위치에서 찾아 등록하세요."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                agentRegistrationControls
                if !viewModel.agentSnapshot.hiddenDefinitionIDs.isEmpty {
                    hiddenAgentsMenu
                }
                installationGuideMenu
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("agent-setup-card")
    }

    private func agentRow(_ installation: AgentInstallation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: installation.availability == .available
                ? "checkmark.circle.fill"
                : "xmark.circle")
                .foregroundStyle(installation.availability == .available ? .green : .secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
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
                if installation.definitionID == .codex,
                   installation.availability == .available {
                    Text(viewModel.codexLoginState.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(codexLoginStatusColor)
                        .accessibilityIdentifier("codex-login-status")
                    Text(AppText.localized(
                        english: "Codex usage counts against your ChatGPT plan limits. Available models and limits may vary by plan. YumYum never receives your password or token.",
                        korean: "Codex 사용량은 ChatGPT 플랜 한도에 포함됩니다. 사용 가능한 모델과 한도는 플랜에 따라 다를 수 있습니다. YumYum은 비밀번호나 토큰을 받지 않습니다."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if installation.definitionID == .claudeCode,
                   installation.availability == .available {
                    Text(AppText.localized(
                        english: "Claude Code manages its own sign-in. Open Terminal and follow the CLI's login prompts. YumYum never receives your password or token.",
                        korean: "Claude Code는 자체적으로 로그인을 관리합니다. 터미널을 열어 CLI 안내에 따라 로그인하세요. YumYum은 비밀번호나 토큰을 받지 않습니다."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(alignment: .top, spacing: 6) {
                agentPrimaryAction(for: installation)
                agentRowMenu(for: installation)
            }
        }
    }

    @ViewBuilder
    private func agentPrimaryAction(for installation: AgentInstallation) -> some View {
        if installation.availability != .available {
            Button(
                AppText.localized(english: "Find and register", korean: "찾아 등록"),
                systemImage: "magnifyingglass"
            ) {
                findAndRegisterAgent(installation.definitionID)
            }
            .disabled(viewModel.isDiscoveringAgents || agentExecutablePanel != nil)
        } else if installation.definitionID == .codex,
                  [.awaitingBrowserSignIn, .loggingOut, .changingAccount].contains(viewModel.codexLoginState) {
            Button(AppText.localized("취소")) {
                viewModel.cancelCodexLogin()
            }
            .accessibilityIdentifier("cancel-codex-login-button")
        } else if installation.definitionID == .codex,
                  viewModel.codexLoginState != .signedIn {
            Button(AppText.localized(
                english: "Sign in with ChatGPT",
                korean: "ChatGPT로 로그인"
            )) {
                requestCodexApproval(for: installation, operation: .login)
            }
            .disabled(viewModel.codexLoginState == .checking)
            .accessibilityIdentifier("sign-in-codex-button")
        } else {
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
            .disabled(viewModel.agentSnapshot.selectedInstallation?.id == installation.id)
        }
    }

    @ViewBuilder
    private func agentRowMenu(for installation: AgentInstallation) -> some View {
        Menu {
            if let url = installationGuideURL(for: installation.definitionID) {
                Link(destination: url) {
                    Label(
                        AppText.localized(english: "Install guide", korean: "설치 안내"),
                        systemImage: "arrow.up.right.square"
                    )
                }
            }

            if installation.definitionID == .codex,
               installation.availability == .available {
                if viewModel.codexLoginState == .signedIn {
                    Button(AppText.localized(english: "Change account", korean: "계정 변경")) {
                        requestCodexApproval(for: installation, operation: .changeAccount)
                    }
                    Button(AppText.localized(english: "Logout", korean: "로그아웃"), role: .destructive) {
                        requestCodexApproval(for: installation, operation: .logout)
                    }
                }
                Button(AppText.localized(
                    english: "Check connection again",
                    korean: "연결 다시 확인"
                )) {
                    Task { await viewModel.refreshCodexLoginStatus(for: installation) }
                }
                .disabled([.checking, .awaitingBrowserSignIn, .loggingOut, .changingAccount].contains(viewModel.codexLoginState))
                .accessibilityIdentifier("check-codex-connection-button")
            }

            if installation.definitionID == .claudeCode,
               installation.availability == .available {
                Button(
                    AppText.localized(english: "Open Terminal", korean: "터미널 열기"),
                    systemImage: "terminal"
                ) {
                    openTerminalForClaudeCodeLogin()
                }
                .accessibilityIdentifier("open-terminal-claude-login-button")
            }

            if installation.availability != .available {
                Button(AppText.localized(
                    english: "Choose executable directly",
                    korean: "실행 파일 직접 선택"
                )) {
                    chooseAgentExecutable(for: installation.definitionID)
                }
                .disabled(viewModel.isDiscoveringAgents || agentExecutablePanel != nil)
            }

            Divider()

            Button(
                AppText.localized(english: "Remove from list", korean: "목록에서 제거"),
                role: .destructive
            ) {
                removeAgentInstallation(installation)
            }
            .disabled(viewModel.isDiscoveringAgents || agentExecutablePanel != nil)
            .accessibilityHint(AppText.localized(
                english: "Removes this agent from the list without deleting its executable. Restore it from Hidden agents or by finding and registering it again.",
                korean: "실행 파일을 삭제하지 않고 이 에이전트를 목록에서 제거합니다. 숨긴 에이전트 메뉴에서 복원하거나 다시 찾아 등록할 수 있습니다."
            ))
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(AppText.localized(english: "More actions", korean: "더 보기"))
        .accessibilityIdentifier("agent-row-more-menu")
    }

    private var hiddenAgentsMenu: some View {
        Menu {
            ForEach(viewModel.agentSnapshot.hiddenDefinitionIDs, id: \.self) { definitionID in
                Button(definitionID.displayName) {
                    findAndRegisterAgent(definitionID)
                }
            }
        } label: {
            Label(
                AppText.localized(english: "Hidden agents", korean: "숨긴 에이전트"),
                systemImage: "eye.slash"
            )
        }
        .disabled(viewModel.isDiscoveringAgents || agentExecutablePanel != nil)
        .accessibilityIdentifier("hidden-agents-menu")
    }

    private var agentRegistrationControls: some View {
        HStack(spacing: 8) {
            Picker(
                AppText.localized(english: "Agent to connect", korean: "연결할 에이전트"),
                selection: $agentToRegister
            ) {
                ForEach(AgentDefinitionID.allCases, id: \.self) { definitionID in
                    Text(definitionID.displayName).tag(definitionID)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 150)
            .accessibilityLabel(AppText.localized(
                english: "Agent to connect",
                korean: "연결할 에이전트"
            ))

            Button {
                findAndRegisterAgent(agentToRegister)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                    Text(AppText.localized(english: "Find and register", korean: "찾고 등록하기"))
                }
                .fixedSize()
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isDiscoveringAgents || agentExecutablePanel != nil)
        }
    }

    private func findAndRegisterAgent(_ definitionID: AgentDefinitionID) {
        Task { await viewModel.findAndRegisterAgent(definitionID) }
    }

    private var installationGuideMenu: some View {
        Menu {
            ForEach(AgentDefinitionID.allCases, id: \.self) { definitionID in
                if let url = installationGuideURL(for: definitionID) {
                    Link(destination: url) {
                        Label(definitionID.displayName, systemImage: "arrow.up.right.square")
                    }
                }
            }
        } label: {
            Label(
                AppText.localized(english: "Install guide", korean: "설치 안내"),
                systemImage: "arrow.up.right.square"
            )
        }
    }

    private func installationGuideURL(for definitionID: AgentDefinitionID) -> URL? {
        switch definitionID {
        case .hermes:
            URL(string: "https://hermes-agent.nousresearch.com/docs/getting-started/quickstart/")
        case .openCode:
            URL(string: "https://opencode.ai/docs")
        case .codex:
            URL(string: "https://learn.chatgpt.com/docs/codex/cli")
        case .claudeCode:
            URL(string: "https://code.claude.com/docs/en/setup")
        }
    }

    private func refreshAgents() {
        Task { await viewModel.refreshAgents(trigger: .manualRescan) }
    }

    private func openTerminalForClaudeCodeLogin() {
        guard let terminalURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) else { return }
        NSWorkspace.shared.openApplication(
            at: terminalURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func chooseAgentExecutable(for definitionID: AgentDefinitionID) {
        guard agentExecutablePanel == nil else { return }
        let panel = NSOpenPanel()
        panel.title = AppText.localized(
            english: "Choose \(definitionID.displayName) Executable",
            korean: "\(definitionID.displayName) 실행 파일 선택"
        )
        panel.message = AppText.localized(
            english: "Choose the installed executable. YumYum will verify its local command contract before using it.",
            korean: "설치된 실행 파일을 선택하세요. YumYum이 사용 전에 로컬 실행 계약을 확인합니다."
        )
        panel.prompt = AppText.localized(english: "Choose", korean: "선택")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = false
        agentExecutablePanel = panel
        panel.begin { response in
            Task { @MainActor in
                guard self.agentExecutablePanel === panel else { return }
                self.agentExecutablePanel = nil
                guard response == .OK, let url = panel.url else { return }
                await viewModel.addExplicitAgentPath(url.path, for: definitionID)
            }
        }
    }

    private func removeAgentInstallation(_ installation: AgentInstallation) {
        Task { await viewModel.removeAgentInstallation(installation) }
    }

    private var shortcutSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(AppText.localized("클립보드 먹이기 전역 단축키"))
                    Spacer()
                    ShortcutRecorderField(
                        shortcut: appDelegate.clipboardFeedShortcut,
                        onBeginRecording: { appDelegate.setShortcutRecording(true) },
                        onEndRecording: { appDelegate.setShortcutRecording(false) },
                        onRecord: { appDelegate.setClipboardFeedShortcut($0) }
                    )
                    .frame(width: 132, height: 24)
                    Button(AppText.localized("기본값")) {
                        appDelegate.setClipboardFeedShortcut(.default)
                    }
                }
                Text(AppText.localized("⌃ ⌥ ⌘ 중 하나 이상을 포함한 조합만 등록할 수 있습니다. Esc로 취소합니다."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(AppText.localized("빠른 메뉴 지금 열기")) {
                    appDelegate.showQuickMenu()
                }
                Button(AppText.localized("권한 확인")) {
                    showsPermissionOnboarding = true
                }
            }
            .padding(.top, 4)
        } label: {
            mascotSectionLabel(AppText.localized("단축키"), symbol: "keyboard")
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

    private var codexLoginStatusColor: Color {
        switch viewModel.codexLoginState {
        case .signedIn: .green
        case .failed, .timedOut, .changeFailedNeedsLogin: .red
        default: .secondary
        }
    }

    private func requestCodexApproval(
        for installation: AgentInstallation,
        operation: CodexLoginApprovalRequest.Operation
    ) {
        codexLoginApproval = viewModel.requestCodexLoginApproval(
            for: installation,
            operation: operation
        )
        confirmsCodexLogin = codexLoginApproval != nil
    }

    private var codexConfirmationTitle: String {
        switch codexLoginApproval?.operation {
        case .logout: AppText.localized(english: "Log out of ChatGPT?", korean: "ChatGPT에서 로그아웃할까요?")
        case .changeAccount: AppText.localized(english: "Change ChatGPT account?", korean: "ChatGPT 계정을 변경할까요?")
        default: AppText.localized(english: "Sign in to Codex with ChatGPT?", korean: "ChatGPT로 Codex에 로그인할까요?")
        }
    }

    private var codexConfirmationButton: String {
        switch codexLoginApproval?.operation {
        case .logout: AppText.localized(english: "Logout", korean: "로그아웃")
        case .changeAccount: AppText.localized(english: "Logout and Change Account", korean: "로그아웃 후 계정 변경")
        default: AppText.localized(english: "Open Browser and Sign In", korean: "브라우저를 열고 로그인")
        }
    }

    private var codexConfirmationMessage: String {
        switch codexLoginApproval?.operation {
        case .logout:
            AppText.localized(
                english: "The official Codex CLI will remove its stored authentication state.",
                korean: "공식 Codex CLI가 저장된 인증 상태를 제거합니다."
            )
        case .changeAccount:
            AppText.localized(
                english: "Current authentication is removed first. If browser sign-in is cancelled or fails, you will remain logged out.",
                korean: "현재 인증을 먼저 제거합니다. 브라우저 로그인을 취소하거나 실패하면 로그아웃 상태로 남습니다."
            )
        default:
            AppText.localized(
                english: "Codex will open your browser, use the network, and save its authentication under your user account. YumYum never receives your password or token.",
                korean: "Codex가 브라우저와 네트워크를 사용하고 사용자 계정 아래에 인증 상태를 저장합니다. YumYum은 비밀번호나 토큰을 받지 않습니다."
            )
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
            mascotSectionLabel(AppText.localized("Hermes 수동 경로 진단"), symbol: "terminal")
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
            mascotSectionLabel(AppText.localized("개발 진단"), symbol: "wrench.and.screwdriver")
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

private struct MascotMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 42
            func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
                CGRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
            }

            var body = Path()
            body.move(to: CGPoint(x: 7 * scale, y: 11 * scale))
            body.addLine(to: CGPoint(x: 14 * scale, y: 5 * scale))
            body.addLine(to: CGPoint(x: 18 * scale, y: 11 * scale))
            body.addLine(to: CGPoint(x: 30 * scale, y: 7 * scale))
            body.addLine(to: CGPoint(x: 35 * scale, y: 13 * scale))
            body.addLine(to: CGPoint(x: 34 * scale, y: 35 * scale))
            body.addLine(to: CGPoint(x: 8 * scale, y: 34 * scale))
            body.closeSubpath()
            context.fill(body, with: .color(.orange))
            context.stroke(body, with: .color(.brown), style: StrokeStyle(lineWidth: 2 * scale, lineJoin: .round))
            context.fill(Path(ellipseIn: rect(13, 15, 3, 4)), with: .color(.brown))
            context.fill(Path(ellipseIn: rect(27, 17, 3.5, 4.5)), with: .color(.brown))
            context.fill(Path(ellipseIn: rect(13, 21, 17, 12)), with: .color(.brown))
            context.fill(Path(ellipseIn: rect(17, 28, 10, 4)), with: .color(.pink))

            var tooth = Path()
            tooth.move(to: CGPoint(x: 19 * scale, y: 22 * scale))
            tooth.addLine(to: CGPoint(x: 23 * scale, y: 22 * scale))
            tooth.addLine(to: CGPoint(x: 21 * scale, y: 26 * scale))
            tooth.closeSubpath()
            context.fill(tooth, with: .color(.white))
        }
    }
}
