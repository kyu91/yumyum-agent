# YumYum Soul format

YumYum이 소유하는 Soul 파일은 `~/Library/Application Support/YumYum/SOUL.md`입니다. 현재 앱에는 외부 파일 가져오기 기능이 없으며, [예제](../Examples/Souls/)는 참고용입니다.

## 문법

파일은 정확히 `# YumYum Soul`, 빈 줄, 고정 안전 문장으로 시작합니다. 그 뒤 아래 heading 중 값이 있는 항목만 이 순서로 나타날 수 있습니다.

1. `Name`
2. `Role / Identity`
3. `Personality`
4. `Speaking Style`
5. `Core Values`
6. `Likes`
7. `Dislikes / Avoidances`
8. `User Form of Address`
9. `Behavior Principles`
10. `Additional Instructions`

각 필드는 정규화 후 최대 2,000자이고 전체 필드 합계는 앞 순서부터 최대 12,000자입니다. CRLF는 LF로 바뀌고 줄의 연속 공백은 하나로 정규화됩니다. 필드 본문의 `## ` 또는 `\`로 시작하는 줄은 저장 시 `\`로 escape됩니다. 알 수 없는 heading, 중복·역순 heading, 잘못된 prefix, 비정규화 내용, 과대 파일은 파싱되지 않고 빈 프로필로 처리됩니다.

Soul은 새 논리 세션의 첫 프롬프트에만 적용되며 YumYum의 안전, 개인정보, 승인, 첨부 및 외부 변경 정책보다 낮은 우선순위입니다. hooks, includes, 환경변수 확장, 네트워크 접근 또는 명령 실행 문법은 없습니다. 비밀·자격증명·민감한 개인정보를 넣지 마세요.
