-- MINDLET migration.sql  (기존 DB 변경 전용)
--
-- 대상: 이미 memos 테이블(및 필요 시 memos.password_hash)이 있는 Supabase DB.
-- 신규 빈 DB에는 schema.sql 을 사용하세요.
--
-- 적용 전제조건
--   1. 먼저 아래 [A. 사전 확인] 쿼리를 실행해 실제 구조를 확인합니다.
--      (memos 에 id, title, content 컬럼이 있어야 합니다. 구조가 다르면 실행하지 마세요.)
--   2. Dashboard > Database > Backups 로 백업하거나 `pg_dump` 로 memos 를 백업합니다.
--   3. 앱 트래픽이 적은 시간에 [B. 마이그레이션]을 한 번에 실행합니다.
--      전체가 하나의 트랜잭션이므로 검증에 실패하면 아무 것도 변경되지 않습니다.
--   4. 마이그레이션 후 새 앱 코드를 배포합니다. (구 코드는 새 권한 설정과 호환되지 않습니다.)
--
-- 보존되는 데이터: 메모 id, 제목, 내용, 생성/수정 일시, 기존 bcrypt 해시(memo_credentials 로 이전)
-- anon / authenticated / service_role 은 DB 역할 이름이며 레거시 API 키 이름이 아닙니다.

------------------------------------------------------------------
-- [A. 사전 확인]  (읽기 전용 — 먼저 단독으로 실행)
------------------------------------------------------------------
-- select column_name, data_type, is_nullable, column_default
--   from information_schema.columns
--  where table_schema = 'public' and table_name in ('memos', 'memo_credentials')
--  order by table_name, ordinal_position;
--
-- select conrelid::regclass, conname, pg_get_constraintdef(oid)
--   from pg_constraint where conrelid in ('public.memos'::regclass);
--
-- select policyname, cmd, roles, qual, with_check
--   from pg_policies where schemaname = 'public' and tablename in ('memos', 'memo_credentials');
--
-- select count(*) as memos,
--        count(*) filter (where password_hash is not null) as with_legacy_hash
--   from public.memos;   -- password_hash 컬럼이 없으면 이 쿼리는 오류가 납니다(정상).

------------------------------------------------------------------
-- [B. 마이그레이션]
------------------------------------------------------------------
begin;

-- B-1. 구조 확인
do $$
declare
  missing text;
begin
  if to_regclass('public.memos') is null then
    raise exception 'public.memos 테이블이 없습니다. 신규 DB라면 schema.sql 을 사용하세요.';
  end if;

  select string_agg(c, ', ') into missing
  from unnest(array['id', 'title', 'content']) as c
  where not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'memos' and column_name = c
  );
  if missing is not null then
    raise exception 'memos 에 필수 컬럼이 없습니다: %. 구조를 확인한 뒤 마이그레이션을 수정하세요.', missing;
  end if;

  if to_regclass('public.memo_credentials') is not null and (
    select count(*) from information_schema.columns
    where table_schema = 'public' and table_name = 'memo_credentials'
      and column_name in ('memo_id', 'password_hash')
  ) <> 2 then
    raise exception 'memo_credentials 가 이미 있지만 memo_id/password_hash 구조가 아닙니다.';
  end if;
end $$;

-- B-2. memos 에 필요한 컬럼 보강
alter table public.memos add column if not exists color text not null default '#fef3c7';
alter table public.memos add column if not exists position integer not null default 0;
alter table public.memos add column if not exists created_at timestamptz not null default now();
alter table public.memos add column if not exists updated_at timestamptz not null default now();
alter table public.memos alter column color set default '#fef3c7';

-- 기존 데이터가 새 길이 제약을 만족하는지 확인 (위반 시 중단)
do $$
begin
  if exists (
    select 1 from public.memos
    where char_length(title) not between 1 and 80
       or char_length(content) not between 1 and 2000
  ) then
    raise exception '길이 제한(제목 1~80, 내용 1~2000)을 벗어난 기존 메모가 있습니다. 데이터를 먼저 정리하세요.';
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'memos_title_length_check' and conrelid = 'public.memos'::regclass) then
    alter table public.memos add constraint memos_title_length_check check (char_length(title) between 1 and 80);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'memos_content_length_check' and conrelid = 'public.memos'::regclass) then
    alter table public.memos add constraint memos_content_length_check check (char_length(content) between 1 and 2000);
  end if;
end $$;

