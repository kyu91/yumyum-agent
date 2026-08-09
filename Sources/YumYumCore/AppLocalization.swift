import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english
    case korean

    public var id: String { rawValue }

    public static func resolved(preferredLanguages: [String]) -> AppLanguage {
        guard let preferred = preferredLanguages.first else { return .english }
        return Locale(identifier: preferred).language.languageCode == .korean
            ? .korean
            : .english
    }

    public var displayName: String {
        switch self {
        case .english: "English"
        case .korean: "한국어"
        }
    }
}

public final class AppLanguageStore: @unchecked Sendable {
    public static let defaultsKey = "appLanguage"

    private let defaults: UserDefaults
    private let preferredLanguages: () -> [String]

    public init(
        defaults: UserDefaults = .standard,
        preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }
    ) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
    }

    public func load() -> AppLanguage {
        defaults.string(forKey: Self.defaultsKey)
            .flatMap(AppLanguage.init(rawValue:))
            ?? AppLanguage.resolved(preferredLanguages: preferredLanguages())
    }

    public func save(_ language: AppLanguage) {
        defaults.set(language.rawValue, forKey: Self.defaultsKey)
    }
}

public enum AppText {
    private static let state = LanguageState()

    public static var language: AppLanguage { state.language }

    public static func setLanguage(_ language: AppLanguage) {
        state.language = language
    }

    public static func localized(english: String, korean: String) -> String {
        localized(english: english, korean: korean, language: language)
    }

    public static func localized(
        english: String,
        korean: String,
        language: AppLanguage
    ) -> String {
        language == .korean ? korean : english
    }

    public static func localized(_ korean: String) -> String {
        localized(korean, language: language)
    }

    public static func localized(_ korean: String, language: AppLanguage) -> String {
        guard language == .english else { return korean }
        return english[korean] ?? korean
    }

    public static func files(_ count: Int) -> String {
        files(count, language: language)
    }

    public static func files(_ count: Int, language: AppLanguage) -> String {
        localized(
            english: "\(count) \(count == 1 ? "file" : "files")",
            korean: "파일 \(count)개",
            language: language
        )
    }

    public static var knownKoreanStrings: [String] { Array(english.keys) }

