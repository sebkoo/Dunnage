# 아키텍처 결정 — 클라우드 경계

이 문서는 **결정**을 담습니다. 손으로 따라 하는 절차는 `docs/aws-learning.md` 에 있고,
에이전트가 지켜야 할 규칙은 `CLAUDE.md` 에 있습니다. 셋을 섞지 마세요.

## 세 평면

세 가지 책임을 분리해서 보세요. 이게 이 프로젝트에서 가장 중요한 구분입니다.

```
CONTROL PLANE — 누가 무엇을 올릴 수 있고, 어디에 올리는가
─────────────────────────────────────────────────────────
 iPhone
   │ Access token (JWT)
   ▼
 Cognito User Pool          Access token 발급 (기본 1시간, 설정 가능)
   │
   ▼
 API Gateway (HTTP API)     JWT authorizer가 서명·iss·aud/client_id·exp·scope 검증
   │
   ▼
 Lambda
   ├── 업로드 세션 생성
   ├── 파트별 presigned URL 발급 (짧은 만료, 내 prefix로만)
   │     └── URL 자체가 bearer 성격의 권한입니다. 가진 사람은
   │         만료 전까지 그 작업을 할 수 있으니 secret처럼 다루세요
   └── 서버가 실제로 보유한 파트 조회      ← 이 설계에서는 백엔드가 수행합니다
   │                                        (s3:ListMultipartUploadParts 권한을
   │                                         control plane에 둡니다)
   ▼
 S3 multipart upload        어느 파트가 실제로 존재하는가


APPLICATION TRUTH — 무슨 일이 있었는가
─────────────────────────────────────────────────────────
 Dunnage event log (기기)
   └── intent / attempts / confirmations / failures


OPTIONAL CONTROL-PLANE STATE
─────────────────────────────────────────────────────────
 [DynamoDB, 필요가 입증되면]
   └── 애플리케이션 수준 조회·소유권·멱등성·수명주기 추적이
       S3만으로 효율적이지 않을 때에만
```

### 왜 이렇게 나누는가

```
Uploaded part   ≠   Completed object
```

파트를 다 올려도 `CompleteMultipartUpload` 가 성공하기 전까지 객체는 존재하지 않고, 올라간 파트는 계속 스토리지를 점유합니다. 이 프로젝트의 논지가 바로 이 간극을 다룹니다.

**`S3 ObjectCreated` 는 "업로드 성공"이 아닙니다.** multipart는 `CompleteMultipartUpload` 가 성공해야 객체가 생깁니다. 그 이벤트는 *S3에 완성된 객체가 만들어졌다*는 신호이지, *사용자의 전체 워크플로가 성공했다*와 같지 않습니다. 이 프로젝트의 논지가 정확히 그 차이를 다룹니다.

**Dunnage separates local intent, transport authority, and cloud coordination.**

그리고 전송 쪽에서 세 가지를 더 갈라야 합니다. 면접에서 "백그라운드 URLSession이면 재개되지 않나요"가 나오면 이 세 줄이 답입니다.

```
background URLSession        적격한 백그라운드 생명주기에서 전송을 이어 스케줄·실행
IETF resumable upload        바이트 단위 재개. offset 모양. 서버가 참여해야 함 (URLSession 구현)
S3 multipart                 파트 번호의 집합 모양. 재개 가능한 바이트 오프셋이 아님
```

셋 중 하나가 다른 둘을 함의하지 않습니다. 그래서 Core는 "확인된 진행"이 오프셋인지 집합인지 모르고, 그 의미는 트랜스포트 계약이 정합니다. 이 한 문장이 README·ADR·면접에서 공통으로 쓸 중심 문장입니다. 세 평면(plane)으로 부르면 설명이 훨씬 쉬워집니다. README와 ADR에도 이 용어를 쓰세요.

| 평면 | 무엇을 담당하나 | 무엇의 권위인가 |
|---|---|---|
| **Control plane** | 권한과 조율 — Cognito, API Gateway, Lambda, (필요하면 DynamoDB) | 누가 누구의 업로드를 조회하고 URL을 받을 수 있는가 |
| **Data plane** | 바이트 — S3 multipart | 스토리지가 어느 **파트**를 보유했다고 보고하는가 |
| **Local plane** | 클라이언트 의도와 이력 — event log | 사용자가 언제 무엇을 의도했고 무슨 일이 있었는가 |