-- B-3. 비공개 테이블
create table if not exists public.memo_credentials (
  memo_id uuid primary key references public.memos(id) on delete cascade,
  password_hash text not null
);

create table if not exists public.admin_sessions (
  token_hash text primary key,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create table if not exists public.rate_limits (
  key text primary key,
  window_started_at timestamptz not null default now(),
  hit_count integer not null default 0
);

create index if not exists memos_created_at_idx on public.memos (created_at desc);
create index if not exists memos_position_idx on public.memos (position asc, created_at desc);
create index if not exists admin_sessions_expires_at_idx on public.admin_sessions (expires_at);
create index if not exists rate_limits_window_started_at_idx on public.rate_limits (window_started_at);

-- B-4. 기존 해시 이전, 검증, 공개 테이블에서 제거
do $$
declare
  legacy_total bigint := 0;
  migrated bigint := 0;
  missing_after bigint := 0;
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'memos' and column_name = 'password_hash'
  ) then
    execute 'select count(*) from public.memos where password_hash is not null' into legacy_total;

    -- 이미 이전된 행은 건드리지 않으므로 재실행해도 안전합니다.
    execute $q$
      insert into public.memo_credentials (memo_id, password_hash)
      select id, password_hash from public.memos where password_hash is not null
      on conflict (memo_id) do nothing
    $q$;

    execute $q$
      select count(*) from public.memos m
      where m.password_hash is not null
        and not exists (
          select 1 from public.memo_credentials c
          where c.memo_id = m.id and c.password_hash = m.password_hash)
    $q$ into missing_after;

    if missing_after <> 0 then
      raise exception '해시 이전 검증 실패: % 건이 누락/불일치합니다. 변경을 취소합니다.', missing_after;
    end if;

    select count(*) into migrated from public.memo_credentials;
    raise notice '기존 해시 % 건 확인, memo_credentials 총 % 건', legacy_total, migrated;

    -- 기존 제약 충돌 방지 후 공개 테이블에서 해시 제거
    execute 'alter table public.memos alter column password_hash drop not null';
    execute 'alter table public.memos drop column password_hash';
  end if;
end $$;

-- 암호 해시가 없는 메모(이전 불가)는 작성자 삭제가 불가능하므로 알립니다.
do $$
declare
  orphan_count bigint;
begin
  select count(*) into orphan_count
  from public.memos m
  where not exists (select 1 from public.memo_credentials c where c.memo_id = m.id);
  if orphan_count > 0 then
    raise notice '작성자 암호가 없는 메모 % 건: 관리자만 삭제할 수 있습니다.', orphan_count;
  end if;
end $$;

-- B-5. 함수 (SECURITY INVOKER)
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

drop trigger if exists memos_set_updated_at on public.memos;
create trigger memos_set_updated_at
before update on public.memos
for each row
execute function public.set_updated_at();

create or replace function public.create_memo_with_credentials(
  p_title text,
  p_content text,
  p_password_hash text,
  p_color text default '#fef3c7'
)
returns public.memos
language plpgsql
security invoker
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

-- B-6. RLS: 이 앱 테이블의 기존 정책을 모두 제거한 뒤 공개 조회 정책만 생성
alter table public.memos enable row level security;
alter table public.memo_credentials enable row level security;
alter table public.admin_sessions enable row level security;
alter table public.rate_limits enable row level security;

do $$
declare
  pol record;
begin
  for pol in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('memos', 'memo_credentials', 'admin_sessions', 'rate_limits')
  loop
    execute format('drop policy %I on %I.%I', pol.policyname, pol.schemaname, pol.tablename);
  end loop;
end $$;

create policy "Public memos are readable"
on public.memos
for select
to anon, authenticated
using (true);

-- B-7. GRANT: 이 앱 테이블/함수에만 적용 (public 스키마 전체 권한은 변경하지 않음)
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

commit;

------------------------------------------------------------------
-- [C. 사후 확인]  (읽기 전용)
------------------------------------------------------------------
-- select count(*) from public.memos;
-- select count(*) from public.memo_credentials;
-- select tablename, rowsecurity from pg_tables
--  where schemaname = 'public' and tablename in ('memos','memo_credentials','admin_sessions','rate_limits');
-- select table_name, grantee, privilege_type from information_schema.role_table_grants
--  where table_schema = 'public' and grantee in ('anon','authenticated')
--    and table_name in ('memos','memo_credentials','admin_sessions','rate_limits');
