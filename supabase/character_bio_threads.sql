-- STARLIGHT RP: player-owned character biography threads
-- Run this once in Supabase Dashboard > SQL Editor after deploying the site.
-- Re-running is safe: both functions are CREATE OR REPLACE and forum seeding is idempotent.

create or replace function public.site_create_character_bio_thread(p_thread jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_thread_id text;
  v_title text;
  v_body text;
  v_author_char_id text;
  v_char jsonb;
  v_order integer;
  v_payload jsonb;
  v_now_ms bigint;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;

  select * into v_profile
  from public.site_profiles
  where auth_user_id = (select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;

  if p_thread is null or jsonb_typeof(p_thread) <> 'object' then
    raise exception 'Biography thread payload is invalid';
  end if;

  v_thread_id := nullif(trim(p_thread ->> 'id'), '');
  v_title := trim(coalesce(p_thread ->> 'title', ''));
  v_body := coalesce(p_thread ->> 'plot', '');

  if v_thread_id is null then raise exception 'Thread ID is required'; end if;
  if length(v_title) < 3 or length(v_title) > 120 then
    raise exception 'Thread title must be 3 to 120 characters';
  end if;
  if length(btrim(regexp_replace(v_body, '<[^>]*>', ' ', 'g'))) < 80 then
    raise exception 'Biography must contain at least 80 characters';
  end if;

  if exists (select 1 from public.site_records where collection = 'threads' and record_id = v_thread_id) then
    raise exception 'Thread ID already exists';
  end if;

  -- A player may include their own approved character as the thread avatar; otherwise it is a user-authored thread.
  v_author_char_id := nullif(p_thread ->> 'authorCharId', '');
  if v_author_char_id is not null then
    select payload into v_char
    from public.site_records
    where collection = 'characters' and record_id = v_author_char_id;
    if v_char is null
      or v_char ->> 'ownerId' is distinct from v_profile.app_user_id
      or coalesce(v_char ->> 'status', '') <> 'approved' then
      v_author_char_id := null;
    end if;
  end if;

  -- Seed the dedicated forum records once. This lets the first player use the board
  -- even if the site owner has not opened the updated admin UI yet.
  if not exists (
    select 1 from public.site_records
    where collection = 'categories' and record_id = 'cat_character_bio'
  ) then
    select coalesce(max(coalesce((payload ->> 'order')::integer, 0)), 0) + 1
      into v_order
    from public.site_records where collection = 'categories';
    insert into public.site_records(collection, record_id, payload, updated_at, updated_by)
    values (
      'categories', 'cat_character_bio',
      jsonb_build_object('id','cat_character_bio','name','📚 ทำเนียบและประวัติตัวละคร','order',v_order),
      now(), auth.uid()
    );
  end if;

  if not exists (
    select 1 from public.site_records
    where collection = 'forums' and record_id = 'f_char_bio'
  ) then
    select coalesce(max(coalesce((payload ->> 'order')::integer, 0)), 0) + 1
      into v_order
    from public.site_records where collection = 'forums';
    insert into public.site_records(collection, record_id, payload, updated_at, updated_by)
    values (
      'forums', 'f_char_bio',
      jsonb_build_object(
        'id','f_char_bio',
        'catId','cat_character_bio',
        'name','คลังประวัติตัวละคร',
        'desc','สร้างกระทู้เล่าเรื่องราวตัวละครฉบับเต็ม แล้วนำลิงก์มาแนบตอนลงทะเบียน',
        'banner','',
        'order',v_order
      ),
      now(), auth.uid()
    );
  end if;

  v_now_ms := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  v_payload := jsonb_build_object(
    'id', v_thread_id,
    'authorId', v_profile.app_user_id,
    'authorCharId', v_author_char_id,
    'title', v_title,
    'type', 'bio',
    'forumId', 'f_char_bio',
    'characterBio', true,
    'exp', 0,
    'won', 0,
    'minStage', 0,
    'maxStage', 99,
    'agencyId', '',
    'train', '[]'::jsonb,
    'statGain', 0,
    'plot', v_body,
    'plotMode', 'rich',
    'rules', '',
    'rulesMode', 'rich',
    'css', '',
    'tpl', '',
    'deadline', '',
    'pinned', false,
    'status', 'open',
    'createdAt', coalesce(nullif(p_thread ->> 'createdAt', '')::numeric, v_now_ms)
  );

  insert into public.site_records(collection, record_id, payload, updated_at, updated_by)
  values ('threads', v_thread_id, v_payload, now(), auth.uid());

  return jsonb_build_object('ok', true, 'thread', v_payload);
end;
$$;

create or replace function public.site_update_character_bio_thread(p_thread jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_old jsonb;
  v_new jsonb;
  v_thread_id text;
  v_title text;
  v_body text;
  v_now_ms bigint;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;

  select * into v_profile
  from public.site_profiles
  where auth_user_id = (select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;

  if p_thread is null or jsonb_typeof(p_thread) <> 'object' then
    raise exception 'Biography thread payload is invalid';
  end if;

  v_thread_id := nullif(trim(p_thread ->> 'id'), '');
  v_title := trim(coalesce(p_thread ->> 'title', ''));
  v_body := coalesce(p_thread ->> 'plot', '');
  if v_thread_id is null then raise exception 'Thread ID is required'; end if;
  if length(v_title) < 3 or length(v_title) > 120 then
    raise exception 'Thread title must be 3 to 120 characters';
  end if;
  if length(btrim(regexp_replace(v_body, '<[^>]*>', ' ', 'g'))) < 80 then
    raise exception 'Biography must contain at least 80 characters';
  end if;

  select payload into v_old
  from public.site_records
  where collection = 'threads' and record_id = v_thread_id
  for update;
  if not found then raise exception 'Biography thread not found'; end if;
  if coalesce(v_old ->> 'characterBio', 'false') <> 'true'
    or coalesce(v_old ->> 'forumId', '') <> 'f_char_bio' then
    raise exception 'This is not a character biography thread';
  end if;
  if v_profile.role <> 'admin'
    and v_old ->> 'authorId' is distinct from v_profile.app_user_id then
    raise exception 'You may only edit your own biography thread';
  end if;

  -- Update only editable fields; owner, forum, rewards, status and timestamp of creation remain trusted.
  v_now_ms := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  v_new := v_old || jsonb_build_object(
    'title', v_title,
    'plot', v_body,
    'plotMode', 'rich',
    'updatedAt', v_now_ms
  );

  update public.site_records
  set payload = v_new, updated_at = now(), updated_by = auth.uid()
  where collection = 'threads' and record_id = v_thread_id;

  return jsonb_build_object('ok', true, 'thread', v_new);
end;
$$;

revoke all on function public.site_create_character_bio_thread(jsonb) from public, anon;
grant execute on function public.site_create_character_bio_thread(jsonb) to authenticated;
revoke all on function public.site_update_character_bio_thread(jsonb) from public, anon;
grant execute on function public.site_update_character_bio_thread(jsonb) to authenticated;

-- Refresh PostgREST's schema cache so the frontend can resolve these RPC signatures.
notify pgrst, 'reload schema';
