# 09. API

REST + SSE. 모든 응답은 JSON. 인증은 세션 쿠키(웹) 또는 게스트 토큰(공유 링크).

## 공통 규약

| 항목 | 규칙 |
|---|---|
| 성공 | `200` / `201` + 리소스 JSON |
| 검증 실패 | `422` + `{ "status": "error", "reason": {...} }` |
| 인증 없음 | `401` |
| **권한 없음** | `404` — **403 을 쓰지 않는다.** 403 은 "그 리소스는 있는데 네가 못 볼 뿐"을 알려준다 |
| **접근 불가(lv3)** | `404` — 위와 같은 이유로 같은 응답이다 |
| 링크 만료/비활성/소진 | `410` — 셋을 구분하지 않는다. 구분하면 토큰이 한때 유효했다는 정보가 샌다 |
| PIN 불일치 | `401` |
| 시도 초과(PIN 대입 방어) | `429` |
| 응답의 권한 | 회의 관련 응답에 `role: "reviewer" \| "contributor" \| "viewer"` 포함 |
| 마스킹 | Viewer에게는 `audio_url`을 내려주지 않는다 |

---

## 인증

| 메서드 | 경로 | 설명 |
|---|---|---|
| `POST` | `/api/auth/register` | 이메일 가입 (초대코드 정책에 따라 코드 필요) |
| `POST` | `/api/auth/login` | 이메일 로그인 |
| `POST` | `/api/auth/logout` | 현재 세션 종료 |
| `GET` | `/api/auth/providers` | **활성화된** 소셜 제공자 목록 (버튼 렌더용) |
| `GET` | `/auth/:provider` | OAuth 시작 — 비활성 제공자는 `404` |
| `GET` | `/auth/:provider/callback` | OAuth 콜백 — 비활성 제공자는 `404` |
| `POST` | `/api/auth/password/reset-request` | 재설정 메일 발송 |
| `POST` | `/api/auth/password/reset` | 토큰으로 재설정 |
| `POST` | `/api/auth/confirm` | 이메일 확인 |

## 계정

| 메서드 | 경로 | 설명 |
|---|---|---|
| `GET` | `/api/me` | 내 계정 + 구독 + 크레딧 잔액 |
| `PATCH` | `/api/me` | 이름 · 언어 · 시간대 |
| `POST` | `/api/me/password` | 비밀번호 변경 (다른 세션 무효화) |
| `GET` | `/api/me/sessions` | 로그인된 기기 목록 |
| `DELETE` | `/api/me/sessions/:id` | 특정 기기 로그아웃 |
| `DELETE` | `/api/me/sessions` | 전체 로그아웃 |
| `POST` | `/api/me/deletion` | 계정 삭제 예약 |
| `DELETE` | `/api/me/deletion` | 삭제 예약 취소 |

## 친구

| 메서드 | 경로 | 설명 |
|---|---|---|
| `GET` | `/api/friends` | 친구 목록 |
| `DELETE` | `/api/friends/:account_id` | 친구 해제 |
| `POST` | `/api/friends/:account_id/block` | 차단 |
| `GET` | `/api/friend-invitations` | 보낸/받은 초대 |
| `POST` | `/api/friend-invitations` | 초대 생성 (`email` 또는 링크형) |
| `DELETE` | `/api/friend-invitations/:id` | 초대 취소 |
| `GET` | `/api/friend-invitations/:token` | 초대 정보 조회 (비로그인 가능) |
| `POST` | `/api/friend-invitations/:token/accept` | 수락 |
| `POST` | `/api/friend-invitations/:token/decline` | 거절 |

## 회의

| 메서드 | 경로 | 권한 | 설명 |
|---|---|---|---|
| `GET` | `/api/meetings` | — | 목록 + `total`. 파라미터는 아래 표 참고 |
| `POST` | `/api/meetings` | — | 생성 (생성자가 Reviewer) |
| `GET` | `/api/meetings/:id` | Viewer+ | 상세 (세션 포함) |
| `PATCH` | `/api/meetings/:id` | Contributor+ | 제목 · 설명 · 토픽 · 라벨 · 시작일 |
| `GET` | `/api/meetings/:id/taxonomy` | Contributor+ | 이 회의에 붙일 수 있는 분류 (**회의 owner 의 것**) |
| `POST` | `/api/meetings/:id/summarize` | Contributor+ | 요약 생성/재생성. 큐잉만 하고 202 로 즉시 응답 |
| `PATCH` | `/api/meetings/:id/status` | Reviewer(archive) / Contributor+ | 상태 전이 |
| `PATCH` | `/api/meetings/:id/permissions` | Reviewer | 공개 범위 · Reviewer · Contributor |
| `DELETE` | `/api/meetings/:id` | Reviewer | soft delete |
| `POST` | `/api/meetings/:id/archive` | Reviewer | 아카이브 |
| `GET` | `/api/meetings/:id/export.md` | Viewer+ | 마크다운 내보내기 |

