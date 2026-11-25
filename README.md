# MINDLET

Next.js + Supabase + Vercel 기반의 단일 메모 보드입니다. 주소를 아는 사람은 메모를 보고 작성할 수 있고, 작성자는 4자리 암호로, 관리자는 별도 로그인 후 메모를 삭제합니다.

## 로컬 실행

1. 압축을 푼 프로젝트 폴더를 엽니다.
2. `node -v`, `npm -v` 확인 (Node.js 22 이상 권장).
3. `npm ci`
   - Windows PowerShell에서 `npm.ps1` 실행 정책 오류가 나면 `npm.cmd ci` 를 사용합니다.
4. `.env.example` 을 `.env.local` 로 복사하고 본인의 Supabase 값을 입력합니다.
   - `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`: Supabase > Project Settings > API Keys
   - `SUPABASE_SECRET_KEY`: 같은 화면의 Secret key (서버 전용)
5. 관리자 암호 해시 생성:

   ```bash
   node -e "require('bcryptjs').hash(process.argv[1], 12).then(console.log)" "원하는-관리자-암호"
   ```

   출력된 `$2b$12$...` 값을 `ADMIN_PASSWORD_HASH` 에 넣습니다. (`.env.local` 에서 `$` 때문에 문제가 되면 값을 작은따옴표로 감싸거나 `\$` 로 이스케이프합니다. Vercel 대시보드에는 그대로 입력합니다.)
6. 관리자 세션 비밀값 생성 후 `ADMIN_SESSION_SECRET` 에 입력:

   ```bash
   node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
   ```

7. DB 준비 (Supabase SQL Editor)
   - **신규 빈 DB**: `schema.sql` 실행
   - **기존 데이터가 있는 DB**: `migration.sql` 의 전제조건을 읽고, [A. 사전 확인] → 백업 → [B. 마이그레이션] 순서로 실행
8. `npm run dev` 후 http://localhost:3000 접속

## Vercel 배포

1. GitHub 저장소를 Vercel에 연결해 프로젝트를 가져옵니다.
2. Project Settings > Environment Variables 에 다음 다섯 개를 Production/Preview/Development에 등록합니다.

   ```
   NEXT_PUBLIC_SUPABASE_URL
   NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
   SUPABASE_SECRET_KEY
   ADMIN_PASSWORD_HASH
   ADMIN_SESSION_SECRET
   ```

   `SUPABASE_SECRET_KEY`, `ADMIN_PASSWORD_HASH`, `ADMIN_SESSION_SECRET` 에는 절대 `NEXT_PUBLIC_` 를 붙이지 않습니다.
3. Deploy 후 메모 작성/삭제, 관리자 로그인/삭제를 확인합니다. 환경 변수가 누락되면 서버 로그에 변수 이름만 출력됩니다.

## 보안 구조

- 브라우저는 Publishable key 로 공개 컬럼(`id,title,content,color,position,created_at,updated_at`)만 조회합니다.
- 작성/삭제/관리자 기능은 Node.js 서버 API 에서 Secret key(`server-only` 모듈)로 처리합니다.
- 작성자 암호는 서버에서 bcrypt 해시 후 `memo_credentials`(비공개)에 메모와 함께 RPC 한 번으로 저장합니다.
- 요청 제한은 Supabase `rate_limits` 테이블과 RPC 로 구현합니다 (작성 20회/10분/IP, 삭제 30회/10분/IP, 메모+IP 삭제 실패 5회/10분, 관리자 로그인 실패 5회/15분/IP). 제한 저장소 오류 시 작업은 진행되지 않습니다.
- 클라이언트 IP: Vercel 은 `X-Forwarded-For` 를 덮어써 외부 값을 전달하지 않으므로(`x-vercel-forwarded-for`/`x-real-ip` 도 동일 값) 이를 우선 사용합니다. 근거: https://vercel.com/docs/headers/request-headers
- 관리자 세션: 무작위 토큰을 `HttpOnly; SameSite=Strict; Path=/`(프로덕션 `Secure`) 쿠키로 발급하고, DB 에는 `HMAC(ADMIN_SESSION_SECRET, token)` 과 만료시간(8시간)만 저장합니다. 요청마다 DB 에서 검증하고 로그아웃 시 폐기합니다.
- 모든 상태 변경 API 는 `Origin` 헤더와 요청 URL 의 origin 이 같아야 하며, Origin 이 없으면 거부합니다.
