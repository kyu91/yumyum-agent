# Windows 확장 계획 (초안)

작성일: 2026-08-18 (오퍼스 플래너 검토, 코드베이스 실측 기반)

핵심 결론: **공유할 수 있는 것은 코드가 아니라 계약이다.** Swift↔Rust FFI 통합은 지금 하면 동작 중인 macOS 앱만 흔들고 얻는 게 없다. 대신 계약을 기계 검증 가능한 픽스처(`spec/`)로 뽑아 CI가 드리프트를 잡게 한다.

## 0. 자산 실측

| 영역 | 라인 | 이식 성격 |
|---|---|---|
| AppKit UI 3종 (ActionFlowPanel/QuickMenuPanel/YumYumApplication) | 5,873 | 전면 재작성 |
| 캡처 (ScreenCaptureCoordinator 499 + CaptureRegionPolicy 195) | 694 | 좌표 정책 이식 가능, API 교체 |
| ACP (HermesACPTransport 944 + CommandBuilder 36) | 980 | 가장 이식성 높음 (순수 JSON-RPC/stdio) |
| 구조화 CLI (StructuredCLIStreaming 854 + AgentRuntime 657) | 1,511 | argv 계약 공유, 실행 계층 재작성 |
| 프로세스 (ProcessRunner 518 + ProcessRunning 83) | 601 | Windows 시맨틱 차이 최대 |
| 순수 정책/상태 (FeedWorkflow, ActionFlowPolicy, ChatBubbleState, AgentSelection, AgentDiscovery, SoulProfile, Redactor, ExternalChangeToolsetPolicy 등) | ~2,900 | 알고리즘 1:1 이식 |
| 테스트 | 337 케이스 | 의도만 공유 |

## 1. 저장소 구조 — 모노레포 + `spec/` 신설

```
/  (Package.swift 루트 유지 — 이동 금지. scripts/·ci.yml·docs 전부 루트 전제)
├─ Sources/ Tests/ AppBundle/ scripts/     기존 그대로
├─ spec/          ★ 신설: 플랫폼 무관 정규 계약 (단일 진실 원천)
│   feed-validation.json / agent-argv.json / acp-sequence.md
│   capture-region.json / error-categories.json / localization.json
│   soul-format.md / process-fixture-modes.md
├─ windows/       ★ 신설: Tauri 2
│   src/ (TS 프론트), src-tauri/{capabilities,src/{process,agent,acp,feed,capture,redact}}
│   fixtures/ (Rust 프로세스 픽스처), AGENTS.md (디렉토리 스코프)
└─ AGENTS.md      공통 원칙 + windows/ 위임
```

별도 저장소가 아닌 이유: ① 계약 드리프트가 진짜 리스크 — FeedValidator 차단 목록 하나가 한쪽에만 추가되면 보안 등가성이 깨진다. 같은 저장소여야 `spec/` 변경이 양쪽 CI를 동시에 빨갛게 만듦. ② 이슈 트래커·SECURITY·PRIVACY·제품 스펙이 이미 하나. ③ 릴리스는 태그 접두사로 분리 가능. 나눠야 할 유일한 조건은 리뷰 권한 분리가 필요할 때 — 1인 메인테이너 상황에선 해당 없음.

CI 함정: 현재 `ci.yml`은 `on: push` 무조건 실행. Windows 잡을 `paths:` 필터로 나누면 required check가 skipped로 남아 PR이 영구 머지 불가가 된다. → 잡은 항상 트리거하고 스텝 내부에서 조기 성공 종료. 3-job: `macos-build-test`(기존 유지, 번들 파일 개수 검증 포함) / `windows-build-test` / `spec-contract`(ubuntu, 저렴).

## 2. 지금 즉시 (Windows 코드 0줄)

**Phase 0-A — `spec/` 추출 (1~2일).** 현재 상수는 소스에 하드코딩: FeedValidator의 확장자 허용목록/차단 파일명·확장자/20MB, StructuredCLIStreaming의 argv 3종, UserFacingErrorCategory 14종.