## 녹음 세션

| 메서드 | 경로 | 권한 | 설명 |
|---|---|---|---|
| `POST` | `/api/meetings/:id/sessions` | Contributor+ | 세션 생성. `{started_at_unix, metadata:{language}}` |
| `POST` | `/api/sessions/:id/upload` | Contributor+ | 업로드 등록. `{duration_seconds, file_size_bytes, mime_type}` |
| `GET` | `/api/sessions/:id/audio` | Contributor+ | 서명된 오디오 URL 로 302. **Viewer 는 404** |
| `POST` | `/api/sessions/:id/transcribe` | Contributor+ | 전사 큐잉 (크레딧 소모). 이미 전사된 세션에 다시 부르면 재전사 |
| `PATCH` | `/api/sessions/:id/speakers` | Contributor+ | `speaker_map` 또는 `transcript` 또는 둘 다 |
| `DELETE` | `/api/sessions/:id` | Reviewer | 세션 삭제 |

### 목록 필터

| 파라미터 | 값 | 비고 |
|---|---|---|
| `status` | `active` · `completed` · `archived` · `all` | 비우면 **아카이브를 숨긴다** |
| `topic_id` | 토픽 id | |
| `label_ids` | 쉼표 구분 또는 배열 | |
| `label_mode` | `and`(기본) · `or` | 모르는 값은 `and` 로 좁힌다 — 넓히는 쪽으로 기울면 필터가 조용히 무력해진다 |
| `participant_id` | 계정 id | Reviewer · owner · Contributor 중 하나로 낀 회의 |
| `from` · `to` | ISO8601 | `started_at` 기준 |
| `q` | 문자열 | 제목 · 설명 · 요약. `%` `_` 는 이스케이프한다 |
| `order` | `archived_desc` | 비우면 `started_at` 내림차순 |
| `limit` · `offset` | 정수 | 기본 50 |

응답의 `total` 은 **필터에 걸린 전체 개수**다 (이 페이지 개수가 아니다).
목록과 카운트는 같은 술어를 쓴다 — 복붙하면 반드시 어긋난다.

회의 응답에는 `topic` · `labels` 가 이름·색까지 풀려서 들어온다.
그 회의 전문을 이미 읽을 수 있는 사람에게 분류 이름을 숨기는 것은 방어가 아니다.

### 분류 (토픽 · 라벨)

| 메서드 | 경로 | 설명 |
|---|---|---|
| `GET` | `/api/topics` | 내 토픽 + `meeting_count` |
| `POST` | `/api/topics` | `{name, color?}` → 201 |
| `PATCH` | `/api/topics/reorder` | `{ids:[...]}` **전체 목록** |
| `PATCH` | `/api/topics/:id` | `{name?, color?}` |
| `DELETE` | `/api/topics/:id` | `{status, detached_meetings}` |
| `GET` `POST` `PATCH` `DELETE` | `/api/labels…` | 위와 동일 (reorder 없음) |

- 색은 **팔레트 키** 10종 (`red` … `gray`). 자유 HEX 를 받지 않는다 — 테마가 넷이라 임의 색이 배경에서 안 읽힌다
- **남의 분류도 없는 분류도 404.** 403 을 주면 그 id 의 존재가 드러난다
- 지우면 소프트 삭제 + **쓰던 회의에서 즉시 떼어낸다.** 참조만 남기면 그 회의는 어떤 필터로도 안 걸린다
- 순서 변경은 **전체 목록을 통째로** 받는다. 일부만 보내면 `422` 이고 아무것도 바뀌지 않는다

### 오디오는 URL 을 내려보내지 않는다

