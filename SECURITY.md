# Security Policy

## Reporting a vulnerability

GitHub 저장소가 공개되고 **Private Vulnerability Reporting**이 활성화되면 저장소의 **Security → Report a vulnerability**를 사용해 주세요. 현재는 로컬 저장소만 존재하므로 비공개 신고 채널이 아직 없습니다. 민감한 내용을 공개 Issue에 게시하지 마세요.

공개 Issue에는 토큰, 자격증명, 개인 식별 정보, 로컬 절대 경로, 원시 로그·stderr, 선택한 파일 또는 화면 캡처를 포함하지 마세요. 재현에 민감한 정보가 필요하다면 비공개 신고 기능이 준비될 때까지 공개하지 마세요.

## Scope and boundaries

YumYum 자체의 입력 검증, 프로세스 실행, 임시 파일, 권한 처리, 경로 노출 및 외부 변경 경계는 이 정책의 범위입니다. Hermes, OpenCode, Codex, Claude Code의 설치·인증·네트워크·모델 제공자 동작에서 발생한 취약점은 해당 upstream 프로젝트에 신고하세요. 공급업체 이름은 호환성 설명일 뿐 후원이나 보증을 의미하지 않습니다.

현재 Connector는 외부 변경을 실행하지 않으며 Hermes ACP 권한 요청은 취소됩니다. 이 경계를 우회하는 문제는 보안 취약점으로 취급합니다.
