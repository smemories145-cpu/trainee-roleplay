-- STARLIGHT ACADEMY shared database foundation
-- Run this file once in Supabase Dashboard > SQL Editor as project owner.
-- This schema deliberately keeps passwords out of public site records.
-- Client writes must use the RPC functions below; direct table writes are revoked.

create table if not exists public.site_profiles (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  app_user_id text not null unique,
  username text not null unique,
  role text not null default 'player' check (role in ('admin','player')),
  permissions text[] not null default '{}',
  created_at timestamptz not null default now()
);

alter table public.site_profiles add column if not exists permissions text[] not null default '{}';

create table if not exists public.site_records (
  collection text not null check (collection in
    ('users','characters','posts','threads','forums','categories','settings','items','agencies','groups')),
  record_id text not null,
  payload jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  primary key (collection, record_id),
  constraint site_records_payload_object check (jsonb_typeof(payload) = 'object')
);

create index if not exists site_records_collection_idx on public.site_records(collection);
alter table public.site_profiles enable row level security;
alter table public.site_records enable row level security;

drop policy if exists "Profiles can read own identity" on public.site_profiles;
create policy "Profiles can read own identity"
  on public.site_profiles for select to authenticated
  using (auth_user_id = (select auth.uid()));

drop policy if exists "Public site content is readable" on public.site_records;
create policy "Public site content is readable"
  on public.site_records for select to anon, authenticated
  using (true);

revoke all on table public.site_profiles from anon, authenticated;
grant select on table public.site_profiles to authenticated;
revoke all on table public.site_records from anon, authenticated;
grant select on table public.site_records to anon, authenticated;

create or replace function public.site_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.site_profiles p
    where p.auth_user_id = (select auth.uid()) and p.role = 'admin'
  );
$$;

create or replace function public.site_handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_app_user_id text;
  v_username text;