    private static let english: [String: String] = [
        "Fixture Probe 실행": "Run Fixture Probe",
        "Fixture probe 성공": "Fixture probe succeeded",
        "Fixture probe 오류": "Fixture probe error",
        "Fixture 확인 중…": "Checking fixture…",
        "Hermes --version 확인 중…": "Checking Hermes --version…",
        "Hermes --version이 버전 문자열을 반환하지 않았습니다.": "Hermes --version returned no version string.",
        "Hermes ACP 연결이 응답 전에 종료되었습니다.": "The Hermes ACP connection closed before responding.",
        "Hermes ACP 출력이 안전 제한을 초과했습니다.": "Hermes ACP output exceeded the safety limit.",
        "Hermes ACP가 세션 ID를 반환하지 않았습니다.": "Hermes ACP returned no session ID.",
        "Hermes ACP가 유효한 JSON-RPC 메시지를 반환하지 않았습니다.": "Hermes ACP returned an invalid JSON-RPC message.",
        "Hermes 경로 오류": "Hermes path error",
        "Hermes 경로를 확인할 수 없습니다.": "Could not validate the Hermes path.",
        "Hermes 수동 경로 진단": "Manual Hermes path diagnostics",
        "Hermes 실행 오류": "Hermes execution error",
        "Hermes 실행 파일 절대 경로": "Absolute path to Hermes executable",
        "Hermes 연결 확인 성공": "Hermes connection succeeded",
        "Hermes 연결 확인 시간 초과": "Hermes connection timed out",
        "Hermes 연결 확인을 완료하지 못했습니다.": "Could not complete the Hermes connection check.",
        "Hermes 연결: 경로 오류": "Hermes connection: Path error",
        "Hermes 연결: 성공": "Hermes connection: Connected",
        "Hermes 연결: 시간 초과": "Hermes connection: Timed out",
        "Hermes 연결: 실행 오류": "Hermes connection: Execution error",
        "Hermes 연결: 확인 전": "Hermes connection: Not checked",
        "Hermes 연결: 확인 중": "Hermes connection: Checking",
        "Hermes가 제한 시간 안에 응답하지 않았습니다.": "Hermes did not respond in time.",
        "Probe 대기 중": "Probe ready",
        "Return을 눌러 전송합니다": "Press Return to send",
        "Soul 설정을 초기화할까요?": "Reset Soul settings?",
        "YumYum Agent 답변 요약. 채팅에서 전체 답변을 열 수 있습니다.": "YumYum Agent response summary. Open the full response in chat.",
        "YumYum Agent 답변": "YumYum Agent Response",
        "YumYum Agent 대화": "YumYum Agent Chat",
        "YumYum Agent 먹이 미리보기": "YumYum Agent Feed Preview",
        "YumYum Agent 상태": "YumYum Agent Status",
        "YumYum Agent 생각 중": "YumYum Agent is thinking",
        "YumYum Agent 액션": "YumYum Agent Actions",
        "YumYum Agent 열기": "Open YumYum Agent",
        "YumYum Agent 종료": "Quit YumYum Agent",
        "YumYum Agent 캡처 영역 선택": "Select YumYum Agent Capture Area",
        "YumYum Agent 플로팅 펫": "YumYum Agent floating pet",
        "YumYum Agent 화면의 밝은 테마와 어두운 테마를 전환합니다": "Switches between YumYum Agent's light and dark themes",
        "YumYum Agent는 자격증명을 읽지 않으며 외부 변경은 Task 한정 일회성 승인 전까지 차단합니다.": "YumYum Agent does not read credentials and blocks external changes until one-time, task-scoped approval.",
        "YumYum Agent가 응답을 생각하는 중": "YumYum Agent is thinking about the response",
        "가로와 세로가 각각 8pt 이상인 영역을 선택하세요.": "Select an area at least 8 pt wide and high.",
        "개발 진단": "Developer Diagnostics",
        "검증된 로컬 에이전트와 빠른 메뉴": "Verified local agents and quick menu",
        "경로 확인": "Validate Path",
        "기본 에이전트: 다시 선택 필요": "Default agent: Reselection required",
        "기본 에이전트를 먼저 선택하세요.": "Select a default agent first.",
        "기본값으로 초기화": "Reset to Defaults",
        "기본으로 선택": "Set as Default",
        "경로는 저장하지 않습니다. 연결 확인은 선택한 실행 파일에 `--version` 인자만 직접 전달합니다.": "The path is not saved. The connection check passes only `--version` directly to the selected executable.",
        "누르면 전체 채팅을 엽니다.": "Press to open the full chat.",
        "다시 검색": "Rescan",
        "닫기": "Close",
        "대화 내용": "Conversation",
        "대화": "Chat",
        "대화 내용을 입력하거나 파일을 선택하세요.": "Type a message or choose a file.",
        "대화 말풍선 닫기": "Close chat bubble",
        "대화 메시지": "Chat message",
        "대화를 입력하거나 자료를 첨부하세요.": "Type a message or attach something.",
        "대화에 첨부할 파일 선택": "Choose files to attach",
        "드래그하여 영역 선택 · Esc 취소": "Drag to select an area · Esc to cancel",
        "드래그하여 캡처할 영역을 선택하세요.": "Drag to select an area to capture.",
        "드래그하여 캡처할 영역 선택, Escape로 취소": "Drag to select a capture area; press Escape to cancel",
        "드래그한 화면 영역을 전송하지 않고 초안에 첨부합니다": "Attaches the selected screen area to the draft without sending it",
        "로컬 에이전트": "Local Agents",
        "로컬 CLI 도움말 계약을 확인하지 못했습니다.": "Could not verify the local CLI help contract.",
        "마지막 메시지 재시도": "Retry last message",
        "마지막 입력 재시도": "Retry last input",
        "말투": "Speaking Style",
        "먹이기": "Feed",
        "먹일 파일 선택": "Choose Files to Feed",
        "메시지 보내기": "Send Message",
        "메시지 입력": "Message",
        "버전 확인 완료": "Version checked",
        "버전 정보를 확인하지 못했습니다.": "Could not read version information.",
        "버전 확인 시간이 초과되었습니다.": "The version check timed out.",
        "버전 확인 프로세스를 시작하지 못했습니다.": "Could not start the version check process.",
        "보내기": "Send",
        "비밀, 자격증명 또는 민감한 개인정보를 입력하지 마세요.": "Do not enter secrets, credentials, or sensitive personal information.",
        "빠른 메뉴 열기": "Open Quick Menu",
        "빠른 메뉴 전역 단축키": "Global Quick Menu Shortcut",
        "클립보드 먹이기 전역 단축키": "Global Clipboard Feed Shortcut",
        "클립보드를 채팅 초안에 담고 입력창을 엽니다": "Stages the clipboard into the chat draft and opens the composer",
        "단축키": "Shortcuts",
        "빠른 메뉴 지금 열기": "Open Quick Menu Now",
        "빠른 메뉴": "Quick Menu",
        "사용자": "You",
        "사용자를 부르는 호칭": "How to Address the User",
        "상대 경로는 허용하지 않습니다. `/`로 시작하는 경로를 입력하세요.": "Relative paths are not allowed. Enter a path beginning with `/`.",
        "선택됨": "Selected",
        "선택한 에이전트를 명시적으로 다시 선택해야 합니다.": "The selected agent must be explicitly reselected.",
        "선택한 에이전트를 사용할 수 없어 명시적으로 다시 선택해야 합니다.": "The selected agent is unavailable and must be explicitly reselected.",
        "선택한 절대 경로가 실행 가능한 파일이 아닙니다.": "The selected absolute path is not an executable file.",
        "선택한 실행 파일에 --version 인자만 전달합니다": "Passes only the --version argument to the selected executable",
        "선택한 영역을 캡처하지 못했습니다.": "Could not capture the selected area.",
        "선택한 파일을 전송하지 않고 초안에 첨부합니다": "Attaches the selected files to the draft without sending them",
        "선택한 화면을 PNG로 저장하지 못했습니다.": "Could not save the selected screen as a PNG.",
        "설정에서 기본 에이전트를 다시 선택하세요.": "Reselect the default agent in Settings.",
        "설정에서 기본 에이전트를 선택하세요.": "Select a default agent in Settings.",
        "설치된 CLI의 공식 로컬 실행 계약이 지원 범위와 다릅니다.": "The installed CLI's official local execution contract is unsupported.",
        "성격": "Personality",
        "싫어하거나 피할 것": "Dislikes and Avoidances",
        "아직 대화가 없습니다": "No conversation yet",
        "안전한 설치 경로 확인 중…": "Checking safe installation paths…",
        "안전한 fixture probe를 완료하지 못했습니다.": "Could not complete the safe fixture probe.",
        "안전한 fixture가 버전 문자열을 반환하지 않았습니다.": "The safe fixture returned no version string.",
        "안전한 fixture가 제한 시간 안에 응답하지 않았습니다.": "The safe fixture did not respond in time.",
        "안전한 설치 경로에서 실행 파일을 찾지 못했습니다.": "No executable was found in safe installation paths.",
        "안전한 설치 경로에서 찾지 못함": "Not found in safe installation paths",
        "어시스턴트": "Assistant",
        "알 수 없는 오류": "Unknown error",
        "알 수 없음": "Unknown",
        "언어": "Language",
        "에이전트": "Agent",
        "에이전트 스트림이 완료 이벤트 없이 종료되었습니다.": "The agent stream ended without a completion event.",
        "에이전트 응답 시간이 초과되었습니다.": "The agent response timed out.",
        "에이전트가 세션 ID를 반환하지 않았습니다.": "The agent returned no session ID.",
        "에이전트가 요청한 세션과 다른 세션을 반환했습니다.": "The agent returned a different session than requested.",
        "에이전트가 유효하지 않은 JSON 스트림을 반환했습니다.": "The agent returned an invalid JSON stream.",
        "에이전트가 응답 텍스트를 반환하지 않았습니다.": "The agent returned no response text.",
        "에이전트가 지원되지 않는 JSON 이벤트를 반환했습니다.": "The agent returned an unsupported JSON event.",
        "역할 / 정체성": "Role / Identity",
        "연결 확인 전": "Not checked",
        "연결 확인": "Check Connection",
        "외부 변경": "External Changes",
        "외부 변경: 비활성화": "External changes: Disabled",
        "응답 생성 중": "Generating response",
        "응답 생성 취소": "Cancel response",
        "응답 말풍선에서 채팅 입력하기": "Type a reply in the response bubble",
        "이름": "Name",
        "이미 다른 입력을 처리하고 있습니다.": "Another input is already being processed.",
        "이전에 사용할 수 없었던 에이전트는 명시적으로 다시 선택해야 합니다.": "A previously unavailable agent must be explicitly reselected.",
        "이미 화면 캡처 영역을 선택하고 있습니다.": "A screen capture area is already being selected.",
        "인라인 메시지 전송": "Send inline message",
        "인라인 채팅 메시지": "Inline chat message",
        "재시도": "Retry",
        "자동 발견 결과와 별개로 진단할 Hermes 절대 경로를 입력할 수 있습니다.": "Enter an absolute Hermes path to diagnose independently of automatic discovery.",
        "저장 시 공백을 정리하고 필드당 2,000자, 전체 12,000자로 제한합니다.": "When saving, whitespace is normalized and content is limited to 2,000 characters per field and 12,000 overall.",
        "저장 중…": "Saving…",
        "저장된 Soul을 불러왔습니다": "Loaded saved Soul",
        "저장됨": "Saved",
        "저장된 정확한 실행 경로를 찾지 못했습니다.": "The exact saved executable path was not found.",
        "저장할 수 없습니다": "Could not save",
        "전송 예정 첨부": "Pending attachments",
        "전송": "Send",
        "전송을 취소했습니다.": "Sending cancelled.",
        "전체 답변을 채팅에서 열기": "Open full response in chat",
        "절대 경로 형식을 확인했습니다. 연결 확인을 실행할 수 있습니다.": "The absolute path format is valid. You can run the connection check.",
        "정리 및 길이 제한 후 저장됨": "Saved after normalization and length limits",
        "종료된 에이전트 스트림을 다시 처리할 수 없습니다.": "A completed agent stream cannot be processed again.",
        "좋아하는 것": "Likes",
        "주 연결과 분리된 패키지 fixture에 `--version`을 전달해 개발 환경만 점검합니다.": "Checks only the development environment by passing `--version` to the package fixture, separately from the primary connection.",
        "채팅 입력하기": "Reply",
        "채팅창 상세": "Open Chat",
        "첨부 제거": "Remove attachment",
        "첨부": "Attachments",
        "초기화": "Reset",
        "초안 첨부 파일": "Draft attachments",
        "추가 지침": "Additional Instructions",
        "취소": "Cancel",
        "캡처": "Capture",
        "캡처나 파일을 첨부하고 메시지를 보내면 대화가 여기에 쌓입니다.": "Attach a capture or file and send a message to start a conversation.",
        "캡처할 디스플레이를 찾지 못했습니다.": "No display is available for capture.",
        "왼쪽 클릭하면 클립보드를 채팅 입력창에 붙입니다. 오른쪽 클릭하면 빠른 메뉴를 엽니다. 드래그하여 이동할 수 있습니다.": "Left-click to add the clipboard to the chat draft. Right-click to open the quick menu. Drag to move.",
        "테마": "Theme",
        "파일 첨부": "Attach Files",
        "파일": "Files",
        "패키지에 포함된 테스트 fixture의 버전만 확인합니다": "Checks only the version of the test fixture included in the package",
        "포커스를 강제로 가져오지 않고 펫 옆 빠른 메뉴를 엽니다": "Opens the quick menu beside the pet without stealing focus",
        "플로팅 펫 보이기": "Show Floating Pet",
        "핵심 가치": "Core Values",
        "행동 원칙": "Behavior Principles",
        "현재 응답을 기다리는 중입니다.": "A response is already pending.",
        "화면 영역 캡처 첨부": "Attach Screen Capture",
        "화면 캡처 권한이 필요합니다.": "Screen recording permission is required.",
        "화면 캡처 영역 선택": "Select Capture Area",
        "화면 테마": "Appearance",
        "화면 우하단의 YumYum Agent 펫 표시 여부를 전환합니다": "Toggles the YumYum Agent pet in the lower-right corner of the screen",
        "화면을 캡처하지 못했습니다.": "Could not capture the screen.",
    ]
}

private final class LanguageState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = AppLanguage.korean

    var language: AppLanguage {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
