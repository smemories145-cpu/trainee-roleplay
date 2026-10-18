-- STARLIGHT RP: recent activity / online today system
-- Run once in Supabase Dashboard > SQL Editor.
-- The presence table has RLS enabled and no direct client table access. Clients use the RPCs only.
begin;

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
commit;
