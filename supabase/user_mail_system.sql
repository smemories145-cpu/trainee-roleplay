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
