-- MINDLET schema.sql  (신규 빈 DB 전용)
-- 이미 memos 테이블에 데이터가 있는 DB에는 이 파일 대신 migration.sql을 사용하세요.
-- 실행 위치: Supabase Dashboard > SQL Editor
-- 참고: anon / authenticated / service_role 은 DB 역할 이름이며 레거시 API 키 이름이 아닙니다.

------------------------------------------------------------------
-- 1. 테이블
------------------------------------------------------------------
create table public.memos (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 80),
  content text not null check (char_length(content) between 1 and 2000),
  color text not null default '#fef3c7' check (char_length(color) > 0),
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 작성자 암호 해시 (공개 테이블과 분리). 메모 삭제 시 함께 삭제됩니다.
create table public.memo_credentials (
  memo_id uuid primary key references public.memos(id) on delete cascade,
  password_hash text not null
);

-- 서버 전용: 관리자 세션 (원본 토큰이 아닌 HMAC 검증값만 저장)
create table public.admin_sessions (
  token_hash text primary key,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

-- 서버 전용: 요청 제한 카운터
create table public.rate_limits (
  key text primary key,
  window_started_at timestamptz not null default now(),
  hit_count integer not null default 0
);

create index memos_created_at_idx on public.memos (created_at desc);
create index memos_position_idx on public.memos (position asc, created_at desc);
create index admin_sessions_expires_at_idx on public.admin_sessions (expires_at);
create index rate_limits_window_started_at_idx on public.rate_limits (window_started_at);

------------------------------------------------------------------
-- 2. 트리거와 함수 (SECURITY INVOKER: 호출한 역할의 권한으로 실행)
------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger memos_set_updated_at
before update on public.memos
for each row
execute function public.set_updated_at();

-- 메모와 암호 해시를 한 트랜잭션(함수 호출 1회)으로 저장
create or replace function public.create_memo_with_credentials(
  p_title text,
  p_content text,
  p_password_hash text,
  p_color text default '#fef3c7'
)
returns public.memos
language plpgsql
set search_path = public
as $$
declare
  inserted_memo public.memos;
begin
  if char_length(p_title) < 1 or char_length(p_title) > 80 then
    raise exception 'Invalid title length';
  end if;

  if char_length(p_content) < 1 or char_length(p_content) > 2000 then
    raise exception 'Invalid content length';
  end if;

  if p_password_hash is null or char_length(p_password_hash) < 50 then
    raise exception 'Invalid password hash';
  end if;

  insert into public.memos (title, content, color, position, created_at, updated_at)
  values (p_title, p_content, coalesce(nullif(p_color, ''), '#fef3c7'), 0, now(), now())
  returning * into inserted_memo;

  insert into public.memo_credentials (memo_id, password_hash)
  values (inserted_memo.id, p_password_hash);

  return inserted_memo;
end;
$$;

-- 시도를 1회 기록하고, 한도 이내이면 true 를 반환 (고정 윈도우, 원자적)
create or replace function public.rate_limit_hit(
  p_key text,
  p_max integer,
  p_window_seconds integer
)
returns boolean
language plpgsql
set search_path = public
as $$
declare
  current_count integer;
begin
  if p_max < 1 or p_window_seconds < 1 then
    raise exception 'Invalid rate limit';
  end if;

  delete from public.rate_limits
  where window_started_at < now() - interval '1 day';

  insert into public.rate_limits as r (key, window_started_at, hit_count)
  values (p_key, now(), 1)
  on conflict (key) do update
  set hit_count = case
        when r.window_started_at <= now() - make_interval(secs => p_window_seconds)
        then 1 else r.hit_count + 1 end,
      window_started_at = case
        when r.window_started_at <= now() - make_interval(secs => p_window_seconds)
        then now() else r.window_started_at end
  returning r.hit_count into current_count;

  return current_count <= p_max;
end;
$$;

-- 기록 없이 현재 윈도우가 아직 한도 미만이면 true (실패 횟수 선검사용)
create or replace function public.rate_limit_check(
  p_key text,
  p_max integer,
  p_window_seconds integer
)
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce(
    (select r.hit_count < p_max
     from public.rate_limits r
     where r.key = p_key
       and r.window_started_at > now() - make_interval(secs => p_window_seconds)),
    true
  );
$$;

------------------------------------------------------------------
-- 3. RLS
------------------------------------------------------------------
alter table public.memos enable row level security;
alter table public.memo_credentials enable row level security;
alter table public.admin_sessions enable row level security;
alter table public.rate_limits enable row level security;

-- 공개 조회 정책 하나만 둡니다. 나머지 테이블에는 정책을 만들지 않습니다(= 직접 접근 불가).
create policy "Public memos are readable"
on public.memos
for select
to anon, authenticated
using (true);

------------------------------------------------------------------
-- 4. GRANT (이 앱 테이블/함수에만 적용, public 스키마 전체는 건드리지 않음)
------------------------------------------------------------------
revoke all on table public.memos from public, anon, authenticated;
revoke all on table public.memo_credentials from public, anon, authenticated;
revoke all on table public.admin_sessions from public, anon, authenticated;
revoke all on table public.rate_limits from public, anon, authenticated;

grant select (id, title, content, color, position, created_at, updated_at)
on public.memos to anon, authenticated;

grant all on table public.memos to service_role;
grant all on table public.memo_credentials to service_role;
grant all on table public.admin_sessions to service_role;
grant all on table public.rate_limits to service_role;

revoke all on function public.set_updated_at() from public, anon, authenticated;
revoke all on function public.create_memo_with_credentials(text, text, text, text)
  from public, anon, authenticated;
revoke all on function public.rate_limit_hit(text, integer, integer)
  from public, anon, authenticated;
revoke all on function public.rate_limit_check(text, integer, integer)
  from public, anon, authenticated;

grant execute on function public.create_memo_with_credentials(text, text, text, text)
  to service_role;
grant execute on function public.rate_limit_hit(text, integer, integer) to service_role;
grant execute on function public.rate_limit_check(text, integer, integer) to service_role;
