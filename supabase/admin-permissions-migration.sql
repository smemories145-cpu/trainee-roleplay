-- STARLIGHT RP: granular admin permissions migration
-- Run this once in Supabase Dashboard > SQL Editor after deploying the matching website code.
-- Safe to re-run; uses ALTER ... IF NOT EXISTS and CREATE OR REPLACE FUNCTION.
begin;

alter table public.site_profiles
  add column if not exists permissions text[] not null default '{}';

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

notify pgrst, 'reload schema';
commit;
