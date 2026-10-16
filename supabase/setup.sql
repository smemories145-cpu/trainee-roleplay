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



create or replace function public.site_create_post(
  p_post jsonb,
  p_train text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $
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

  select payload into v_thread from public.site_records where collection='threads' and record_id=v_tid;
  if v_thread is null then raise exception 'Thread not found'; end if;
  if coalesce(v_thread ->> 'status','open') = 'closed' then raise exception 'Thread is closed'; end if;
  if nullif(v_thread ->> 'deadline','') is not null
    and (v_thread ->> 'deadline')::timestamptz < now() then raise exception 'Thread deadline has passed'; end if;
  if coalesce(v_thread ->> 'type','main') = 'notice' then raise exception 'Players cannot post in announcement threads'; end if;

  select payload into v_char from public.site_records where collection='characters' and record_id=v_cid;
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
$;

create or replace function public.site_practice(p_character_id text,p_stat text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $
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
  if p_stat not in ('vocal','dance','rap','visual','charm') then raise exception 'Unknown stat'; end if;
  select payload into v_char from public.site_records where collection='characters' and record_id=p_character_id;
  if v_char is null or v_char ->> 'ownerId' is distinct from v_profile.app_user_id
    or v_char ->> 'status' <> 'approved' then raise exception 'Character is not available'; end if;
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
$;

create or replace function public.site_claim_salary(p_character_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $
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
  select payload into v_char from public.site_records where collection='characters' and record_id=p_character_id;
  if v_char is null or v_char ->> 'ownerId' is distinct from v_profile.app_user_id
    or v_char ->> 'status' <> 'approved' then raise exception 'Character is not available'; end if;
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
$;

create or replace function public.site_transfer(
 p_sender_id text,p_recipient_id text,p_amount integer,p_note text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $
declare
 v_profile public.site_profiles%rowtype;
 v_sender jsonb;
 v_recipient jsonb;
 v_now_ms bigint;
 v_note text;
 v_sender_name text;
 v_recipient_name text;
 v_ledger jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found then raise exception 'Account profile has not been initialized'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'Invalid transfer amount'; end if;
 select payload into v_sender from public.site_records where collection='characters' and record_id=p_sender_id for update;
 select payload into v_recipient from public.site_records where collection='characters' and record_id=p_recipient_id for update;
 if v_sender is null or v_sender ->> 'ownerId' is distinct from v_profile.app_user_id
   or v_sender ->> 'status' <> 'approved' then raise exception 'Sender character is not available'; end if;
 if v_recipient is null or v_recipient ->> 'status' <> 'approved' then raise exception 'Recipient character is not available'; end if;
 if p_sender_id=p_recipient_id then raise exception 'Cannot transfer to the same character'; end if;
 if coalesce((v_sender ->> 'won')::numeric,0)<p_amount then raise exception 'Insufficient funds'; end if;
 v_now_ms := floor(extract(epoch from clock_timestamp())*1000)::bigint;
 v_note := left(coalesce(p_note,''),240);
 v_sender_name := coalesce(nullif(v_sender ->> 'stageName',''),v_sender ->> 'name','ตัวละคร');
 v_recipient_name := coalesce(nullif(v_recipient ->> 'stageName',''),v_recipient ->> 'name','ตัวละคร');
 v_sender := jsonb_set(v_sender,'{won}',to_jsonb(coalesce((v_sender ->> 'won')::numeric,0)-p_amount),true);
 v_ledger := jsonb_build_array(jsonb_build_object('at',v_now_ms,'amt',-p_amount,'note','โอนให้ '||v_recipient_name||case when v_note<>'' then ' · '||v_note else '' end)) || coalesce(v_sender -> 'ledger','[]'::jsonb);
 v_sender := jsonb_set(v_sender,'{ledger}',(select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) from jsonb_array_elements(v_ledger) with ordinality where ordinality<=30),true);
 v_recipient := jsonb_set(v_recipient,'{won}',to_jsonb(coalesce((v_recipient ->> 'won')::numeric,0)+p_amount),true);
 v_ledger := jsonb_build_array(jsonb_build_object('at',v_now_ms,'amt',p_amount,'note','รับโอนจาก '||v_sender_name||case when v_note<>'' then ' · '||v_note else '' end)) || coalesce(v_recipient -> 'ledger','[]'::jsonb);
 v_recipient := jsonb_set(v_recipient,'{ledger}',(select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) from jsonb_array_elements(v_ledger) with ordinality where ordinality<=30),true);
 update public.site_records set payload=v_sender,updated_at=now(),updated_by=auth.uid() where collection='characters' and record_id=p_sender_id;
 update public.site_records set payload=v_recipient,updated_at=now(),updated_by=auth.uid() where collection='characters' and record_id=p_recipient_id;
 return jsonb_build_object('ok',true,'sender',v_sender,'recipient',v_recipient);
end;
$;

create or replace function public.site_buy_item(p_character_id text,p_item_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $
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
   or v_char ->> 'status' <> 'approved' then raise exception 'Character is not available'; end if;
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
$;

revoke all on function public.site_create_post(jsonb,text) from public, anon;
grant execute on function public.site_create_post(jsonb,text) to authenticated;
revoke all on function public.site_practice(text,text) from public, anon;
grant execute on function public.site_practice(text,text) to authenticated;
revoke all on function public.site_claim_salary(text) from public, anon;
grant execute on function public.site_claim_salary(text) to authenticated;
revoke all on function public.site_transfer(text,text,integer,text) from public, anon;
grant execute on function public.site_transfer(text,text,integer,text) to authenticated;
revoke all on function public.site_buy_item(text,text) from public, anon;
grant execute on function public.site_buy_item(text,text) to authenticated;

do $
begin
  if exists (select 1 from pg_publication where pubname='supabase_realtime')
    and not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='site_records') then
    execute 'alter publication supabase_realtime add table public.site_records';
  end if;
end $;

-- After the first account signs into STARLIGHT ACADEMY from the legacy device,
-- promote the existing site owner once in SQL Editor. Replace Admin if needed:
-- update public.site_profiles set role = 'admin' where lower(username) = lower('Admin');
