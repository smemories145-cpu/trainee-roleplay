-- STARLIGHT ACADEMY shared database foundation
-- Run this file once in Supabase Dashboard > SQL Editor as project owner.
-- This schema deliberately keeps passwords out of public site records.
-- Client writes must use the RPC functions below; direct table writes are revoked.

create table if not exists public.site_profiles (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  app_user_id text not null unique,
  username text not null unique,
  role text not null default 'player' check (role in ('admin','player')),
  created_at timestamptz not null default now()
);

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

  if p_delete then
    if not found then return jsonb_build_object('ok', true, 'deleted', false); end if;
    if not v_admin then
      if p_collection = 'posts' then
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

  if not v_admin then
    if p_collection = 'users' then
      if v_new ->> 'id' is distinct from v_profile.app_user_id then
        raise exception 'Cannot modify another account';
      end if;
      if exists (select 1 from public.site_records r
        where r.collection = 'users' and r.record_id = p_record_id
          and r.payload ->> 'role' is distinct from v_profile.role)
        and v_new ->> 'role' is distinct from v_profile.role then
        raise exception 'Only an administrator can change roles';
      end if;
      v_new := jsonb_set(v_new, '{role}', to_jsonb(v_profile.role), true);
    elsif p_collection = 'characters' then
      if v_new ->> 'ownerId' is distinct from v_profile.app_user_id then
        raise exception 'Characters can only be written by their owner';
      end if;
      if v_old is null then
        -- New player characters must start as pending; approval and progression
        -- are administrator-controlled.
        v_new := jsonb_set(v_new, '{status}', '"pending"'::jsonb, true);
        v_new := jsonb_set(v_new, '{stage}', '0'::jsonb, true);
        v_new := jsonb_set(v_new, '{exp}', '0'::jsonb, true);
        v_new := jsonb_set(v_new, '{won}', '10000'::jsonb, true);
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
      if v_new ->> 'userId' is distinct from v_profile.app_user_id
        or coalesce((v_new ->> 'gm')::boolean, false) then
        raise exception 'Players can only post as themselves';
      end if;
      if v_old is not null and v_old ->> 'userId' is distinct from v_profile.app_user_id then
        raise exception 'Cannot modify another user''s post';
      end if;
      if nullif(v_new ->> 'charId','') is not null and not exists (
        select 1 from public.site_records c
        where c.collection='characters'
          and c.record_id = v_new ->> 'charId'
          and c.payload ->> 'ownerId' = v_profile.app_user_id
      ) then
        raise exception 'Post character does not belong to this account';
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

revoke all on function public.site_is_admin() from public, anon;
grant execute on function public.site_is_admin() to authenticated;
revoke all on function public.site_record_write(text,text,jsonb,boolean) from public, anon;
grant execute on function public.site_record_write(text,text,jsonb,boolean) to authenticated;
revoke all on function public.site_import_local_snapshot(jsonb) from public, anon;
grant execute on function public.site_import_local_snapshot(jsonb) to authenticated;

-- After the first account signs into STARLIGHT ACADEMY from the legacy device,
-- promote the existing site owner once in SQL Editor. Replace Admin if needed:
-- update public.site_profiles set role = 'admin' where lower(username) = lower('Admin');