S3는 **자기가 노출하는 multipart 상태에 대해서만** 권위입니다. 자동으로 애플리케이션 수준 업로드 원장이 되지는 않습니다 — `CompleteMultipartUpload` 자체가 클라이언트가 보관한 파트 번호와 ETag 목록을 요구한다는 사실이 그 증거입니다. 그리고 어느 쪽도 단독으로 완전한 원장이 아닙니다.

**이벤트는 관찰 신호이지 상태 전이의 근거가 아닙니다.**

```
S3 state
    ↓  event / poll
관찰
    ↓  내가 정의한 reconciliation rule
application state
```

`ObjectCreated` 가 뜻하는 것은 **"S3가 완성된 객체가 존재한다고 보고했다"** 입니다. data plane에 대한 증거이지, 애플리케이션 워크플로 전체가 성공했다는 증명이 아닙니다.

그럼 언제 성공인가? 애플리케이션 상태는 이렇게 유도됩니다.

> Application state is derived by replaying the event log and applying explicitly defined reconciliation rules to transport observations.

이벤트 로그가 권위이고, 전송 관찰은 입력이며, 전이 규칙이 둘을 합칩니다. 이벤트 하나가 상태를 직접 바꾸는 게 아닙니다.

**ETag를 애플리케이션 콘텐츠 해시로 취급하지 마세요.** multipart 객체의 ETag는 파일 전체의 MD5가 아닙니다. 무결성 검증이 필요하면 애플리케이션이 자기 해시(예: SHA-256)를 따로 계산해서 보관해야 합니다. ADR에 `ETag ≠ application content hash` 라고 한 줄 남겨두세요.

### 면접에서 나오는 질문

**"DynamoDB는 왜 필요합니까?"** 바로 답하면 안 됩니다. 지금 이 프로젝트의 올바른 답:

> "I don't know yet. S3 already has authoritative multipart state. I'd introduce DynamoDB only if the control plane needs application-level queries, ownership, idempotency state, or lifecycle tracking that S3 cannot provide efficiently."

AWS 이력서 키워드 때문에 DynamoDB를 미리 넣지 마세요. 안 넣은 이유를 설명할 수 있는 쪽이 훨씬 강합니다.

**"②가 왜 필요한가"** — 앱이 S3 자격증명을 직접 들면 앱을 뜯은 사람이 남의 폴더도 건드립니다. Lambda가 매번 짧고 좁은 URL을 발급하면 그 URL이 새도 피해가 한정됩니다.

다만 "내 prefix로만"은 URL을 만든다고 자동으로 보장되지 않습니다. 구현 계약으로 내려가야 합니다.

```
authenticated principal
        ↓
upload 소유권 확인
        ↓
서버가 object key를 생성
        ↓
그 key + 그 operation 에만 유효한 presigned URL
```

ADR에 한 줄로 박아두세요: **The server derives object ownership from the authenticated principal, not from client-supplied path fields.** 요청 본문의 `uploads/<user-id>/...` 를 그대로 믿으면 안 됩니다.

**"③이 왜 서버를 안 거치나"** — Lambda가 바이트를 못 받는 게 아닙니다. **받을 수 있지만 일부러 안 씁니다.** control plane과 data plane의 분리가 1차 이유고, Lambda는 업로드를 조율하되 바이트는 나르지 않습니다. 부차적으로 Lambda 실행 시간·메모리·비용·처리량이 붙고, 최대 실행 시간이 900초라는 상한도 있습니다 — 하지만 그건 결론이지 이유가 아닙니다.

**"기기가 직접 재개 상태를 조회하면 되지 않나"** — S3가 막는 게 아니라 **이 설계가 그렇게 두지 않습니다.** `ListParts` 는 `s3:ListMultipartUploadParts` 권한을 요구하는 별도의 S3 API 호출이고, 파트별 presigned PUT URL 자체는 그 호출을 인가하는 수단이 아닙니다. 그 권한은 control plane에 두고 기기는 백엔드가 주는 progress view를 씁니다. 적절한 자격증명을 가진 클라이언트라면 호출할 수 있다는 점은 인정하고, 그렇게 두지 않기로 한 이유를 말하는 편이 낫습니다.

## 면접에서 나오는 질문 — 한 줄 답

각 질문에 한 줄로 답할 수 있으면 이 JD 기준으로는 충분합니다.

