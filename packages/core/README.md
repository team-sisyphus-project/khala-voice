# @vr/core

녹음 · 업로드 · 도메인 로직. **UI 프레임워크에 의존하지 않는다.**

React import 를 여기에 넣지 마라. 이 규칙이 깨지면 분리한 의미가 없다.

## 왜 분리하는가

sisyphus 는 이 로직을 데스크톱(`meeting-recorder.js`)과 모바일(`mobile.js`)에
**두 벌 복사**해 두었고, 그 결과 일시정지 동작이 서로 갈렸다.
데스크톱은 세션을 쪼갰고 모바일은 한 세션을 유지했다. 게다가 데스크톱 재개 경로는
존재하지 않는 함수를 부르고 있어 아예 동작하지 않았다.

로직을 한 곳에 두면 그 유형의 사고가 구조적으로 막힌다.
UI 를 몇 벌 만들지도 나중에 바꿀 수 있는 값싼 결정이 된다.

## 구조

```
recorder/   MediaRecorder 엔진 · 파형 분석 · 타이머 · 일시정지 정책
upload/     IndexedDB 큐 · presign · PUT · 재시도
api/        타입 있는 API 클라이언트
domain/     transcript · speaker · 권한 판정
```

## 소비 방식

빌드 산출물을 만들지 않는다. TypeScript 소스를 그대로 import 한다.

- Phoenix esbuild — 스파이크 페이지·LiveView 훅
- Vite — React 앱

한 단계 줄어들고, 소스맵이 항상 원본을 가리킨다.