중요: Swift 런타임이 JSON을 읽게 만들지 말 것. 런타임 파싱은 새 시작 실패 경로를 만들고 "미확인 추상화 금지" 원칙에 어긋난다. → `spec/*.json`은 테스트 전용 정본. Swift 상수는 하드코딩 유지, 신규 `SpecContractTests.swift`가 spec을 읽어 일치 검증. 어느 쪽이든 spec 없이 상수를 바꾸면 CI가 깨진다.

**Phase 0-B — 픽스처 모드 계약 문서화 (반나절).** YumYumProcessFixture의 `--version`/`emit`/`flood`/`arguments`/`stdin-chunks`/`stdin-backpressure`/`acp` 모드를 명세화.

**Phase 0-C — 사실 확인 스파이크 (3~5일, 계획 확정 전 필수).**

- **S1: Windows에서 `codex exec --sandbox read-only`가 실제로 강제되는가?** (Codex 샌드박스는 macOS Seatbelt/Linux Landlock 기반) → 실패 시 포팅 난이도가 아니라 제품 안전 원칙 문제. 가장 중요.
- **S2: npm/bun 설치 CLI가 Windows에서 `.cmd`/`.ps1` shim인가 `.exe`인가?** → `.cmd`면 "shell 미경유" 원칙과 정면 충돌
- **S3: 투명+항상위+클릭통과 NSPanel 등가물을 WebView2에서 픽셀 알파로 구현 가능한가?**
- **S4: xcap 캡처에 자기 오버레이가 찍히는가, `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`로 배제되는가?**

## 3. 기능 동등성 순서 — 리스크 역순 (백엔드 먼저, UI 마지막)

**Phase 1 — 프로세스+탐색 (게이트).** UI 없는 Rust `yumyum-probe.exe`. 탐색 디렉토리 전면 교체(`%APPDATA%\npm`, `%LOCALAPPDATA%\Programs`, `~\.bun\bin`, `~\scoop\shims`, `%LOCALAPPDATA%\Microsoft\WinGet\Links`). 확장자 후보는 명시 목록으로만(PATHEXT 전체 추종 금지). `SystemRoot` 환경변수 누락 주의. 2초 타임아웃·64KB 제한 유지.

**Phase 2 — ACP (가장 안전한 첫 실제 연동).** 944라인이 stdio 위 JSON-RPC라 플랫폼 의존 거의 없음. `session/request_permission` → 항상 `cancelled` 고정(절대 완화 금지). Windows 고유 방어: `\r\n` — ACP 프레이밍에 `\r` trim 필수. Hermes+Gemini 둘 다 ACP라 Phase 2 하나로 에이전트 2개가 켜진다.

**Phase 3 — 구조화 CLI.** argv는 `spec/agent-argv.json` 대조. 경로는 Rust `Command`에 이스케이핑 위임(문자열 결합 금지). stdout/stderr 동시 배수 필수 — Rust `wait_with_output()`는 제한이 없어 요구 미충족, 리더 태스크 2개 필요.

**Phase 4 — 순수 로직 (병렬 가능).** 절대경로 판정에 드라이브 문자 + UNC(`\\server\share`) 차단 권장(네트워크 접근 유발). alias 검사에 심볼릭/junction/reparse point + `.lnk` 차단 추가. ADS(`file.txt:hidden`) 방지 — 드라이브 위치 외 `:` 거부.

**Phase 5 — 캡처 (병렬 가능).**

| 이슈 | 영향 |
|---|---|
| 자기 프로세스 창 캡처 | 직접 영향 — 해결 필수 |
| Windows 프레임 미출력 | 영향, 재시도+타임아웃으로 완화 |
| HDR/색상 차이 | 거의 무관 |
| macOS 다중모니터/hang/메모리, SCK 전환 논의 | 무관 |
| Linux Wayland | 무관 |

대응: 오버레이/펫에 `WDA_EXCLUDEFROMCAPTURE`(Win10 2004+) + 숨김 후 DWM 프레임 1개 대기. `tauri-plugin-screenshots` 사용 금지(내부 xcap 0.3 고정), `xcap` 직접 의존.