`recording_key/4` 는 `meeting_id` · `session_id` · `started_at_unix` · 확장자로 **완전히 결정된다.**
이 값들은 회의를 볼 수 있는 사람이면 응답으로 다 받는다. 그래서 `audio_url` 필드만 빼는 것으로는
Viewer 마스킹이 되지 않는다 — 키를 손으로 조립하면 그만이다.

Contributor 이상에게 `audio_href`(= `GET /api/sessions/:id/audio`) 만 준다.
그 엔드포인트가 권한을 다시 판정하고 **서명된 URL 로 302** 한다.
서명 만료는 녹음 길이의 3배(최소 15분 · 최대 6시간)다 — 재생 도중 Range 요청이
만료로 끊기지 않게 하면서 링크가 새어도 영구히 살지는 않게 한다.

**버킷은 비공개여야 한다.** 공개 버킷이면 위의 방어가 전부 무의미하다.

### 업로드 대상은 서버가 정한다

`POST /api/uploads/presign` 이 키를 정해 세션에 기록하고, `upload` 는 주소를 받지 않는다.
클라이언트가 준 주소를 저장하면 전사 워커가 그것을 그대로 GET 하므로 사설망 요청이 된다 (SSRF).

- 이미 업로드가 끝난 세션에 presign 을 다시 요청하면 `422 already_uploaded` — 같은 키에 덮어쓰기를 막는다
- 아카이브된 회의의 업로드 · 전사 · 전사본 수정은 `422 meeting_archived`

**전사 편집은 `PATCH .../speakers` 하나로 받는다.**
화자 이름 변경 · 세그먼트 화자 변경 · 텍스트 편집 · 분할 · 원본 복원이
모두 "고쳐진 transcript 를 통째로 보낸다"로 귀결되기 때문이다.
세그먼트별 엔드포인트를 따로 두면 편집 중간 상태가 서버에 남는다.

원본 복원도 같은 경로다. 원본은 `transcript.original_segments` 에 들어 있고
되돌리기는 클라이언트가 그것을 `segments` 로 되돌려 보내는 것으로 끝난다.

### 화자 업데이트 페이로드

```jsonc
// 화자 칩 변경 — 그 화자의 모든 발언에 반영
{ "speaker_map": { "speaker_1": { "name": "홍길동", "account_id": "acct_xxx" } } }

// 세그먼트 화자 변경 — 그 한 줄만
{ "transcript": { "segments": [ /* speaker가 바뀐 전체 배열 */ ] } }
```

## 요약

| 메서드 | 경로 | 권한 | 설명 |
|---|---|---|---|
| `POST` | `/api/meetings/:id/summary` | Contributor+ | 요약 생성 (없을 때) |
| `POST` | `/api/meetings/:id/summary/retry` | Contributor+ | 재요약 (강제) |

응답은 즉시 `202`를 주고, 완료는 SSE로 알린다.

## 업로드

| 메서드 | 경로 | 설명 |
|---|---|---|
| `POST` | `/api/uploads/presign` | `{meeting_id, session_id, file_name, content_type}` → `{upload_url, download_url, key, expires_in}` |

## 분류

| 메서드 | 경로 | 설명 |
|---|---|---|
| `GET` `POST` | `/api/topics` | 목록 · 생성 |
| `PATCH` `DELETE` | `/api/topics/:id` | 수정 · 삭제 |
| `GET` `POST` | `/api/labels` | 목록 · 생성 |
| `PATCH` `DELETE` | `/api/labels/:id` | 수정 · 삭제 |

## 아카이브 검색

| 메서드 | 경로 | 설명 |
|---|---|---|
| `GET` | `/api/archive` | `?q=&topic_id=&label_ids[]=&label_mode=and\|or&from=&to=&participant_id=&language=&cursor=` |

응답에 매칭 스니펫 포함:
```jsonc
{ "meetings": [ { "id": "meet_x", "title": "...",
    "matches": [ { "session_id": "mrss_a", "time_label": "00:12:34",
                   "snippet": "…음성 녹음 배포로 갑시다…" } ] } ],
  "next_cursor": "..." }
```

## 공유

