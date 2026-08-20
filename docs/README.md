# KHALA VOICE — 문서

음성 회의 녹음 · 전사 · AI 요약 서비스. 데스크톱 웹 / 모바일 웹 / PWA.

`autosquad/sisyphus`의 Meeting Recorder 기능을 독립 앱으로 분리하고,
계정 · 친구 · 공유 체계와 `devkanban`의 플랜 · 크레딧 체계를 결합한다.

## 읽는 순서

| # | 문서 | 내용 |
|---|---|---|
| 00 | [설정 체크리스트](00-setup-checklist.md) | **키를 어디에 넣는가** — 배포 후 이것부터 |
| 01 | [개요](01-overview.md) | 제품 범위 · 확정 결정 · 비범위 · 용어 |
| 02 | [아키텍처](02-architecture.md) | 스택 · 시스템 구성 · 리포 구조 · 배포 요구사항 |
| 03 | [도메인 모델](03-domain-model.md) | 전체 컨텍스트와 스키마 |
| 04 | [녹음 파이프라인](04-pipeline.md) | 녹음 → 업로드 → 전사 → 화자 → 요약 *(sisyphus 이식)* |
| 05 | [인증 · 공유](05-auth-sharing.md) | 계정 · 소셜 로그인 · 친구 · 공유 링크 · 권한 |
| 06 | [구독 · 크레딧](06-billing.md) | 플랜 · 크레딧 원장 · 사용량 집계 *(devkanban 이식)* |
| 07 | [설정 · 어드민](07-config-admin.md) | 설정 해석 순서 · 시크릿 정책 · 시스템 어드민 |
| 08 | [프론트엔드](08-frontend.md) | 라우팅 · core 분리 · 반응형 · PWA |
| 09 | [API](09-api.md) | REST 엔드포인트 명세 |
| 10 | [이식 대조표](10-porting-map.md) | sisyphus / devkanban에서 무엇을 어떻게 가져오는가 |
| 11 | [로드맵](11-roadmap.md) | 마일스톤 |
| 12 | [디자인 시스템](12-design-system.md) | 테마 4종 · 컴포넌트 규격 *(devkanban 이식)* |
| 13 | [실기기 테스트](13-device-testing.md) | 모바일 백그라운드 녹음 검증 절차 |
| 14 | [출처](14-provenance.md) | **무엇이 sisyphus/devkanban 어디서 왔는가** |

## 원칙

1. **시크릿은 코드에 존재하지 않는다.** 이 리포는 오픈소스로 공개된다.
   설정은 `DB → 환경변수 → 없음` 순으로만 해석하며, 코드에 리터럴 기본값을 두지 않는다.
   → [07-config-admin.md](07-config-admin.md)
2. **비즈니스 로직은 UI에서 분리한다.** 프론트 로직은 `packages/core`에 두고
   UI는 그 위의 껍데기로 만든다. UI를 몇 벌 만들지는 나중에 바꿀 수 있는 결정으로 유지한다.
   → [08-frontend.md](08-frontend.md)
3. **외부 워크플로 의존을 두지 않는다.** sisyphus가 n8n에 위임하던 S3 presign과
   AI 요약을 앱 안에서 직접 구현한다. 프롬프트도 리포에서 버전 관리한다.
4. **가져온 것은 출처를 남긴다.** sisyphus / devkanban 에서 온 것은
   코드 주석과 [14-provenance.md](14-provenance.md) 에 원본 경로까지 적는다.
   원본이 고쳐졌을 때 여기도 고쳐야 하는지 판단할 수 있어야 한다.
5. **집계는 항상 돌린다.** 지금은 실질 과금이 0이지만 크레딧 원장은 정확히 기록해서
   실사용량과 원가가 보이게 한다. 유료화는 스위치를 켜는 일이 되게 한다.