**Phase 6 — 전역 단축키.** 권한 3종(Screen Recording/Accessibility/Input Monitoring)이 Windows엔 없다 → PermissionOnboardingView 전체 삭제(순 감소). 새 실패 모드: 다른 앱이 조합을 점유하면 `RegisterHotKey`가 조용히 실패 — "다른 앱이 사용 중" 피드백 UX 신규 필요.

**Phase 7 — UI.** 노력 최대, 리스크 최저. S3 결과로 렌더링 방식 확정.

## 4. 아키텍처 원칙 강제 (기계적 장치)

**4-1. shell 미경유 — 가장 위험한 지점.** npm 전역 설치 CLI는 Windows에서 `.cmd` 배치 shim이고, 정의상 `cmd.exe`가 해석해야 한다. 원칙을 문자 그대로 지키면 npm 설치 에이전트를 지원할 수 없다.
- A. shim 해석: `.cmd` 파싱해 node 스크립트 추출 → `node.exe <script>` 직접 실행. 원칙 완전 유지
- B. `.exe`만 지원: 원칙 유지, 범위 축소
- C. `cmd.exe /C` 예외 명문화: 비권장 — BatBadBut(CVE-2024-24576) 계열 인자 주입 위험 실재
→ B로 v1, A는 후속. C 미채택.

**4-2. 강제 장치.** spawn은 `src-tauri/src/process/` 단일 모듈만 허용, `clippy.toml` `disallowed-methods`로 `Command::new` 전역 금지 후 해당 모듈만 allow. CI에서 `Cargo.toml`에 `tauri-plugin-shell`이 있으면 실패하는 grep. `VerifiedExecutable` 타입 생성자가 절대경로+존재+실행가능 검증을 통과해야만 인스턴스화. `cargo deny` 게이트.

**4-3. 리댁션 — Tauri에서 새로 생기는 누출면.** Tauri는 webview가 별도 컨텍스트 + devtools로 열람 가능. 원칙: 절대경로는 IPC 경계를 넘지 않는다. Rust가 `AttachmentId`(불투명 UUID) 발급, 프론트는 ID+파일명+바이트수만 수신. 썸네일은 Rust가 디코딩해 data URL로 전달.

**4-4. 외부 변경 기본 거부.** ExternalChangeToolsetPolicy 1:1 이식, TaskApprovalGate 1회 소비 모델 동일, ACP permission=cancelled 고정. Tauri capability 파일이 추가 방어선.

**4-5. 네트워크 차단.** CSP `default-src 'self'; connect-src 'self'; img-src 'self' data: asset:` 고정, `dangerousDisableAssetCspModification: false`.

**4-6. AGENTS.md와 정면 충돌.** 현재 "There is no external package dependency." vs Tauri+xcap+tokio+serde의 수백 개 transitive crate. 명시적 개정 필요: "Swift 패키지는 외부 의존성 없음. `windows/`는 의존성을 갖되 신규 직접 의존성은 PR에서 사유·라이선스·유지보수 상태 명시 + `cargo deny` 통과."

## 5. 통합 시점 — 미루는 것이 타당. 단 계약 추출은 미루지 말 것

미루는 게 맞는 이유: ① macOS 앱은 337 테스트로 보호되며 출시 중 — 통합은 Core 5,500라인을 Rust로 재작성한 뒤 C ABI로 붙이는 일이라 동작 중인 앱을 깨뜨릴 위험만 추가. ② Swift Concurrency와 Rust async는 FFI 경계에서 자연스럽게 만나지 않아 콜백 브리지가 새로 필요. ③ UI는 어차피 통합 불가, 공유되는 건 Core뿐인데 Core는 순수 로직이라 계약+테스트 공유만으로 90% 이득.

미루면 안 되는 것: `spec/` 추출. 안 하면 6개월 뒤 차단 목록·argv·에러 카테고리가 소리 없이 갈라지고, 그때 통합하려면 "무엇이 정본인가"를 고고학으로 복원해야 한다.

재검토 트리거(미리 확정): Windows Core가 Phase 1~4 패리티 달성 + `spec/` 대칭 테스트가 실제 드리프트를 3회 이상 잡음 + 양 플랫폼 모두 활성 기여자 존재. 셋 다 만족 전엔 논의하지 않는다.