| 메서드 | 경로 | 권한 | 설명 |
|---|---|---|---|
| `GET` | `/api/meetings/:id/share-links` | Reviewer | 링크 목록. **평문 토큰·PIN 없음** |
| `POST` | `/api/meetings/:id/share-links` | Reviewer | 발급. `{granted_role, max_uses?, expires_at?, require_name?, require_email?, with_pincode?}` → `201` + `url`·`pincode` |
| `PATCH` | `/api/share-links/:id` | Reviewer | `{is_active?, max_uses?, expires_at?, require_name?, require_email?}` |
| `POST` | `/api/share-links/:id/rotate` | Reviewer | 토큰 재발급 → `url` |
| `POST` | `/api/share-links/:id/pincode` | Reviewer | `{enabled: bool}` → `pincode` (켤 때만) |
| `DELETE` | `/api/share-links/:id` | Reviewer | 폐기 → `204`. **들어와 있는 게스트도 끊긴다** |

### 평문은 한 번만 나간다

`url` 과 `pincode` 는 **발급 · 재발급 · PIN 켜기 응답에만** 실린다.
DB 에는 sha256 해시(토큰)와 Bcrypt 해시(PIN)만 있으므로 서버도 원본을 모른다.
잃어버리면 `rotate` 로 재발급하는 수밖에 없다.

`granted_role` 은 **발급 이후 바꿀 수 없다.** 배포된 `viewer` 링크를 `contributor` 로
올리면 그 링크를 받은 모든 사람의 권한이 소급 상승한다. 바꾸려면 폐기 후 재발급한다.

### 게스트 (인증 불필요)

| 메서드 | 경로 | 설명 |
|---|---|---|
| `GET` | `/api/public/share/:token` | 요구 조건만. **회의 내용은 제목조차 주지 않는다** |
| `POST` | `/api/public/share/:token/enter` | `{display_name?, email?, pincode?}` → `guest_token`, `use_count` 증가 |
| `GET` | `/api/public/guest/meeting` | 회의 조회. **경로에 회의 id 가 없다** |
| `GET` | `/api/public/guest/sessions/:id/audio` | 서명된 오디오로 302. Contributor 게스트만 |
| `DELETE` | `/api/public/guest/session` | 게스트가 스스로 나간다 → `204` |

게스트 자격은 `X-Guest-Token` 헤더로 보낸다. 쿠키를 쓰지 않는 이유는
`:api` 파이프라인에 CSRF 방어가 없고, 쿠키는 도메인 전역이라 "회의 하나만"이라는
제약과 어긋나기 때문이다.

### 게스트가 볼 회의는 세션이 정한다

`/api/public/guest/*` 경로에 **회의 id 가 없다.** 게스트 세션 행에 `meeting_id` 가
박혀 있고 서버가 그것만 쓴다. 요청이 다른 회의를 가리킬 방법 자체가 없다.

### 게스트에게 주지 않는 것

- `owner_id` · `reviewer_id` · `contributor_ids` · `permissions` — 참여자 목록
- `speaker_map[].account_id` — **전사에 딸려 나가기 쉬운 자리다**
- `last_summary_error` — 내부 예외 원문
- `total_credits_charged` · `credits_charged` — 회의 소유자의 과금 정보

### 게스트가 닿을 수 없는 것

전사 · 요약 · 업로드 · presign 라우트를 **게스트 스코프에 두지 않았다.**
링크 하나가 회의 소유자의 크레딧에 대한 위임장이 되면 안 된다.

로그인 계정이 링크로 들어오면 **계정 권한이 우선**한다.

## 구독 · 크레딧

| 메서드 | 경로 | 설명 |
|---|---|---|
| `GET` | `/api/billing/subscription` | 현재 구독 + 플랜 |
| `GET` | `/api/billing/credits` | 잔액 + 묶음별 만료 |
| `GET` | `/api/billing/ledger` | 사용 내역 (`?cursor=`) |
| `GET` | `/api/billing/plans` | 공개 플랜 목록 |

## SSE

```
GET /api/sse/meetings/:id
```

| 이벤트 | 페이로드 |
|---|---|
| `session_status_changed` | `{meeting_id, session_id, status, changed_by_id}` |
| `session_transcription_failed` | `{meeting_id, session_id, error_message}` |
| `summary_completed` | `{meeting_id}` |
| `summary_failed` | `{meeting_id, error}` |

클라이언트는 `changed_by_id`가 자신이면 무시하고, 로컬 편집 직후에는
일정 시간 갱신을 보류해 편집 내용이 덮이지 않게 한다.