| 질문 | 핵심 한 줄 |
|---|---|
| Cognito User Pool과 Identity Pool 차이는? | User Pool은 사용자 명부라 JWT를 주고, Identity Pool은 그 JWT를 AWS 임시 자격증명으로 바꿔줍니다 |
| 모바일 앱에 AWS 액세스 키를 넣으면 왜 안 되나? | 앱 바이너리는 뜯을 수 있고, 키에는 만료가 없으며, 서버가 그 키로 뭘 하는지 통제할 수 없습니다 |
| API Gateway REST API vs HTTP API? | HTTP API가 싸고 빠릅니다. 요청/응답 변환이나 사용량 계획이 필요할 때만 REST API |
| JWT authorizer vs Lambda authorizer? | Cognito 토큰 검증으로 충분하면 HTTP API의 내장 JWT authorizer를 씁니다. 요청별 커스텀 인가 로직이 필요할 때 Lambda authorizer를 검토하고, 그만큼 지연시간과 비용이 붙습니다 |
| presigned URL은 언제 만료되나? | 지정한 만료 시각과 **서명한 자격증명의 만료** 중 먼저 오는 쪽. Lambda 역할로 서명하면 역할 세션 만료에 묶입니다 |
| 백그라운드 URLSession이면 업로드가 이어서 재개되나? | 백그라운드 세션이 주는 건 **스케줄·실행의 지속성**입니다. 서버가 URLSession이 쓰는 IETF HTTP resumable upload 프로토콜에 참여하지 않으면 URLSession은 그 서버에 대해 **바이트 단위 재개를 제공하지 못합니다.** 그러면 복구는 트랜스포트 계약이 정하는 방식을 따르고, 전체 재전송이 될 수도 있습니다 (tus 진영 클라이언트의 관찰: *"By default, iOS will retry the full upload instead of resuming where the upload has left off."*) |
| 그럼 S3에서는 어떻게 재개하나? | multipart. 재개 기준은 오프셋이 아니라 `ListParts`가 돌려주는 파트 **집합**입니다. 오프셋은 클라이언트가 고정 파티션을 정했을 때만 유도되는 값입니다 |
| 기기가 `ListParts`를 직접 호출하면 되지 않나? | **기술적으로는 가능합니다** — `s3:ListMultipartUploadParts` 권한을 가진 주체라면. **이 설계에서는 하지 않습니다.** 클라이언트에 그 권한을 주지 않고 control plane이 progress view를 제공합니다. 파트별 presigned PUT URL 자체는 그 호출을 인가하는 수단이 아닙니다 |
| S3가 업로드 원장 아닌가? | 어느 파트를 갖고 있는지에 대한 권위일 뿐입니다. `CompleteMultipartUpload`는 클라이언트가 보관한 파트 번호와 ETag 목록을 요구하므로, 애플리케이션 원장은 별개입니다 |
| 왜 파일을 서버로 안 보내고 S3에 직접 올리나? | Lambda를 통과시키면 파일 크기만큼 실행 시간·메모리 비용이 붙고 15분 제한에 걸립니다 |
| DynamoDB 파티션 키는 어떻게 정하나? | 조회 패턴을 먼저 정하고 거기서 역산합니다. 접근이 한 키에 몰리면 핫 파티션이 됩니다 |
| GSI는 언제 필요한가? | 기본 키가 아닌 다른 순서로 조회해야 할 때. 예: "내 것 중 최근 갱신순" |
| single table design이 뭔가? | 여러 엔터티를 한 테이블에 넣고 키 접두어로 구분하는 방식. 조인이 없는 대신 조회 패턴이 고정됩니다 |
| Lambda 콜드 스타트는 어떻게 줄이나? | 패키지 크기 축소, arm64, 필요하면 provisioned concurrency. 다만 모바일 업로드 발급 경로에서는 대개 문제가 안 됩니다 |
| 업로드 재시도에서 중복은 어떻게 막나? | 클라이언트가 생성한 UUID를 멱등성 키로 쓰고, 서버는 조건부 쓰기로 같은 키를 두 번 반영하지 않습니다 |
| 액세스 토큰이 만료되면 클라이언트가 뭘 하나? | 401을 받으면 refresh flow로 새 액세스 토큰을 받고, 원래 요청을 **안전한 범위에서** 한 번 재시도합니다. 갱신도 실패하면 재로그인. 동시 갱신 레이스는 갱신을 actor 하나 뒤로 직렬화해서 막습니다 |

---