## 6. 기여자 리스크

| 리스크 | 심각도 | 완화 |
|---|---|---|
| Swift 기여자가 Windows를 깨는지 판단 불가 | 높음 | `spec/` 대칭 테스트가 CI에서 잡음 |
| 반대 플랫폼 테스트 불가 | 높음 | 라벨 `platform:macos/windows/both`. 크로스 PR은 분해 허용 |
| 1인 메인테이너 리뷰 부담 2배 | 높음 | 경로별 CODEOWNERS, Windows 초기엔 외부 기여 닫아두기 |
| AGENTS.md 비대·모호 | 중간 | 최상위는 공통 원칙만, `windows/AGENTS.md` 분리 |
| CONTRIBUTING 검증 명령이 macOS 전용 | 중간 | 플랫폼별 섹션 분리 |
| 빌드 재현성 하락 | 중간 | 락파일 커밋, `cargo deny`, 의존성 갱신 자동화 |
| 프로젝트 정체성 희석 | 중간 | README에 "macOS 정본, Windows 동등 구현" 관계 명시 |

## 7. 실행 순서

0-A(spec 추출, 지금 시작 가능) → 0-B(픽스처 계약) → 0-C(S1~S4 스파이크) → **게이트: S1/S2 결론으로 v1 에이전트 범위 확정(사용자 결정)** → 1(프로세스/탐색) → 2(ACP: Hermes+Gemini) → 3(구조화 CLI) → 4(순수 로직, 1~3과 병렬) / 5(캡처, 병렬) → 6(단축키) → 7(UI). CI 3-job은 Phase 1과 함께.

## 8. 착수 전 사용자 결정 필요 (우선순위순)

1. **Codex 샌드박스(S1 의존, 최우선)** — Windows에서 read-only가 강제 안 되면 (a)v1 제외 / (b)경고 후 포함 / (c)성숙 대기? → (a) 권장
2. **`.cmd` shim 정책(S2 의존)** — A(shim 해석)/B(`.exe`만)/C(cmd.exe 예외)? → B로 v1, A 후속, C 비권장
3. **저장소 분리** — 모노레포(권장) vs 별도
4. **AGENTS.md 의존성 원칙 개정 동의?** — 동의 없으면 Tauri 경로 자체가 성립 불가
5. **Windows v1 에이전트 범위** — ACP 2종(Hermes+Gemini)만 vs 5종 전부 → 2종 권장
6. **UI 충실도** — 펫/버블 픽셀 복제 vs Windows 관용 UI 적응. S3에 따라 강제될 수도
7. **버전 정책** — 공통 버전 vs 독립(`macos-v*`/`windows-v*`)
8. **`windows/` 외부 기여 개방 시점** → Phase 4까지 닫기 권장
9. **로컬라이제이션 공유** — AppLocalization을 `spec/localization.json`으로? → 공유 권장

## 9. 명시적 비권장

`tauri-plugin-screenshots` 사용 금지 / `tauri-plugin-shell` 의존성 추가 금지(CI 강제) / Rust+Swift FFI 통합 지금 시도 금지 / `Package.swift` 이동 금지 / Swift 런타임이 spec JSON 읽게 만들지 말 것 / Electron 재고 불필요 — 항상위 투명 펫 + 로컬 프로세스 스폰이 핵심이라 메모리·설치용량 페널티가 상시 체감됨.

## 참고할 핵심 파일

- `AGENTS.md` — 의존성 원칙 개정, `windows/AGENTS.md` 위임, Windows 주의사항 섹션
- `Sources/YumYumCore/FeedWorkflow.swift` — FeedValidator 상수 → `spec/feed-validation.json` 추출 기준점
- `Sources/YumYumCore/StructuredCLIStreaming.swift` — argv 계약 → `spec/agent-argv.json` 추출 기준점
- `Sources/YumYumCore/AgentDiscovery.swift` — 탐색 디렉토리/`AgentProcessEnvironment.make` Windows 대응 기준점
- `.github/workflows/ci.yml` — 3-job 분리, cargo deny/shell-plugin 금지 게이트, skipped-required-check 회피
