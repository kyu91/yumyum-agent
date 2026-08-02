# Open-source readiness checklist

- [ ] 소스·문서·자산의 소유권과 공개 권한 확인
- [ ] YumYum 이름과 로고의 상표 사용·등록·기여자 사용 정책 결정
- [ ] 전체 Git history 비밀 검사 및 결과 보관
  - gitleaks와 trufflehog는 로컬에서 사용할 수 없어 아직 실행하지 않음
- [ ] 공개할 clean snapshot 또는 전체 history 유지 여부 결정
- [ ] 스크린샷·영상·fixture의 사용자 정보, 경로, 알림, 계정명 redaction 확인
- [ ] GitHub 저장소 설명, 기본 브랜치, 라이선스 감지와 Topics 설정
- [ ] branch protection/ruleset, 필수 CI, 리뷰 수, force-push·삭제 제한 설정
- [ ] GitHub Private Vulnerability Reporting 활성화 및 SECURITY.md 흐름 확인
- [ ] 행동 강령 신고 전용 비공개 채널 구성 후 CODE_OF_CONDUCT.md 공개 blocker 해제
- [ ] Issue/PR template, blank issue 비활성화, 행동 강령 적용 확인
- [ ] Dependabot·CodeQL 등 추가 GitHub 기능의 필요성과 권한 결정
- [ ] 서명, hardened runtime, entitlements, 공증, clean-machine, 체크섬 릴리스 gate 완료
- [ ] 번들 ID, CPU 지원, fixture 포함, TCC 안내, 자격증명 보관, rollback 결정 완료

현재 `NOTICE`는 별도 제3자 attribution 요구가 확인되지 않아 추가하지 않습니다. 공급업체 이름은 CLI 호환성 설명에만 사용하며 로고는 포함하지 않습니다.