begin
  v_app_user_id := nullif(new.raw_user_meta_data ->> 'app_user_id', '');
  v_username := nullif(trim(new.raw_user_meta_data ->> 'username'), '');
  if v_username is null then
    v_username := split_part(coalesce(new.email, 'player'), '@', 1);
  end if;
  if v_app_user_id is null then
    v_app_user_id := 'cloud_' || replace(new.id::text, '-', '');
  end if;

  insert into public.site_profiles(auth_user_id, app_user_id, username, role)
  values (new.id, v_app_user_id, v_username, 'player')
  on conflict (auth_user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists site_auth_user_created on auth.users;
create trigger site_auth_user_created
  after insert on auth.users
  for each row execute procedure public.site_handle_new_auth_user();

create or replace function public.site_record_write(
  p_collection text,
  p_record_id text,
  p_payload jsonb default null,
  p_delete boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_old jsonb;
  v_new jsonb;
  v_admin boolean;
  v_stat_key text;
  v_stat_value integer;
  v_stat_total integer;
  v_authorized boolean := false;
  v_manage_characters boolean := false;
  v_manage_character_review boolean := false;
  v_manage_economy boolean := false;
begin
  if auth.uid() is null then
    raise exception 'Sign in is required';
  end if;

  select * into v_profile
  from public.site_profiles
  where auth_user_id = (select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;
  v_admin := v_profile.role = 'admin';

  if p_collection not in ('users','characters','posts','threads','forums','categories','settings','items','agencies','groups') then
    raise exception 'Unsupported collection';
  end if;

  select payload into v_old
  from public.site_records
  where collection = p_collection and record_id = p_record_id;

  v_manage_characters := 'manage_characters' = any(coalesce(v_profile.permissions, '{}'::text[]));
  v_manage_character_review := 'manage_character_review' = any(coalesce(v_profile.permissions, '{}'::text[]));
  v_manage_economy := 'manage_economy' = any(coalesce(v_profile.permissions, '{}'::text[]));
  v_authorized := case p_collection
    when 'posts' then 'manage_posts' = any(coalesce(v_profile.permissions, '{}'::text[]))
    when 'threads' then 'manage_threads' = any(coalesce(v_profile.permissions, '{}'::text[]))
    when 'forums' then 'manage_forums' = any(coalesce(v_profile.permissions, '{}'::text[]))
    when 'categories' then 'manage_forums' = any(coalesce(v_profile.permissions, '{}'::text[]))
    when 'settings' then 'manage_settings' = any(coalesce(v_profile.permissions, '{}'::text[]))
    when 'items' then 'manage_shop' = any(coalesce(v_profile.permissions, '{}'::text[]))
    when 'agencies' then 'manage_agencies' = any(coalesce(v_profile.permissions, '{}'::text[]))
    when 'groups' then 'manage_groups' = any(coalesce(v_profile.permissions, '{}'::text[]))
    when 'characters' then false
    else false
  end;

  if p_delete then
    if not found then return jsonb_build_object('ok', true, 'deleted', false); end if;
    if not v_admin then
      if p_collection = 'posts' and 'manage_posts' = any(coalesce(v_profile.permissions, '{}'::text[])) then
        null;
      elsif p_collection = 'characters' and v_manage_characters then
        null;
      elsif p_collection = 'posts' then
        if v_old ->> 'userId' is distinct from v_profile.app_user_id then
          raise exception 'Cannot delete another user''s post';
        end if;
      elsif p_collection = 'characters' then
        if v_old ->> 'ownerId' is distinct from v_profile.app_user_id
          or v_old ->> 'status' = 'approved' then
          raise exception 'Only your own unapproved character may be deleted';
        end if;
      else
        raise exception 'Administrator permission required';
      end if;
    end if;
    delete from public.site_records where collection = p_collection and record_id = p_record_id;
    return jsonb_build_object('ok', true, 'deleted', true);
  end if;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'Payload must be a JSON object';
  end if;

  v_new := p_payload - 'pass';

  if coalesce(v_new ->> 'id', p_record_id) <> p_record_id then
    raise exception 'Record ID mismatch';
  end if;

  if not v_admin
    and p_collection = 'characters'
    and v_old is not null
    and v_new ->> 'ownerId' is distinct from v_profile.app_user_id then
    if (v_new - array['status','reason','won','inv','ledger','lastPractice','lastSalary']::text[])
       is distinct from
       (v_old - array['status','reason','won','inv','ledger','lastPractice','lastSalary']::text[])
       and not v_manage_characters then
      raise exception 'Character management permission required';
    end if;
    if ((v_new -> 'status') is distinct from (v_old -> 'status')
        or (v_new -> 'reason') is distinct from (v_old -> 'reason'))
       and not v_manage_character_review then
      raise exception 'Character review permission required';
    end if;
    if ((v_new -> 'won') is distinct from (v_old -> 'won')
        or (v_new -> 'inv') is distinct from (v_old -> 'inv')
        or (v_new -> 'ledger') is distinct from (v_old -> 'ledger')
        or (v_new -> 'lastPractice') is distinct from (v_old -> 'lastPractice')
        or (v_new -> 'lastSalary') is distinct from (v_old -> 'lastSalary'))
       and not v_manage_economy then
      raise exception 'Economy permission required';
    end if;
  elsif not v_admin and v_authorized then
    null;
  elsif not v_admin then
    if p_collection = 'users' then
      if v_new ->> 'id' is distinct from v_profile.app_user_id then
        raise exception 'Cannot modify another account';
      end if;
      v_new := jsonb_set(v_new, '{role}', to_jsonb(case when v_profile.role = 'admin' or cardinality(coalesce(v_profile.permissions, '{}'::text[])) > 0 then 'admin' else 'player' end), true);
      v_new := jsonb_set(v_new, '{permissions}', to_jsonb(coalesce(v_profile.permissions, '{}'::text[])), true);
      v_new := jsonb_set(v_new, '{username}', to_jsonb(v_profile.username), true);
    elsif p_collection = 'characters' then
      if v_new ->> 'ownerId' is distinct from v_profile.app_user_id then
        raise exception 'Characters can only be written by their owner';
      end if;
      if v_old is null then
        -- New player characters must use the permitted starter stat allocation.
        v_new := jsonb_set(v_new, '{status}', '"pending"'::jsonb, true);
        v_new := jsonb_set(v_new, '{stage}', '0'::jsonb, true);
        v_new := jsonb_set(v_new, '{exp}', '0'::jsonb, true);
        v_new := jsonb_set(v_new, '{won}', '10000'::jsonb, true);
        if jsonb_typeof(v_new -> 'stats') <> 'object' then
          raise exception 'Character stats allocation is missing';
        end if;
        v_stat_total := 0;
        foreach v_stat_key in array array['vocal','dance','rap','visual','acting','produce'] loop
          if coalesce(v_new -> 'stats' ->> v_stat_key,'') !~ '^[0-9]+$' then
            raise exception 'Character stat allocation is invalid';
          end if;
          v_stat_value := (v_new -> 'stats' ->> v_stat_key)::integer;
          if v_stat_value < 10 or v_stat_value > 30 then
            raise exception 'Character stat values must be between 10 and 30';
          end if;
          v_stat_total := v_stat_total + v_stat_value;
        end loop;
        if v_stat_total <> 90 then
          raise exception 'Character stat allocation must total 90 points';
        end if;
      else
        if v_old ->> 'ownerId' is distinct from v_profile.app_user_id then
          raise exception 'Cannot modify another user''s character';
        end if;
        if (v_new -> 'status') is distinct from (v_old -> 'status')
          or (v_new -> 'stage') is distinct from (v_old -> 'stage')
          or (v_new -> 'exp') is distinct from (v_old -> 'exp')
          or (v_new -> 'won') is distinct from (v_old -> 'won')
          or (v_new -> 'stats') is distinct from (v_old -> 'stats')
          or (v_new -> 'inv') is distinct from (v_old -> 'inv')
          or (v_new -> 'ledger') is distinct from (v_old -> 'ledger')
          or (v_new -> 'lastPractice') is distinct from (v_old -> 'lastPractice')
          or (v_new -> 'lastSalary') is distinct from (v_old -> 'lastSalary') then
          raise exception 'Progress, wallet, inventory and approval require a trusted action';
        end if;
      end if;
    elsif p_collection = 'posts' then
      if v_old is null then
        raise exception 'New posts must use site_create_post so rewards are validated on the server';
      end if;
      if v_new ->> 'userId' is distinct from v_profile.app_user_id
        or v_old ->> 'userId' is distinct from v_profile.app_user_id then
        raise exception 'Cannot modify another user''s post';
      end if;
      if (v_new -> 'threadId') is distinct from (v_old -> 'threadId')
        or (v_new -> 'userId') is distinct from (v_old -> 'userId')
        or (v_new -> 'charId') is distinct from (v_old -> 'charId')
        or (v_new -> 'gm') is distinct from (v_old -> 'gm')
        or (v_new -> 'gain') is distinct from (v_old -> 'gain')
        or (v_new -> 'wonGain') is distinct from (v_old -> 'wonGain')
        or (v_new -> 'train') is distinct from (v_old -> 'train') then
        raise exception 'Reward and authorship data cannot be changed';
      end if;
    else
      raise exception 'Administrator permission required for this collection';
    end if;
  end if;

  insert into public.site_records(collection, record_id, payload, updated_at, updated_by)
  values (p_collection, p_record_id, v_new, now(), auth.uid())
  on conflict (collection, record_id) do update
    set payload = excluded.payload, updated_at = excluded.updated_at, updated_by = excluded.updated_by;

  return jsonb_build_object('ok', true, 'collection', p_collection, 'record_id', p_record_id);
end;
$$;

create or replace function public.site_set_admin_permissions(
  p_app_user_id text,
  p_permissions text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller public.site_profiles%rowtype;
  v_target public.site_profiles%rowtype;
  v_permissions text[] := coalesce(p_permissions, '{}'::text[]);
  v_allowed text[] := array[
    'manage_character_review','manage_characters','manage_economy','manage_posts',
    'manage_threads','manage_forums','manage_shop','manage_agencies','manage_groups',
    'manage_members','manage_settings'
  ];
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;

  select * into v_caller from public.site_profiles
  where auth_user_id = (select auth.uid());
  if not found or v_caller.role <> 'admin' then
    raise exception 'Only the primary administrator can assign admin permissions';
  end if;
  if p_app_user_id is null or p_app_user_id = v_caller.app_user_id then
    raise exception 'Choose another account; your own permissions cannot be changed here';
  end if;
  if not (v_permissions <@ v_allowed) then
    raise exception 'One or more permission keys are invalid';
  end if;

  select * into v_target from public.site_profiles
  where app_user_id = p_app_user_id
  for update;
  if not found then raise exception 'Target account does not exist'; end if;

  if v_target.role = 'admin' then
    raise exception 'A full administrator account cannot be changed from the delegated-permissions screen';
  end if;

  update public.site_profiles
  set permissions = (select coalesce(array_agg(distinct p), '{}'::text[]) from unnest(v_permissions) p)
  where app_user_id = p_app_user_id;

  -- Update the visible site_records user in the same transaction as the trusted profile.
  -- If the public user row is missing, fail and roll back rather than saving partial permissions.
  update public.site_records
  set payload = jsonb_set(
        jsonb_set(payload, '{role}', to_jsonb(case when cardinality(v_permissions) > 0 then 'admin' else 'player' end), true),
        '{permissions}', to_jsonb(v_permissions), true
      ),
      updated_at = now(),
      updated_by = auth.uid()
  where collection = 'users' and record_id = p_app_user_id;

  if not found then
    raise exception 'User record is missing in site_records for app_user_id %', p_app_user_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'app_user_id', p_app_user_id,
    'permissions', to_jsonb(v_permissions),
    'role', case when cardinality(v_permissions) > 0 then 'admin' else 'player' end
  );
end;
$$;

revoke all on function public.site_set_admin_permissions(text, text[]) from public, anon;
grant execute on function public.site_set_admin_permissions(text, text[]) to authenticated;

create or replace function public.site_import_local_snapshot(p_snapshot jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_collection text;
  v_value jsonb;
  v_item jsonb;
  v_id text;
  v_count integer := 0;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_profile from public.site_profiles where auth_user_id = (select auth.uid());
  if not found or v_profile.role <> 'admin' then raise exception 'Administrator permission required'; end if;
  if p_snapshot is null or jsonb_typeof(p_snapshot) <> 'object' then
    raise exception 'Snapshot must be a JSON object';
  end if;
  if exists (select 1 from public.site_records) then
    raise exception 'Cloud data already exists; import is only allowed into an empty site';
  end if;

  for v_collection, v_value in select key, value from jsonb_each(p_snapshot)
  loop
    if v_collection not in ('users','characters','posts','threads','forums','categories','settings','items','agencies','groups') then
      continue;
    end if;
    if jsonb_typeof(v_value) = 'array' then
      for v_item in select value from jsonb_array_elements(v_value)
      loop
        v_id := nullif(v_item ->> 'id', '');
        if v_id is null then continue; end if;
        insert into public.site_records(collection, record_id, payload, updated_at, updated_by)
        values (v_collection, v_id, v_item - 'pass', now(), auth.uid())
        on conflict (collection, record_id) do nothing;
        v_count := v_count + 1;
      end loop;
    elsif v_collection = 'settings' and jsonb_typeof(v_value) = 'object' then
      insert into public.site_records(collection, record_id, payload, updated_at, updated_by)
      values (v_collection, '__singleton__', v_value, now(), auth.uid())
      on conflict (collection, record_id) do nothing;
      v_count := v_count + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'records_imported', v_count);
end;
$$;

create or replace function public.site_first_admin_needed()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    not exists (select 1 from public.site_profiles where role = 'admin')
    and not exists (select 1 from public.site_records);
$$;

revoke all on function public.site_first_admin_needed() from public, anon;
grant execute on function public.site_first_admin_needed() to authenticated;

revoke all on function public.site_is_admin() from public, anon;
grant execute on function public.site_is_admin() to authenticated;
revoke all on function public.site_record_write(text,text,jsonb,boolean) from public, anon;
grant execute on function public.site_record_write(text,text,jsonb,boolean) to authenticated;
revoke all on function public.site_import_local_snapshot(jsonb) from public, anon;
grant execute on function public.site_import_local_snapshot(jsonb) to authenticated;



create or replace function public.site_create_post(
  p_post jsonb,
  p_train text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_thread jsonb;
  v_char jsonb;
  v_post jsonb;
  v_id text;
  v_tid text;
  v_cid text;
  v_exp numeric;
  v_won numeric;
  v_stat_gain integer;
  v_old_stat integer := 0;
  v_new_stat integer := 0;
  v_cap integer;
  v_now_ms bigint;
  v_content_len integer;
  v_ledger jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_profile from public.site_profiles where auth_user_id = (select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;
  if p_post is null or jsonb_typeof(p_post) <> 'object' then raise exception 'Post payload is invalid'; end if;

  v_id := nullif(p_post ->> 'id','');
  v_tid := nullif(p_post ->> 'threadId','');
  v_cid := nullif(p_post ->> 'charId','');
  if v_id is null or v_tid is null or v_cid is null then raise exception 'Post is missing required fields'; end if;
  if p_post ->> 'userId' is distinct from v_profile.app_user_id
    or coalesce((p_post ->> 'gm')::boolean,false) then
    raise exception 'Players can only post as themselves';
  end if;

  select payload into v_thread from public.site_records where collection='threads' and record_id=v_tid for update;
  if v_thread is null then raise exception 'Thread not found'; end if;
  if coalesce(v_thread ->> 'status','open') = 'closed' then raise exception 'Thread is closed'; end if;
  if nullif(v_thread ->> 'deadline','') is not null
    and (v_thread ->> 'deadline')::timestamptz < now() then raise exception 'Thread deadline has passed'; end if;
  if coalesce(v_thread ->> 'type','main') = 'notice' then raise exception 'Players cannot post in announcement threads'; end if;

  select payload into v_char from public.site_records where collection='characters' and record_id=v_cid for update;
  if v_char is null then raise exception 'Character not found'; end if;
  if v_char ->> 'ownerId' is distinct from v_profile.app_user_id
    or coalesce(v_char ->> 'status','') <> 'approved' then raise exception 'Character is not approved for this account'; end if;
  if coalesce((v_char ->> 'stage')::integer,0) < coalesce((v_thread ->> 'minStage')::integer,0)
    or coalesce((v_char ->> 'stage')::integer,0) > coalesce((v_thread ->> 'maxStage')::integer,99) then
    raise exception 'Character stage does not match this thread';
  end if;
  if nullif(v_thread ->> 'agencyId','') is not null
    and coalesce(v_char ->> 'agencyId','') <> v_thread ->> 'agencyId' then
    raise exception 'Character does not belong to the required agency';
  end if;

  v_content_len := length(btrim(regexp_replace(coalesce(p_post ->> 'content',''), '<[^>]*>', ' ', 'g')));
  if v_content_len < 50 then raise exception 'Post must contain at least 50 characters'; end if;

  v_exp := greatest(0,coalesce((v_thread ->> 'exp')::numeric,0));
  v_won := greatest(0,coalesce((v_thread ->> 'won')::numeric,0));
  v_now_ms := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  v_char := jsonb_set(v_char,'{exp}',to_jsonb(coalesce((v_char ->> 'exp')::numeric,0)+v_exp),true);
  v_char := jsonb_set(v_char,'{won}',to_jsonb(coalesce((v_char ->> 'won')::numeric,0)+v_won),true);
  v_ledger := coalesce(v_char -> 'ledger','[]'::jsonb);
  v_ledger := jsonb_build_array(jsonb_build_object('at',v_now_ms,'amt',v_won,'note','โพสต์: '||coalesce(v_thread ->> 'title','กระทู้'))) || v_ledger;
  v_char := jsonb_set(v_char,'{ledger}',(select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) from jsonb_array_elements(v_ledger) with ordinality where ordinality<=30),true);

  v_stat_gain := greatest(0,coalesce((v_thread ->> 'statGain')::integer,0));
  if p_train is not null and coalesce(v_thread -> 'train','[]'::jsonb) ? p_train then
    v_cap := least(100,30+coalesce((v_char ->> 'stage')::integer,0)*10);
    v_old_stat := greatest(0,coalesce((v_char -> 'stats' ->> p_train)::integer,0));
    v_new_stat := greatest(v_old_stat,least(v_cap,v_old_stat+v_stat_gain));
    v_char := jsonb_set(v_char,ARRAY['stats',p_train],to_jsonb(v_new_stat),true);
  else
    p_train := null;
    v_stat_gain := 0;
  end if;

  v_post := p_post
    || jsonb_build_object('charId',v_cid,'gm',false,'train',p_train,
       'gain',v_new_stat-v_old_stat,'wonGain',v_won,'createdAt',coalesce((p_post ->> 'createdAt')::numeric,v_now_ms));
  insert into public.site_records(collection,record_id,payload,updated_at,updated_by)
  values ('posts',v_id,v_post,now(),auth.uid());
  update public.site_records set payload=v_char,updated_at=now(),updated_by=auth.uid()
    where collection='characters' and record_id=v_cid;

  return jsonb_build_object('ok',true,'post',v_post,'character',v_char,'gain',v_new_stat-v_old_stat);
end;
$$;

create or replace function public.site_practice(p_character_id text,p_stat text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_char jsonb;
  v_stats jsonb;
  v_now_ms bigint;
  v_last numeric;
  v_cap integer;
  v_old integer;
  v_gain integer;
  v_key text;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;
  if p_stat not in ('vocal','dance','rap','visual','acting','produce') then raise exception 'Unknown stat'; end if;
  select payload into v_char from public.site_records where collection='characters' and record_id=p_character_id;
  if v_char is null or v_char ->> 'ownerId' is distinct from v_profile.app_user_id
    or v_char ->> 'status' is distinct from 'approved' then raise exception 'Character is not available'; end if;
  v_now_ms := floor(extract(epoch from clock_timestamp())*1000)::bigint;
  v_last := coalesce((v_char ->> 'lastPractice')::numeric,0);
  if v_now_ms-v_last < 72000000 then raise exception 'Practice cooldown has not elapsed'; end if;
  v_cap := least(100,30+coalesce((v_char ->> 'stage')::integer,0)*10);
  v_old := greatest(0,coalesce((v_char -> 'stats' ->> p_stat)::integer,0));
  if v_old >= v_cap then raise exception 'This stat is at the current stage cap'; end if;
  v_gain := case when random()<0.3 then 2 else 1 end;
  v_gain := least(v_gain,v_cap-v_old);
  v_stats := jsonb_set(coalesce(v_char -> 'stats','{}'::jsonb),ARRAY[p_stat],to_jsonb(v_old+v_gain),true);
  v_char := jsonb_set(v_char,'{stats}',v_stats,true);
  v_char := jsonb_set(v_char,'{exp}',to_jsonb(coalesce((v_char ->> 'exp')::numeric,0)+3),true);
  v_char := jsonb_set(v_char,'{lastPractice}',to_jsonb(v_now_ms),true);
  update public.site_records set payload=v_char,updated_at=now(),updated_by=auth.uid()
    where collection='characters' and record_id=p_character_id;
  return jsonb_build_object('ok',true,'character',v_char,'stat',p_stat,'gain',v_gain,'exp_gain',3);
end;
$$;

create or replace function public.site_claim_salary(p_character_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_char jsonb;
  v_now_ms bigint;
  v_last numeric;
  v_amount integer;
  v_ledger jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;
  select payload into v_char from public.site_records where collection='characters' and record_id=p_character_id for update;
  if v_char is null or v_char ->> 'ownerId' is distinct from v_profile.app_user_id
    or v_char ->> 'status' is distinct from 'approved' then raise exception 'Character is not available'; end if;
  v_now_ms := floor(extract(epoch from clock_timestamp())*1000)::bigint;
  v_last := coalesce((v_char ->> 'lastSalary')::numeric,0);
  if v_now_ms-v_last < 72000000 then raise exception 'Salary cooldown has not elapsed'; end if;
  v_amount := 1000+500*coalesce((v_char ->> 'stage')::integer,0);
  v_char := jsonb_set(v_char,'{won}',to_jsonb(coalesce((v_char ->> 'won')::numeric,0)+v_amount),true);
  v_char := jsonb_set(v_char,'{lastSalary}',to_jsonb(v_now_ms),true);
  v_ledger := jsonb_build_array(jsonb_build_object('at',v_now_ms,'amt',v_amount,'note','เงินเดือนประจำวัน')) || coalesce(v_char -> 'ledger','[]'::jsonb);
  v_char := jsonb_set(v_char,'{ledger}',(select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) from jsonb_array_elements(v_ledger) with ordinality where ordinality<=30),true);
  update public.site_records set payload=v_char,updated_at=now(),updated_by=auth.uid()
    where collection='characters' and record_id=p_character_id;
  return jsonb_build_object('ok',true,'character',v_char,'amount',v_amount);
end;
$$;

-- Legacy cash-on-hand cross-character transfer has been removed. Transfers belong in the bank system.
drop function if exists public.site_transfer(text,text,integer,text);

create or replace function public.site_buy_item(p_character_id text,p_item_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
 v_profile public.site_profiles%rowtype;
 v_char jsonb;
 v_item jsonb;
 v_now_ms bigint;
 v_price integer;
 v_stock integer;
 v_inv jsonb;
 v_ledger jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found then raise exception 'Account profile has not been initialized'; end if;
 select payload into v_char from public.site_records where collection='characters' and record_id=p_character_id for update;
 select payload into v_item from public.site_records where collection='items' and record_id=p_item_id for update;
 if v_char is null or v_char ->> 'ownerId' is distinct from v_profile.app_user_id
   or v_char ->> 'status' is distinct from 'approved' then raise exception 'Character is not available'; end if;
 if v_item is null then raise exception 'Item not found'; end if;
 v_price := greatest(0,coalesce((v_item ->> 'price')::integer,0));
 v_stock := coalesce((v_item ->> 'stock')::integer,-1);
 if v_stock=0 then raise exception 'Item is out of stock'; end if;
 if coalesce((v_char ->> 'won')::numeric,0)<v_price then raise exception 'Insufficient funds'; end if;
 v_now_ms := floor(extract(epoch from clock_timestamp())*1000)::bigint;
 v_char := jsonb_set(v_char,'{won}',to_jsonb(coalesce((v_char ->> 'won')::numeric,0)-v_price),true);
 v_inv := coalesce(v_char -> 'inv','[]'::jsonb) || jsonb_build_array(jsonb_build_object('id',gen_random_uuid()::text,'iid',p_item_id,'at',v_now_ms));
 v_char := jsonb_set(v_char,'{inv}',v_inv,true);
 v_ledger := jsonb_build_array(jsonb_build_object('at',v_now_ms,'amt',-v_price,'note','ซื้อ: '||coalesce(v_item ->> 'name','สินค้า'))) || coalesce(v_char -> 'ledger','[]'::jsonb);
 v_char := jsonb_set(v_char,'{ledger}',(select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) from jsonb_array_elements(v_ledger) with ordinality where ordinality<=30),true);
 if v_stock>0 then
   v_item := jsonb_set(v_item,'{stock}',to_jsonb(v_stock-1),true);
   update public.site_records set payload=v_item,updated_at=now(),updated_by=auth.uid() where collection='items' and record_id=p_item_id;
 end if;
 update public.site_records set payload=v_char,updated_at=now(),updated_by=auth.uid() where collection='characters' and record_id=p_character_id;
 return jsonb_build_object('ok',true,'character',v_char,'item',v_item);
end;
$$;

revoke all on function public.site_create_post(jsonb,text) from public, anon;
grant execute on function public.site_create_post(jsonb,text) to authenticated;
revoke all on function public.site_practice(text,text) from public, anon;
grant execute on function public.site_practice(text,text) to authenticated;
revoke all on function public.site_claim_salary(text) from public, anon;
grant execute on function public.site_claim_salary(text) to authenticated;
revoke all on function public.site_buy_item(text,text) from public, anon;
grant execute on function public.site_buy_item(text,text) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname='supabase_realtime')
    and not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='site_records') then
    execute 'alter publication supabase_realtime add table public.site_records';
  end if;
end $$;

-- After the first account signs into STARLIGHT ACADEMY from the legacy device,
-- promote the existing site owner once in SQL Editor. Replace Admin if needed:
-- update public.site_profiles set role = 'admin' where lower(username) = lower('Admin');


-- Character biography thread migration is also available as supabase/character_bio_threads.sql
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
  v_plot_mode text;
  v_body_readable text;
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
  v_plot_mode := coalesce(nullif(trim(p_thread ->> 'plotMode'), ''), 'rich');
  if v_plot_mode not in ('rich','html') then
    raise exception 'Biography display mode must be rich or html';
  end if;
  v_body_readable := regexp_replace(v_body, '<style[^>]*>.*?</style>', ' ', 'gi');
  v_body_readable := regexp_replace(v_body_readable, '<script[^>]*>.*?</script>', ' ', 'gi');
  v_body_readable := regexp_replace(v_body_readable, '<head[^>]*>.*?</head>', ' ', 'gi');
  v_body_readable := regexp_replace(v_body_readable, '<[^>]*>', ' ', 'g');

  if v_thread_id is null then raise exception 'Thread ID is required'; end if;
  if length(v_title) < 3 or length(v_title) > 120 then
    raise exception 'Thread title must be 3 to 120 characters';
  end if;
  if length(btrim(regexp_replace(v_body_readable, '[[:space:]]+', ' ', 'g'))) < 80 then
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
    'plotMode', v_plot_mode,
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
  v_plot_mode text;
  v_body_readable text;
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
  v_plot_mode := coalesce(nullif(trim(p_thread ->> 'plotMode'), ''), 'rich');
  if v_plot_mode not in ('rich','html') then
    raise exception 'Biography display mode must be rich or html';
  end if;
  v_body_readable := regexp_replace(v_body, '<style[^>]*>.*?</style>', ' ', 'gi');
  v_body_readable := regexp_replace(v_body_readable, '<script[^>]*>.*?</script>', ' ', 'gi');
  v_body_readable := regexp_replace(v_body_readable, '<head[^>]*>.*?</head>', ' ', 'gi');
  v_body_readable := regexp_replace(v_body_readable, '<[^>]*>', ' ', 'g');
  if v_thread_id is null then raise exception 'Thread ID is required'; end if;
  if length(v_title) < 3 or length(v_title) > 120 then
    raise exception 'Thread title must be 3 to 120 characters';
  end if;
  if length(btrim(regexp_replace(v_body_readable, '[[:space:]]+', ' ', 'g'))) < 80 then
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
    'plotMode', v_plot_mode,
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


-- STARLIGHT RP user profile settings and private mailbox
-- Also available as supabase/user_mail_system.sql for upgrading an existing project.
-- STARLIGHT RP: user profile settings and private mailbox
-- Run this migration once in Supabase SQL Editor for an existing project.
-- The mailbox table is intentionally private; reads/writes go through SECURITY DEFINER RPCs only.

create or replace function public.site_profile_update(
  p_username text,
  p_avatar text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_username text := trim(coalesce(p_username, ''));
  v_avatar text := trim(coalesce(p_avatar, ''));
  v_email text;
begin
  if auth.uid() is null then
    raise exception 'Sign in is required';
  end if;

  select * into v_profile
  from public.site_profiles
  where auth_user_id = (select auth.uid())
  for update;

  if not found then
    raise exception 'Account profile has not been initialized';
  end if;

  if v_username !~ '^[A-Za-z0-9_]{3,20}$' then
    raise exception 'Username must be 3-20 characters using letters, numbers, or underscores';
  end if;

  if v_avatar <> '' and v_avatar !~* '^https?://' then
    raise exception 'Avatar must be an http or https URL';
  end if;

  if exists (
    select 1 from public.site_profiles p
    where lower(p.username) = lower(v_username)
      and p.auth_user_id <> (select auth.uid())
  ) then
    raise exception 'Username is already taken';
  end if;

  v_email := lower(v_username) || '@starlight.invalid';

  if exists (
    select 1 from auth.users a
    where lower(a.email) = v_email and a.id <> (select auth.uid())
  ) then
    raise exception 'Username is already in use by an authentication account';
  end if;

  update public.site_profiles
  set username = v_username
  where auth_user_id = (select auth.uid());

  -- The app uses username@starlight.invalid as the Supabase Auth login identifier.
  -- Keep that identifier aligned with the chosen username so subsequent logins work.
  update auth.users
  set email = v_email,
      raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb)
        || jsonb_build_object('username', v_username)
  where id = (select auth.uid());

  update public.site_records
  set payload = jsonb_set(
                  jsonb_set(payload, '{username}', to_jsonb(v_username), true),
                  '{avatar}', to_jsonb(v_avatar), true
                ),
      updated_at = now(),
      updated_by = (select auth.uid())
  where collection = 'users'
    and record_id = v_profile.app_user_id;

  return jsonb_build_object(
    'ok', true,
    'app_user_id', v_profile.app_user_id,
    'username', v_username,
    'avatar', v_avatar,
    'role', v_profile.role
  );
end;
$$;

revoke all on function public.site_profile_update(text, text) from public, anon;
grant execute on function public.site_profile_update(text, text) to authenticated;


create table if not exists public.site_mail (
  id text primary key,
  sender_app_user_id text not null references public.site_profiles(app_user_id) on delete cascade,
  recipient_app_user_id text not null references public.site_profiles(app_user_id) on delete cascade,
  subject text not null check (char_length(subject) between 1 and 120),
  body text not null check (char_length(body) between 1 and 12000),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  sender_deleted boolean not null default false,
  recipient_deleted boolean not null default false,
  constraint site_mail_not_self check (sender_app_user_id <> recipient_app_user_id)
);

create index if not exists site_mail_inbox_idx
  on public.site_mail(recipient_app_user_id, created_at desc)
  where recipient_deleted = false;

create index if not exists site_mail_sent_idx
  on public.site_mail(sender_app_user_id, created_at desc)
  where sender_deleted = false;

alter table public.site_mail enable row level security;
revoke all on table public.site_mail from public, anon, authenticated;


create or replace function public.site_mail_send(p_mail jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_id text := trim(coalesce(p_mail ->> 'id', ''));
  v_recipient_id text := trim(coalesce(p_mail ->> 'recipientId', ''));
  v_subject text := trim(coalesce(p_mail ->> 'subject', ''));
  v_body text := trim(coalesce(p_mail ->> 'body', ''));
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;

  select * into v_profile from public.site_profiles
  where auth_user_id = (select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;

  if v_id = '' or char_length(v_id) > 80 then raise exception 'Message ID is invalid'; end if;
  if v_recipient_id = '' then raise exception 'Recipient is required'; end if;
  if char_length(v_subject) < 1 or char_length(v_subject) > 120 then
    raise exception 'Subject must be 1-120 characters';
  end if;
  if char_length(v_body) < 1 or char_length(v_body) > 12000 then
    raise exception 'Message must be 1-12000 characters';
  end if;
  if v_recipient_id = v_profile.app_user_id then
    raise exception 'Cannot send a message to yourself';
  end if;
  if not exists (select 1 from public.site_profiles where app_user_id = v_recipient_id) then
    raise exception 'Recipient account does not exist';
  end if;

  insert into public.site_mail(id, sender_app_user_id, recipient_app_user_id, subject, body)
  values (v_id, v_profile.app_user_id, v_recipient_id, v_subject, v_body);

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.site_mail_list(p_folder text default 'inbox')
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_messages jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  if p_folder not in ('inbox', 'sent') then raise exception 'Folder must be inbox or sent'; end if;

  select * into v_profile from public.site_profiles
  where auth_user_id = (select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;

  select coalesce(jsonb_agg(q.message order by q.created_at desc), '[]'::jsonb)
  into v_messages
  from (
    select
      m.created_at,
      jsonb_build_object(
        'id', m.id,
        'senderId', m.sender_app_user_id,
        'senderUsername', s.username,
        'recipientId', m.recipient_app_user_id,
        'recipientUsername', r.username,
        'subject', m.subject,
        'body', m.body,
        'createdAt', floor(extract(epoch from m.created_at) * 1000)::bigint,
        'readAt', case when m.read_at is null then null
          else floor(extract(epoch from m.read_at) * 1000)::bigint end
      ) as message
    from public.site_mail m
    join public.site_profiles s on s.app_user_id = m.sender_app_user_id
    join public.site_profiles r on r.app_user_id = m.recipient_app_user_id
    where (
      p_folder = 'inbox'
      and m.recipient_app_user_id = v_profile.app_user_id
      and not m.recipient_deleted
    ) or (
      p_folder = 'sent'
      and m.sender_app_user_id = v_profile.app_user_id
      and not m.sender_deleted
    )
  ) q;

  return v_messages;
end;
$$;

create or replace function public.site_mail_mark_read(p_mail_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_count integer;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_profile from public.site_profiles
  where auth_user_id = (select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;

  update public.site_mail
  set read_at = coalesce(read_at, now())
  where id = p_mail_id
    and recipient_app_user_id = v_profile.app_user_id
    and not recipient_deleted;
  get diagnostics v_count = row_count;
  if v_count = 0 then raise exception 'Message not found in your inbox'; end if;

  return jsonb_build_object('ok', true, 'id', p_mail_id);
end;
$$;

create or replace function public.site_mail_delete(p_mail_id text, p_folder text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_count integer;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  if p_folder not in ('inbox', 'sent') then raise exception 'Folder must be inbox or sent'; end if;

  select * into v_profile from public.site_profiles
  where auth_user_id = (select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;

  if p_folder = 'inbox' then
    update public.site_mail set recipient_deleted = true
    where id = p_mail_id and recipient_app_user_id = v_profile.app_user_id
      and not recipient_deleted;
  else
    update public.site_mail set sender_deleted = true
    where id = p_mail_id and sender_app_user_id = v_profile.app_user_id
      and not sender_deleted;
  end if;

  get diagnostics v_count = row_count;
  if v_count = 0 then raise exception 'Message not found or not owned by this account'; end if;

  return jsonb_build_object('ok', true, 'id', p_mail_id, 'folder', p_folder);
end;
$$;

revoke all on function public.site_mail_send(jsonb) from public, anon;
grant execute on function public.site_mail_send(jsonb) to authenticated;

revoke all on function public.site_mail_list(text) from public, anon;
grant execute on function public.site_mail_list(text) to authenticated;

revoke all on function public.site_mail_mark_read(text) from public, anon;
grant execute on function public.site_mail_mark_read(text) to authenticated;

revoke all on function public.site_mail_delete(text, text) from public, anon;
grant execute on function public.site_mail_delete(text, text) to authenticated;

-- Refresh PostgREST after all RPC functions and grants are installed.
notify pgrst, 'reload schema';


-- Online presence and daily active member tracking
-- STARLIGHT RP: recent activity / online today system
-- The presence table has RLS enabled and no direct client table access. Clients use the RPCs only.

create table if not exists public.site_presence (
  session_id text primary key check (session_id ~ '^[A-Za-z0-9-]{16,80}$'),
  current_app_user_id text,
  is_member boolean not null default false,
  is_hidden boolean not null default false,
  last_seen timestamptz not null default now(),
  member_app_user_id text,
  member_username text,
  member_online_group text not null default 'human',
  member_display_color text not null default '#d6d6dc',
  member_is_hidden boolean not null default false,
  member_last_seen timestamptz
);

alter table public.site_presence alter column member_online_group set default 'applicant';

create index if not exists site_presence_last_seen_idx
  on public.site_presence(last_seen desc);
create index if not exists site_presence_member_last_seen_idx
  on public.site_presence(member_last_seen desc);

-- Move records from the earlier example roleplay categories into the lowest rank
-- until the member's browser sends a fresh heartbeat with their actual character stage.
update public.site_presence
set member_online_group = 'applicant'
where member_online_group not in (
  'applicant','trainee_d','trainee_c','trainee_b',
  'trainee_a','pre_debut','rookie_artist','superstar'
);

alter table public.site_presence enable row level security;
revoke all on table public.site_presence from anon, authenticated;

create or replace function public.site_presence_heartbeat(
  p_session_id text,
  p_hidden boolean default false,
  p_online_group text default 'applicant',
  p_display_color text default '#d6d6dc'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_group text;
  v_color text;
begin
  if p_session_id is null or p_session_id !~ '^[A-Za-z0-9-]{16,80}$' then
    raise exception 'Invalid presence session id';
  end if;

  if auth.uid() is not null then
    select * into v_profile
    from public.site_profiles
    where auth_user_id = (select auth.uid());

    if found then
      -- The website derives the category from the selected character's STARLIGHT stage.
      -- Keep the group key aligned with the eight ranks; do not use example roleplay species/groups.
      v_group := coalesce(nullif(p_online_group, ''), 'applicant');
      if v_group not in (
        'applicant','trainee_d','trainee_c','trainee_b',
        'trainee_a','pre_debut','rookie_artist','superstar'
      ) then
        v_group := 'applicant';
      end if;

      v_color := case
        when p_display_color ~ '^#[0-9A-Fa-f]{6}$' then p_display_color
        else '#d6d6dc'
      end;

      insert into public.site_presence (
        session_id, current_app_user_id, is_member, is_hidden, last_seen,
        member_app_user_id, member_username, member_online_group,
        member_display_color, member_is_hidden, member_last_seen
      ) values (
        p_session_id, v_profile.app_user_id, true, coalesce(p_hidden, false), now(),
        v_profile.app_user_id, v_profile.username, v_group,
        v_color, coalesce(p_hidden, false), now()
      )
      on conflict (session_id) do update set
        current_app_user_id = excluded.current_app_user_id,
        is_member = true,
        is_hidden = excluded.is_hidden,
        last_seen = now(),
        member_app_user_id = excluded.member_app_user_id,
        member_username = excluded.member_username,
        member_online_group = excluded.member_online_group,
        member_display_color = excluded.member_display_color,
        member_is_hidden = excluded.member_is_hidden,
        member_last_seen = now();

      return jsonb_build_object('ok', true, 'is_member', true);
    end if;
  end if;

  -- Anonymous visitor heartbeat: retain this browser's last member visit for today's list,
  -- but do not expose a signed-out user as currently online.
  insert into public.site_presence (
    session_id, current_app_user_id, is_member, is_hidden, last_seen
  ) values (
    p_session_id, null, false, false, now()
  )
  on conflict (session_id) do update set
    current_app_user_id = null,
    is_member = false,
    is_hidden = false,
    last_seen = now();

  return jsonb_build_object('ok', true, 'is_member', false);
end;
$$;

create or replace function public.site_presence_summary()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_now timestamptz := now();
  v_today_start timestamptz := (date_trunc('day', now() at time zone 'Asia/Bangkok') at time zone 'Asia/Bangkok');
  v_total_members integer := 0;
  v_members_online integer := 0;
  v_hidden_members integer := 0;
  v_visitors integer := 0;
  v_online_today jsonb := '[]'::jsonb;
begin
  select count(*)::integer into v_total_members
  from public.site_profiles;

  with latest_active as (
    select distinct on (current_app_user_id)
      current_app_user_id, is_hidden
    from public.site_presence
    where is_member = true
      and current_app_user_id is not null
      and last_seen >= v_now - interval '5 minutes'
    order by current_app_user_id, last_seen desc
  )
  select
    count(*) filter (where is_hidden = false)::integer,
    count(*) filter (where is_hidden = true)::integer
  into v_members_online, v_hidden_members
  from latest_active;

  select count(*)::integer into v_visitors
  from public.site_presence
  where is_member = false
    and last_seen >= v_now - interval '5 minutes';

  with latest_daily as (
    select distinct on (member_app_user_id)
      member_app_user_id, member_username, member_online_group,
      member_display_color, member_is_hidden, member_last_seen
    from public.site_presence
    where member_app_user_id is not null
      and member_last_seen >= v_today_start
    order by member_app_user_id, member_last_seen desc
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'app_user_id', member_app_user_id,
        'username', member_username,
        'online_group', member_online_group,
        'display_color', member_display_color,
        'last_seen', member_last_seen
      )
      order by member_online_group, lower(member_username)
    ),
    '[]'::jsonb
  )
  into v_online_today
  from latest_daily
  where member_is_hidden = false;

  return jsonb_build_object(
    'ok', true,
    'window_minutes', 5,
    'total_members', v_total_members,
    'members_online', coalesce(v_members_online, 0),
    'hidden_members', coalesce(v_hidden_members, 0),
    'visitors_online', coalesce(v_visitors, 0),
    'online_today', v_online_today,
    'generated_at', v_now
  );
end;
$$;

revoke all on function public.site_presence_heartbeat(text, boolean, text, text) from public;
revoke all on function public.site_presence_summary() from public;
grant execute on function public.site_presence_heartbeat(text, boolean, text, text) to anon, authenticated;
grant execute on function public.site_presence_summary() to anon, authenticated;

notify pgrst, 'reload schema';


-- STARLIGHT RP: phone banking core
-- Run in Supabase SQL Editor for an existing installation.
-- Cash remains in characters.won. Only these RPCs may move cash to/from bank balances.

begin;

create sequence if not exists public.site_bank_account_no_seq
  start with 1000000000 increment by 1 minvalue 1000000000 maxvalue 9999999999 no cycle;

create table if not exists public.site_bank_accounts (
  id bigint generated always as identity primary key,
  character_id text not null unique,
  owner_app_user_id text not null,
  account_number text not null unique,
  balance bigint not null default 0 check (balance >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.site_bank_settings (
  singleton_id boolean primary key default true check (singleton_id = true),
  deposit_fee_bps integer not null default 0 check (deposit_fee_bps between 0 and 10000),
  withdrawal_fee_bps integer not null default 0 check (withdrawal_fee_bps between 0 and 10000),
  transfer_fee_bps integer not null default 0 check (transfer_fee_bps between 0 and 10000),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

insert into public.site_bank_settings(singleton_id)
values (true)
on conflict (singleton_id) do nothing;

create table if not exists public.site_bank_transactions (
  id bigint generated always as identity primary key,
  request_id text not null unique,
  kind text not null check (kind in ('deposit','withdraw','transfer')),
  actor_app_user_id text not null,
  sender_character_id text,
  recipient_character_id text,
  source_account_id bigint references public.site_bank_accounts(id) on delete restrict,
  destination_account_id bigint references public.site_bank_accounts(id) on delete restrict,
  amount bigint not null check (amount > 0),
  fee bigint not null default 0 check (fee >= 0),
  note text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists site_bank_transactions_sender_idx
  on public.site_bank_transactions(sender_character_id, created_at desc);
create index if not exists site_bank_transactions_recipient_idx
  on public.site_bank_transactions(recipient_character_id, created_at desc);
create index if not exists site_bank_transactions_created_idx
  on public.site_bank_transactions(created_at desc);

create table if not exists public.site_bank_settings_audit (
  id bigint generated always as identity primary key,
  changed_by_app_user_id text not null,
  deposit_fee_bps integer not null,
  withdrawal_fee_bps integer not null,
  transfer_fee_bps integer not null,
  changed_at timestamptz not null default now()
);

alter table public.site_bank_accounts enable row level security;
alter table public.site_bank_settings enable row level security;
alter table public.site_bank_transactions enable row level security;
alter table public.site_bank_settings_audit enable row level security;
revoke all on public.site_bank_accounts from anon, authenticated;
revoke all on public.site_bank_settings from anon, authenticated;
revoke all on public.site_bank_transactions from anon, authenticated;
revoke all on public.site_bank_settings_audit from anon, authenticated;

create or replace function public.site_bank_get_account(p_character_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_char jsonb;
  v_account public.site_bank_accounts%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_profile from public.site_profiles where auth_user_id = (select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;

  select payload into v_char
  from public.site_records
  where collection='characters' and record_id=p_character_id;

  if v_char is null
     or v_char ->> 'ownerId' is distinct from v_profile.app_user_id
     or v_char ->> 'status' is distinct from 'approved' then
    raise exception 'Character is not available for banking';
  end if;

  select * into v_account
  from public.site_bank_accounts
  where character_id=p_character_id and owner_app_user_id=v_profile.app_user_id;

  if not found then return null; end if;

  return jsonb_build_object(
    'id', v_account.id,
    'character_id', v_account.character_id,
    'account_number', v_account.account_number,
    'balance', v_account.balance,
    'cash_balance', greatest(0,coalesce((v_char ->> 'won')::bigint,0)),
    'display_name', coalesce(nullif(v_char ->> 'stageName',''),nullif(v_char ->> 'name',''),p_character_id),
    'created_at', v_account.created_at
  );
end;
$$;

create or replace function public.site_bank_open_account(p_character_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_char jsonb;
  v_account public.site_bank_accounts%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_profile from public.site_profiles where auth_user_id = (select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;

  select payload into v_char
  from public.site_records
  where collection='characters' and record_id=p_character_id
  for update;

  if v_char is null
     or v_char ->> 'ownerId' is distinct from v_profile.app_user_id
     or v_char ->> 'status' is distinct from 'approved' then
    raise exception 'Character is not available for banking';
  end if;

  insert into public.site_bank_accounts(character_id,owner_app_user_id,account_number,balance)
  values (p_character_id,v_profile.app_user_id,nextval('public.site_bank_account_no_seq')::text,0)
  on conflict (character_id) do nothing;

  select * into v_account
  from public.site_bank_accounts
  where character_id=p_character_id and owner_app_user_id=v_profile.app_user_id;

  if not found then raise exception 'Bank account belongs to another account owner'; end if;

  return jsonb_build_object(
    'ok',true,
    'id',v_account.id,
    'character_id',v_account.character_id,
    'account_number',v_account.account_number,
    'balance',v_account.balance,
    'cash_balance',greatest(0,coalesce((v_char ->> 'won')::bigint,0)),
    'display_name',coalesce(nullif(v_char ->> 'stageName',''),nullif(v_char ->> 'name',''),p_character_id),
    'created_at',v_account.created_at
  );
end;
$$;

create or replace function public.site_bank_find_recipient(p_character_id text,p_query text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_sender jsonb;
  v_query text := trim(coalesce(p_query,''));
  v_results jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;
  select payload into v_sender from public.site_records
   where collection='characters' and record_id=p_character_id;
  if v_sender is null or v_sender ->> 'ownerId' is distinct from v_profile.app_user_id
     or v_sender ->> 'status' is distinct from 'approved' then
    raise exception 'Character is not available for banking';
  end if;
  if length(v_query)<2 then raise exception 'Enter at least 2 characters or a full account number'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'character_id',ba.character_id,
    'account_number',ba.account_number,
    'display_name',coalesce(nullif(cr.payload ->> 'stageName',''),nullif(cr.payload ->> 'name',''),ba.character_id)
  ) order by coalesce(nullif(cr.payload ->> 'stageName',''),nullif(cr.payload ->> 'name',''),ba.character_id)), '[]'::jsonb)
  into v_results
  from public.site_bank_accounts ba
  join public.site_records cr
    on cr.collection='characters' and cr.record_id=ba.character_id
  where ba.character_id<>p_character_id
    and cr.payload ->> 'status'='approved'
    and (
      ba.account_number=v_query
      or (
        length(v_query)>=2
        and coalesce(nullif(cr.payload ->> 'stageName',''),nullif(cr.payload ->> 'name',''),ba.character_id)
          ilike '%' || replace(replace(replace(v_query,'\','\\'),'%','\%'),'_','\_') || '%' escape '\'
      )
    )
  limit 10;

  return v_results;
end;
$$;

create or replace function public.site_bank_my_transactions(p_character_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_char jsonb;
  v_results jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;
  select payload into v_char from public.site_records where collection='characters' and record_id=p_character_id;
  if v_char is null or v_char ->> 'ownerId' is distinct from v_profile.app_user_id
     or v_char ->> 'status' is distinct from 'approved' then
    raise exception 'Character is not available for banking';
  end if;

  select coalesce(jsonb_agg(row_data order by created_at desc), '[]'::jsonb)
  into v_results
  from (
    select t.created_at,
      jsonb_build_object(
        'id',t.id,'kind',t.kind,'amount',t.amount,'fee',t.fee,'note',t.note,'created_at',t.created_at,
        'sender_character_id',t.sender_character_id,'recipient_character_id',t.recipient_character_id,
        'sender_name',coalesce(nullif(sc.payload ->> 'stageName',''),nullif(sc.payload ->> 'name',''),t.sender_character_id,''),
        'recipient_name',coalesce(nullif(rc.payload ->> 'stageName',''),nullif(rc.payload ->> 'name',''),t.recipient_character_id,''),
        'source_account_number',sa.account_number,'destination_account_number',da.account_number
      ) as row_data
    from public.site_bank_transactions t
    left join public.site_records sc on sc.collection='characters' and sc.record_id=t.sender_character_id
    left join public.site_records rc on rc.collection='characters' and rc.record_id=t.recipient_character_id
    left join public.site_bank_accounts sa on sa.id=t.source_account_id
    left join public.site_bank_accounts da on da.id=t.destination_account_id
    where t.sender_character_id=p_character_id or t.recipient_character_id=p_character_id
    order by t.created_at desc
    limit 50
  ) q;

  return v_results;
end;
$$;

create or replace function public.site_bank_deposit(p_character_id text,p_amount bigint,p_request_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_char jsonb;
  v_account public.site_bank_accounts%rowtype;
  v_tx public.site_bank_transactions%rowtype;
  v_cash bigint;
  v_fee_bps integer;
  v_fee bigint;
  v_total bigint;
  v_now_ms bigint;
  v_entry jsonb;
  v_ledger jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  if p_amount is null or p_amount<1 or p_amount>9000000000000000 then raise exception 'Invalid deposit amount'; end if;
  if coalesce(length(trim(p_request_id)),0)<8 or length(p_request_id)>100 then raise exception 'Invalid request identifier'; end if;
  select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;

  select * into v_tx from public.site_bank_transactions where request_id=p_request_id;
  if found then
    if v_tx.actor_app_user_id<>v_profile.app_user_id or v_tx.kind<>'deposit' or v_tx.recipient_character_id<>p_character_id then
      raise exception 'Request identifier has already been used';
    end if;
    return jsonb_build_object('ok',true,'duplicate',true,'transaction_id',v_tx.id);
  end if;

  select payload into v_char from public.site_records
   where collection='characters' and record_id=p_character_id for update;
  if v_char is null or v_char ->> 'ownerId' is distinct from v_profile.app_user_id
     or v_char ->> 'status' is distinct from 'approved' then
    raise exception 'Character is not available for banking';
  end if;
  select * into v_account from public.site_bank_accounts
   where character_id=p_character_id and owner_app_user_id=v_profile.app_user_id for update;
  if not found then raise exception 'Open a bank account first'; end if;

  select deposit_fee_bps into v_fee_bps from public.site_bank_settings where singleton_id=true;
  v_fee:=ceil(p_amount::numeric*coalesce(v_fee_bps,0)/10000.0)::bigint;
  v_total:=p_amount+v_fee;
  v_cash:=greatest(0,coalesce((v_char ->> 'won')::bigint,0));
  if v_cash<v_total then raise exception 'Insufficient cash balance including fee'; end if;

  v_now_ms:=floor(extract(epoch from clock_timestamp())*1000)::bigint;
  v_entry:=jsonb_build_object('at',v_now_ms,'amt',-v_total,'note','ฝากธนาคาร '||v_account.account_number||case when v_fee>0 then ' (ค่าธรรมเนียม '||v_fee||' วอน)' else '' end);
  select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) into v_ledger
  from (
    select value,ordinality from jsonb_array_elements(v_entry||coalesce(v_char->'ledger','[]'::jsonb)) with ordinality
    where ordinality<=30
  ) ledger_rows;
  v_char:=jsonb_set(v_char,'{won}',to_jsonb(v_cash-v_total),true);
  v_char:=jsonb_set(v_char,'{ledger}',v_ledger,true);
  update public.site_records set payload=v_char,updated_at=now(),updated_by=auth.uid()
   where collection='characters' and record_id=p_character_id;

  update public.site_bank_accounts set balance=balance+p_amount where id=v_account.id;
  insert into public.site_bank_transactions(request_id,kind,actor_app_user_id,recipient_character_id,destination_account_id,amount,fee,note)
  values(p_request_id,'deposit',v_profile.app_user_id,p_character_id,v_account.id,p_amount,v_fee,'ฝากเงินสดเข้าบัญชี');

  return jsonb_build_object('ok',true,'amount',p_amount,'fee',v_fee);
end;
$$;

create or replace function public.site_bank_withdraw(p_character_id text,p_amount bigint,p_request_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_char jsonb;
  v_account public.site_bank_accounts%rowtype;
  v_tx public.site_bank_transactions%rowtype;
  v_cash bigint;
  v_fee_bps integer;
  v_fee bigint;
  v_total bigint;
  v_now_ms bigint;
  v_entry jsonb;
  v_ledger jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  if p_amount is null or p_amount<1 or p_amount>9000000000000000 then raise exception 'Invalid withdrawal amount'; end if;
  if coalesce(length(trim(p_request_id)),0)<8 or length(p_request_id)>100 then raise exception 'Invalid request identifier'; end if;
  select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;

  select * into v_tx from public.site_bank_transactions where request_id=p_request_id;
  if found then
    if v_tx.actor_app_user_id<>v_profile.app_user_id or v_tx.kind<>'withdraw' or v_tx.sender_character_id<>p_character_id then
      raise exception 'Request identifier has already been used';
    end if;
    return jsonb_build_object('ok',true,'duplicate',true,'transaction_id',v_tx.id);
  end if;

  select payload into v_char from public.site_records
   where collection='characters' and record_id=p_character_id for update;
  if v_char is null or v_char ->> 'ownerId' is distinct from v_profile.app_user_id
     or v_char ->> 'status' is distinct from 'approved' then
    raise exception 'Character is not available for banking';
  end if;
  select * into v_account from public.site_bank_accounts
   where character_id=p_character_id and owner_app_user_id=v_profile.app_user_id for update;
  if not found then raise exception 'Open a bank account first'; end if;

  select withdrawal_fee_bps into v_fee_bps from public.site_bank_settings where singleton_id=true;
  v_fee:=ceil(p_amount::numeric*coalesce(v_fee_bps,0)/10000.0)::bigint;
  v_total:=p_amount+v_fee;
  if v_account.balance<v_total then raise exception 'Insufficient bank balance including fee'; end if;

  v_cash:=greatest(0,coalesce((v_char ->> 'won')::bigint,0))+p_amount;
  v_now_ms:=floor(extract(epoch from clock_timestamp())*1000)::bigint;
  v_entry:=jsonb_build_object('at',v_now_ms,'amt',p_amount,'note','ถอนจากธนาคาร '||v_account.account_number||case when v_fee>0 then ' (ค่าธรรมเนียม '||v_fee||' วอน)' else '' end);
  select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) into v_ledger
  from (
    select value,ordinality from jsonb_array_elements(v_entry||coalesce(v_char->'ledger','[]'::jsonb)) with ordinality
    where ordinality<=30
  ) ledger_rows;
  v_char:=jsonb_set(v_char,'{won}',to_jsonb(v_cash),true);
  v_char:=jsonb_set(v_char,'{ledger}',v_ledger,true);
  update public.site_records set payload=v_char,updated_at=now(),updated_by=auth.uid()
   where collection='characters' and record_id=p_character_id;

  update public.site_bank_accounts set balance=balance-v_total where id=v_account.id;
  insert into public.site_bank_transactions(request_id,kind,actor_app_user_id,sender_character_id,source_account_id,amount,fee,note)
  values(p_request_id,'withdraw',v_profile.app_user_id,p_character_id,v_account.id,p_amount,v_fee,'ถอนเงินเข้ากระเป๋าเงินสด');

  return jsonb_build_object('ok',true,'amount',p_amount,'fee',v_fee);
end;
$$;

create or replace function public.site_bank_transfer(
  p_character_id text,p_recipient_character_id text,p_amount bigint,p_note text,p_request_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_sender_char jsonb;
  v_recipient_char jsonb;
  v_sender public.site_bank_accounts%rowtype;
  v_recipient public.site_bank_accounts%rowtype;
  v_tx public.site_bank_transactions%rowtype;
  v_fee_bps integer;
  v_fee bigint;
  v_total bigint;
  v_note text:=left(trim(coalesce(p_note,'')),160);
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  if p_amount is null or p_amount<1 or p_amount>9000000000000000 then raise exception 'Invalid transfer amount'; end if;
  if p_character_id=p_recipient_character_id then raise exception 'Choose a different recipient character'; end if;
  if coalesce(length(trim(p_request_id)),0)<8 or length(p_request_id)>100 then raise exception 'Invalid request identifier'; end if;
  select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;

  select * into v_tx from public.site_bank_transactions where request_id=p_request_id;
  if found then
    if v_tx.actor_app_user_id<>v_profile.app_user_id or v_tx.kind<>'transfer'
       or v_tx.sender_character_id<>p_character_id or v_tx.recipient_character_id<>p_recipient_character_id then
      raise exception 'Request identifier has already been used';
    end if;
    return jsonb_build_object('ok',true,'duplicate',true,'transaction_id',v_tx.id);
  end if;

  select payload into v_sender_char from public.site_records
   where collection='characters' and record_id=p_character_id;
  if v_sender_char is null or v_sender_char ->> 'ownerId' is distinct from v_profile.app_user_id
     or v_sender_char ->> 'status' is distinct from 'approved' then
    raise exception 'Sender character is not available for banking';
  end if;
  select payload into v_recipient_char from public.site_records
   where collection='characters' and record_id=p_recipient_character_id;
  if v_recipient_char is null or v_recipient_char ->> 'status' is distinct from 'approved' then
    raise exception 'Recipient character is not available';
  end if;

  -- Lock both accounts in a stable order so simultaneous transfers cannot overspend balances.
  perform 1 from public.site_bank_accounts
   where character_id in (p_character_id,p_recipient_character_id)
   order by id
   for update;

  select * into v_sender from public.site_bank_accounts
   where character_id=p_character_id and owner_app_user_id=v_profile.app_user_id;
  if not found then raise exception 'Open a sender bank account first'; end if;
  select * into v_recipient from public.site_bank_accounts
   where character_id=p_recipient_character_id;
  if not found then raise exception 'Recipient has not opened a bank account'; end if;

  select transfer_fee_bps into v_fee_bps from public.site_bank_settings where singleton_id=true;
  v_fee:=ceil(p_amount::numeric*coalesce(v_fee_bps,0)/10000.0)::bigint;
  v_total:=p_amount+v_fee;
  if v_sender.balance<v_total then raise exception 'Insufficient bank balance including fee'; end if;

  update public.site_bank_accounts set balance=balance-v_total where id=v_sender.id;
  update public.site_bank_accounts set balance=balance+p_amount where id=v_recipient.id;
  insert into public.site_bank_transactions(
    request_id,kind,actor_app_user_id,sender_character_id,recipient_character_id,
    source_account_id,destination_account_id,amount,fee,note
  ) values (
    p_request_id,'transfer',v_profile.app_user_id,p_character_id,p_recipient_character_id,
    v_sender.id,v_recipient.id,p_amount,v_fee,v_note
  );

  return jsonb_build_object('ok',true,'amount',p_amount,'fee',v_fee,'recipient_account_number',v_recipient.account_number);
end;
$$;

create or replace function public.site_bank_admin_overview()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_settings public.site_bank_settings%rowtype;
  v_transactions jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
  if not found or not (v_profile.role='admin' or 'manage_economy'=any(coalesce(v_profile.permissions,'{}'::text[]))) then
    raise exception 'Bank administration permission required';
  end if;
  select * into v_settings from public.site_bank_settings where singleton_id=true;

  select coalesce(jsonb_agg(row_data order by created_at desc),'[]'::jsonb)
  into v_transactions
  from (
    select t.created_at,
      jsonb_build_object(
        'id',t.id,'request_id',t.request_id,'kind',t.kind,'amount',t.amount,'fee',t.fee,'note',t.note,'created_at',t.created_at,
        'sender_character_id',t.sender_character_id,'recipient_character_id',t.recipient_character_id,
        'sender_name',coalesce(nullif(sc.payload ->> 'stageName',''),nullif(sc.payload ->> 'name',''),t.sender_character_id,'-'),
        'recipient_name',coalesce(nullif(rc.payload ->> 'stageName',''),nullif(rc.payload ->> 'name',''),t.recipient_character_id,'-'),
        'source_account_number',sa.account_number,'destination_account_number',da.account_number,
        'actor_app_user_id',t.actor_app_user_id
      ) as row_data
    from public.site_bank_transactions t
    left join public.site_records sc on sc.collection='characters' and sc.record_id=t.sender_character_id
    left join public.site_records rc on rc.collection='characters' and rc.record_id=t.recipient_character_id
    left join public.site_bank_accounts sa on sa.id=t.source_account_id
    left join public.site_bank_accounts da on da.id=t.destination_account_id
    order by t.created_at desc
    limit 200
  ) q;

  return jsonb_build_object(
    'settings',jsonb_build_object(
      'deposit_fee_bps',coalesce(v_settings.deposit_fee_bps,0),
      'withdrawal_fee_bps',coalesce(v_settings.withdrawal_fee_bps,0),
      'transfer_fee_bps',coalesce(v_settings.transfer_fee_bps,0),
      'updated_at',v_settings.updated_at
    ),
    'transactions',v_transactions
  );
end;
$$;

create or replace function public.site_bank_admin_update_settings(
  p_deposit_fee_bps integer,p_withdrawal_fee_bps integer,p_transfer_fee_bps integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
  if not found or not (v_profile.role='admin' or 'manage_economy'=any(coalesce(v_profile.permissions,'{}'::text[]))) then
    raise exception 'Bank administration permission required';
  end if;
  if p_deposit_fee_bps not between 0 and 10000
     or p_withdrawal_fee_bps not between 0 and 10000
     or p_transfer_fee_bps not between 0 and 10000 then
    raise exception 'Each fee must be between 0% and 100%';
  end if;

  update public.site_bank_settings
   set deposit_fee_bps=p_deposit_fee_bps,
       withdrawal_fee_bps=p_withdrawal_fee_bps,
       transfer_fee_bps=p_transfer_fee_bps,
       updated_at=now(),
       updated_by=auth.uid()
   where singleton_id=true;

  insert into public.site_bank_settings_audit(
    changed_by_app_user_id,deposit_fee_bps,withdrawal_fee_bps,transfer_fee_bps
  ) values (
    v_profile.app_user_id,p_deposit_fee_bps,p_withdrawal_fee_bps,p_transfer_fee_bps
  );

  return jsonb_build_object('ok',true);
end;
$$;

revoke all on function public.site_bank_get_account(text) from public, anon;
revoke all on function public.site_bank_open_account(text) from public, anon;
revoke all on function public.site_bank_find_recipient(text,text) from public, anon;
revoke all on function public.site_bank_my_transactions(text) from public, anon;
revoke all on function public.site_bank_deposit(text,bigint,text) from public, anon;
revoke all on function public.site_bank_withdraw(text,bigint,text) from public, anon;
revoke all on function public.site_bank_transfer(text,text,bigint,text,text) from public, anon;
revoke all on function public.site_bank_admin_overview() from public, anon;
revoke all on function public.site_bank_admin_update_settings(integer,integer,integer) from public, anon;

grant execute on function public.site_bank_get_account(text) to authenticated;
grant execute on function public.site_bank_open_account(text) to authenticated;
grant execute on function public.site_bank_find_recipient(text,text) to authenticated;
grant execute on function public.site_bank_my_transactions(text) to authenticated;
grant execute on function public.site_bank_deposit(text,bigint,text) to authenticated;
grant execute on function public.site_bank_withdraw(text,bigint,text) to authenticated;
grant execute on function public.site_bank_transfer(text,text,bigint,text,text) to authenticated;
grant execute on function public.site_bank_admin_overview() to authenticated;
grant execute on function public.site_bank_admin_update_settings(integer,integer,integer) to authenticated;

notify pgrst, 'reload schema';

commit;

