-- STARLIGHT RP phone communications + item transfer
-- Existing installations: run this file once in Supabase SQL Editor after banking-phone-migration.sql.
-- Client access to these tables is denied; authenticated users interact through validated RPCs only.
begin;

create table if not exists public.site_phone_settings (
  singleton_id boolean primary key default true check(singleton_id=true),
  max_group_members integer not null default 30 check(max_group_members between 2 and 200),
  unsend_fee bigint not null default 100 check(unsend_fee between 0 and 9000000000000000),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
insert into public.site_phone_settings(singleton_id) values(true)
on conflict(singleton_id) do nothing;

create table if not exists public.site_phone_conversations (
  id text primary key default gen_random_uuid()::text,
  kind text not null check(kind in ('dm','group')),
  dm_char_a text,
  dm_char_b text,
  group_name text,
  description text not null default '',
  image_url text not null default '',
  owner_character_id text,
  pinned_message_id text,
  is_closed boolean not null default false,
  created_by_app_user_id text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at timestamptz,
  constraint site_phone_dm_pair_check check (
    (kind='dm' and dm_char_a is not null and dm_char_b is not null and dm_char_a < dm_char_b
      and group_name is null and owner_character_id is null)
    or
    (kind='group' and dm_char_a is null and dm_char_b is null
      and group_name is not null and owner_character_id is not null)
  )
);
alter table public.site_phone_conversations add column if not exists pinned_message_id text;
create unique index if not exists site_phone_dm_pair_unique
 on public.site_phone_conversations(dm_char_a,dm_char_b) where kind='dm';
create index if not exists site_phone_conversations_updated_idx
 on public.site_phone_conversations(updated_at desc);

create table if not exists public.site_phone_members (
  conversation_id text not null references public.site_phone_conversations(id) on delete cascade,
  character_id text not null,
  owner_app_user_id text not null,
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  is_owner boolean not null default false,
  is_muted boolean not null default false,
  mentions_enabled boolean not null default true,
  last_read_at timestamptz,
  primary key(conversation_id,character_id)
);
create index if not exists site_phone_members_character_idx
 on public.site_phone_members(character_id,left_at,joined_at desc);

create table if not exists public.site_phone_group_invites (
  id text primary key default gen_random_uuid()::text,
  conversation_id text not null references public.site_phone_conversations(id) on delete cascade,
  invited_by_character_id text not null,
  invited_character_id text not null,
  status text not null default 'pending' check(status in ('pending','accepted','declined','canceled')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  unique(conversation_id,invited_character_id,id)
);
create unique index if not exists site_phone_group_invite_pending_unique
 on public.site_phone_group_invites(conversation_id,invited_character_id) where status='pending';
create index if not exists site_phone_invites_inbox_idx
 on public.site_phone_group_invites(invited_character_id,status,created_at desc);

create table if not exists public.site_phone_messages (
  id text primary key default gen_random_uuid()::text,
  request_id text not null unique,
  conversation_id text not null references public.site_phone_conversations(id) on delete cascade,
  sender_character_id text not null,
  sender_app_user_id text not null,
  body text not null default '',
  image_url text not null default '',
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by_character_id text,
  constraint site_phone_message_content_check check(char_length(body)<=4000 and char_length(image_url)<=1000)
);
create index if not exists site_phone_messages_conversation_idx
 on public.site_phone_messages(conversation_id,created_at desc);
create index if not exists site_phone_messages_sender_idx
 on public.site_phone_messages(sender_character_id,created_at desc);

create table if not exists public.site_phone_message_reads (
  message_id text not null references public.site_phone_messages(id) on delete cascade,
  character_id text not null,
  read_at timestamptz not null default now(),
  primary key(message_id,character_id)
);
create index if not exists site_phone_message_reads_character_idx
 on public.site_phone_message_reads(character_id,read_at desc);

create table if not exists public.site_phone_hidden_messages (
  message_id text not null references public.site_phone_messages(id) on delete cascade,
  character_id text not null,
  hidden_at timestamptz not null default now(),
  primary key(message_id,character_id)
);

create table if not exists public.site_phone_blocks (
  owner_character_id text not null,
  blocked_character_id text not null,
  created_at timestamptz not null default now(),
  primary key(owner_character_id,blocked_character_id),
  constraint site_phone_block_not_self check(owner_character_id<>blocked_character_id)
);
create index if not exists site_phone_blocks_blocked_idx
 on public.site_phone_blocks(blocked_character_id,owner_character_id);

create table if not exists public.site_phone_contacts (
  owner_character_id text not null,
  contact_character_id text not null,
  favorite boolean not null default false,
  nickname text not null default '',
  created_at timestamptz not null default now(),
  primary key(owner_character_id,contact_character_id),
  constraint site_phone_contact_not_self check(owner_character_id<>contact_character_id)
);

create table if not exists public.site_phone_notifications (
  id bigint generated always as identity primary key,
  character_id text not null,
  kind text not null,
  actor_character_id text,
  conversation_id text,
  message_id text,
  transfer_id bigint,
  payload jsonb not null default '{}'::jsonb check(jsonb_typeof(payload)='object'),
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists site_phone_notifications_inbox_idx
 on public.site_phone_notifications(character_id,is_read,created_at desc);

create table if not exists public.site_phone_presence (
  character_id text primary key,
  hide_presence boolean not null default false,
  hide_last_seen boolean not null default false,
  last_seen_at timestamptz not null default now()
);

create table if not exists public.site_phone_item_transfers (
  id bigint generated always as identity primary key,
  request_id text not null unique,
  sender_character_id text not null,
  recipient_character_id text not null,
  item_id text not null,
  quantity integer not null check(quantity between 1 and 100),
  item_name text not null,
  note text not null default '',
  created_at timestamptz not null default now(),
  constraint site_phone_item_transfer_not_self check(sender_character_id<>recipient_character_id)
);
create index if not exists site_phone_item_transfer_sender_idx
 on public.site_phone_item_transfers(sender_character_id,created_at desc);
create index if not exists site_phone_item_transfer_recipient_idx
 on public.site_phone_item_transfers(recipient_character_id,created_at desc);

create table if not exists public.site_phone_reports (
  id bigint generated always as identity primary key,
  message_id text not null references public.site_phone_messages(id) on delete restrict,
  reporter_character_id text not null,
  reason text not null check(char_length(reason) between 3 and 800),
  status text not null default 'pending' check(status in ('pending','reviewed','dismissed')),
  created_at timestamptz not null default now(),
  reviewed_by_app_user_id text,
  reviewed_at timestamptz,
  review_note text not null default '',
  unique(message_id,reporter_character_id)
);
create index if not exists site_phone_reports_status_idx
 on public.site_phone_reports(status,created_at desc);

create table if not exists public.site_phone_audit (
  id bigint generated always as identity primary key,
  actor_app_user_id text not null,
  actor_character_id text,
  action text not null,
  target_type text not null,
  target_id text not null,
  detail jsonb not null default '{}'::jsonb check(jsonb_typeof(detail)='object'),
  created_at timestamptz not null default now()
);
create index if not exists site_phone_audit_created_idx on public.site_phone_audit(created_at desc);

alter table public.site_phone_settings enable row level security;
alter table public.site_phone_conversations enable row level security;
alter table public.site_phone_members enable row level security;
alter table public.site_phone_group_invites enable row level security;
alter table public.site_phone_messages enable row level security;
alter table public.site_phone_message_reads enable row level security;
alter table public.site_phone_hidden_messages enable row level security;
alter table public.site_phone_blocks enable row level security;
alter table public.site_phone_contacts enable row level security;
alter table public.site_phone_notifications enable row level security;
alter table public.site_phone_presence enable row level security;
alter table public.site_phone_item_transfers enable row level security;
alter table public.site_phone_reports enable row level security;
alter table public.site_phone_audit enable row level security;

revoke all on public.site_phone_settings from public,anon,authenticated;
revoke all on public.site_phone_conversations from public,anon,authenticated;
revoke all on public.site_phone_members from public,anon,authenticated;
revoke all on public.site_phone_group_invites from public,anon,authenticated;
revoke all on public.site_phone_messages from public,anon,authenticated;
revoke all on public.site_phone_message_reads from public,anon,authenticated;
revoke all on public.site_phone_hidden_messages from public,anon,authenticated;
revoke all on public.site_phone_blocks from public,anon,authenticated;
revoke all on public.site_phone_contacts from public,anon,authenticated;
revoke all on public.site_phone_notifications from public,anon,authenticated;
revoke all on public.site_phone_presence from public,anon,authenticated;
revoke all on public.site_phone_item_transfers from public,anon,authenticated;
revoke all on public.site_phone_reports from public,anon,authenticated;
revoke all on public.site_phone_audit from public,anon,authenticated;

create or replace function public.site_phone_character_owned(p_character_id text,p_app_user_id text)
returns boolean
language sql stable security definer
set search_path=public,pg_temp
as $$
 select exists(
  select 1 from public.site_records r
  where r.collection='characters' and r.record_id=p_character_id
    and r.payload ->> 'ownerId'=p_app_user_id
    and r.payload ->> 'status'='approved'
 );
$$;

create or replace function public.site_phone_is_blocked_between(p_a text,p_b text)
returns boolean
language sql stable security definer
set search_path=public,pg_temp
as $$
 select exists(
  select 1 from public.site_phone_blocks b
  where (b.owner_character_id=p_a and b.blocked_character_id=p_b)
     or (b.owner_character_id=p_b and b.blocked_character_id=p_a)
 );
$$;

create or replace function public.site_phone_notify(
 p_character_id text,p_kind text,p_actor_character_id text default null,
 p_conversation_id text default null,p_message_id text default null,
 p_transfer_id bigint default null,p_payload jsonb default '{}'::jsonb
)
returns void language plpgsql security definer
set search_path=public,pg_temp
as $$
begin
 insert into public.site_phone_notifications(character_id,kind,actor_character_id,conversation_id,message_id,transfer_id,payload)
 values(p_character_id,p_kind,p_actor_character_id,p_conversation_id,p_message_id,p_transfer_id,coalesce(p_payload,'{}'::jsonb));
end;
$$;

create or replace function public.site_phone_touch_presence(p_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found then raise exception 'Account profile has not been initialized'; end if;
 if not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then
  raise exception 'Character is not available';
 end if;
 insert into public.site_phone_presence(character_id,last_seen_at) values(p_character_id,now())
 on conflict(character_id) do update set last_seen_at=now();
 return jsonb_build_object('ok',true,'last_seen_at',now());
end;
$$;

create or replace function public.site_phone_set_privacy(p_character_id text,p_hide_presence boolean,p_hide_last_seen boolean)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then
  raise exception 'Character is not available';
 end if;
 insert into public.site_phone_presence(character_id,hide_presence,hide_last_seen,last_seen_at)
 values(p_character_id,coalesce(p_hide_presence,false),coalesce(p_hide_last_seen,false),now())
 on conflict(character_id) do update set hide_presence=excluded.hide_presence,hide_last_seen=excluded.hide_last_seen,last_seen_at=now();
 return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.site_phone_presence_for_characters(p_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then
  raise exception 'Character is not available';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'character_id',p.character_id,
   'online',case when coalesce(pr.hide_presence,false) then false else pr.last_seen_at>now()-interval '90 seconds' end,
   'last_seen_at',case when coalesce(pr.hide_last_seen,false) then null else pr.last_seen_at end,
   'hide_presence',coalesce(pr.hide_presence,false),
   'hide_last_seen',coalesce(pr.hide_last_seen,false)
  )),'[]'::jsonb)
 into v_result
 from public.site_phone_contacts p
 left join public.site_phone_presence pr on pr.character_id=p.contact_character_id
 where p.owner_character_id=p_character_id;
 return v_result;
end;
$$;

create or replace function public.site_phone_open_dm(p_character_id text,p_other_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare
 v_profile public.site_profiles%rowtype; v_other jsonb; v_a text; v_b text; v_id text; v_now timestamptz:=now();
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Sender character is not available'; end if;
 if p_character_id=p_other_character_id then raise exception 'Cannot start a conversation with yourself'; end if;
 select payload into v_other from public.site_records where collection='characters' and record_id=p_other_character_id;
 if v_other is null or v_other ->> 'status'<>'approved' then raise exception 'Recipient character is not available'; end if;
 if public.site_phone_is_blocked_between(p_character_id,p_other_character_id) then raise exception 'This character is blocked'; end if;
 v_a:=least(p_character_id,p_other_character_id); v_b:=greatest(p_character_id,p_other_character_id);
 select id into v_id from public.site_phone_conversations where kind='dm' and dm_char_a=v_a and dm_char_b=v_b;
 if v_id is null then
  insert into public.site_phone_conversations(kind,dm_char_a,dm_char_b,created_by_app_user_id,created_at,updated_at)
  values('dm',v_a,v_b,v_profile.app_user_id,v_now,v_now)
  on conflict(dm_char_a,dm_char_b) where kind='dm' do nothing
  returning id into v_id;
  if v_id is null then select id into v_id from public.site_phone_conversations where kind='dm' and dm_char_a=v_a and dm_char_b=v_b; end if;
 end if;
 insert into public.site_phone_members(conversation_id,character_id,owner_app_user_id,joined_at,last_read_at)
 values(v_id,p_character_id,v_profile.app_user_id,v_now,v_now)
 on conflict(conversation_id,character_id) do update set left_at=null,owner_app_user_id=excluded.owner_app_user_id;
 insert into public.site_phone_members(conversation_id,character_id,owner_app_user_id,joined_at,last_read_at)
 select v_id,p_other_character_id,coalesce(v_other->>'ownerId',''),v_now,v_now
 on conflict(conversation_id,character_id) do nothing;
 return jsonb_build_object('ok',true,'conversation_id',v_id,'kind','dm');
end;
$$;

create or replace function public.site_phone_list_conversations(p_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select coalesce(jsonb_agg(q.data order by q.last_at desc nulls last),'[]'::jsonb) into v_result
 from (
  select jsonb_build_object(
   'id',c.id,'kind',c.kind,
   'title',case when c.kind='group' then c.group_name else coalesce(nullif(other.payload->>'stageName',''),nullif(other.payload->>'name',''),'ตัวละคร') end,
   'other_character_id',case when c.kind='dm' then case when c.dm_char_a=p_character_id then c.dm_char_b else c.dm_char_a end else null end,
   'image_url',case when c.kind='group' then c.image_url else coalesce(other.payload->>'avatar','') end,
   'description',c.description,'owner_character_id',c.owner_character_id,
   'is_owner',coalesce(m.is_owner,false),'is_closed',c.is_closed,'is_muted',m.is_muted,'mentions_enabled',m.mentions_enabled,
   'member_count',(select count(*) from public.site_phone_members mm where mm.conversation_id=c.id and mm.left_at is null),
   'unread_count',(select count(*) from public.site_phone_messages msg where msg.conversation_id=c.id and msg.sender_character_id<>p_character_id and msg.created_at>=m.joined_at and (m.left_at is null or msg.created_at<m.left_at) and (m.last_read_at is null or msg.created_at>m.last_read_at) and not exists(select 1 from public.site_phone_hidden_messages h where h.message_id=msg.id and h.character_id=p_character_id)),
   'last_message',case when lm.revoked_at is not null then 'ข้อความถูกยกเลิก' else left(lm.body,180) end,
   'last_message_at',lm.created_at,'pinned_message_id',c.pinned_message_id,
   'left_at',m.left_at,
   'created_at',c.created_at
  ) as data,coalesce(lm.created_at,c.updated_at) as last_at
  from public.site_phone_members m
  join public.site_phone_conversations c on c.id=m.conversation_id
  left join public.site_records other on other.collection='characters' and other.record_id=case when c.dm_char_a=p_character_id then c.dm_char_b else c.dm_char_a end
  left join lateral (
   select msg.body,msg.revoked_at,msg.created_at
   from public.site_phone_messages msg
   where msg.conversation_id=c.id and msg.created_at>=m.joined_at and (m.left_at is null or msg.created_at<m.left_at)
     and not exists(select 1 from public.site_phone_hidden_messages h where h.message_id=msg.id and h.character_id=p_character_id)
   order by msg.created_at desc limit 1
  ) lm on true
  where m.character_id=p_character_id
 ) q;
 return v_result;
end;
$$;

create or replace function public.site_phone_get_messages(p_character_id text,p_conversation_id text,p_limit integer default 80)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_member public.site_phone_members%rowtype; v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select * into v_member from public.site_phone_members where conversation_id=p_conversation_id and character_id=p_character_id;
 if not found then raise exception 'Conversation is not available'; end if;
 select coalesce(jsonb_agg(q.data order by q.created_at),'[]'::jsonb) into v_result
 from (
  select msg.created_at,jsonb_build_object(
   'id',msg.id,'conversation_id',msg.conversation_id,'sender_character_id',msg.sender_character_id,
   'sender_name',coalesce(nullif(ch.payload->>'stageName',''),nullif(ch.payload->>'name',''),'ตัวละคร'),
   'sender_avatar',coalesce(ch.payload->>'avatar',''),
   'is_mine',msg.sender_character_id=p_character_id,
   'body',case when msg.revoked_at is not null then 'ข้อความถูกยกเลิก' else msg.body end,
   'image_url',case when msg.revoked_at is not null then '' else msg.image_url end,
   'created_at',msg.created_at,'revoked',msg.revoked_at is not null,
   'is_hidden',false,
   'is_pinned',msg.id=(select pinned_message_id from public.site_phone_conversations where id=msg.conversation_id)
  ) as data
  from public.site_phone_messages msg
  left join public.site_records ch on ch.collection='characters' and ch.record_id=msg.sender_character_id
  where msg.conversation_id=p_conversation_id and msg.created_at>=v_member.joined_at
    and (v_member.left_at is null or msg.created_at<v_member.left_at)
    and not exists(select 1 from public.site_phone_hidden_messages h where h.message_id=msg.id and h.character_id=p_character_id)
  order by msg.created_at desc
  limit greatest(1,least(coalesce(p_limit,80),120))
 ) q;
 return v_result;
end;
$$;

create or replace function public.site_phone_send_message(
 p_character_id text,p_conversation_id text,p_body text,p_image_url text default '',p_request_id text default ''
)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare
 v_profile public.site_profiles%rowtype; v_member public.site_phone_members%rowtype; v_conv public.site_phone_conversations%rowtype;
 v_existing public.site_phone_messages%rowtype; v_body text:=coalesce(p_body,''); v_image text:=trim(coalesce(p_image_url,'')); v_rec record; v_name text; v_kind text;
 v_message_id text; v_now timestamptz:=now(); v_is_mention boolean;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 if coalesce(length(trim(p_request_id)),0)<8 or length(p_request_id)>100 then raise exception 'Message request id is invalid'; end if;
 if char_length(v_body)>4000 then raise exception 'Message is too long'; end if;
 if v_body='' and v_image='' then raise exception 'Enter a message or image URL'; end if;
 if v_image<>'' and v_image !~* '^https?://[^[:space:]]+$' then raise exception 'Image must be a direct HTTP or HTTPS URL'; end if;
 select * into v_existing from public.site_phone_messages where request_id=p_request_id;
 if found then
  if v_existing.sender_character_id<>p_character_id or v_existing.conversation_id<>p_conversation_id then raise exception 'Request identifier has already been used'; end if;
  return jsonb_build_object('ok',true,'duplicate',true,'message_id',v_existing.id);
 end if;
 select * into v_conv from public.site_phone_conversations where id=p_conversation_id for update;
 if not found then raise exception 'Conversation not found'; end if;
 if v_conv.is_closed then raise exception 'This conversation is archived'; end if;
 select * into v_member from public.site_phone_members where conversation_id=p_conversation_id and character_id=p_character_id and left_at is null;
 if not found then raise exception 'You are not an active member of this conversation'; end if;
 if v_conv.kind='dm' then
  v_name:=case when v_conv.dm_char_a=p_character_id then v_conv.dm_char_b else v_conv.dm_char_a end;
  if public.site_phone_is_blocked_between(p_character_id,v_name) then raise exception 'This character is blocked'; end if;
 end if;
 insert into public.site_phone_messages(request_id,conversation_id,sender_character_id,sender_app_user_id,body,image_url,created_at)
 values(p_request_id,p_conversation_id,p_character_id,v_profile.app_user_id,v_body,v_image,v_now)
 returning id into v_message_id;
 update public.site_phone_conversations set updated_at=v_now where id=p_conversation_id;
 select coalesce(nullif(payload->>'stageName',''),nullif(payload->>'name',''),'ตัวละคร') into v_name from public.site_records where collection='characters' and record_id=p_character_id;
 for v_rec in
  select m.character_id,m.is_muted,m.mentions_enabled,coalesce(nullif(cr.payload->>'stageName',''),nullif(cr.payload->>'name',''),'ตัวละคร') as display_name
  from public.site_phone_members m
  left join public.site_records cr on cr.collection='characters' and cr.record_id=m.character_id
  where m.conversation_id=p_conversation_id and m.character_id<>p_character_id and m.left_at is null
 loop
  if public.site_phone_is_blocked_between(p_character_id,v_rec.character_id) and v_conv.kind='dm' then continue; end if;
  v_is_mention:=v_conv.kind='group' and v_rec.mentions_enabled and position('@'||lower(v_rec.display_name) in lower(v_body))>0;
  if v_is_mention then
   perform public.site_phone_notify(v_rec.character_id,'mention',p_character_id,p_conversation_id,v_message_id,null,jsonb_build_object('conversation_name',coalesce(v_conv.group_name,''),'sender_name',v_name));
  elsif not v_rec.is_muted then
   perform public.site_phone_notify(v_rec.character_id,'message',p_character_id,p_conversation_id,v_message_id,null,jsonb_build_object('conversation_name',case when v_conv.kind='group' then v_conv.group_name else v_name end,'sender_name',v_name));
  end if;
 end loop;
 return jsonb_build_object('ok',true,'message_id',v_message_id,'created_at',v_now);
end;
$$;

create or replace function public.site_phone_mark_read(p_character_id text,p_conversation_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_member public.site_phone_members%rowtype; v_count integer:=0;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select * into v_member from public.site_phone_members where conversation_id=p_conversation_id and character_id=p_character_id;
 if not found then raise exception 'Conversation is not available'; end if;
 insert into public.site_phone_message_reads(message_id,character_id,read_at)
 select m.id,p_character_id,now() from public.site_phone_messages m
 where m.conversation_id=p_conversation_id and m.sender_character_id<>p_character_id
   and m.created_at>=v_member.joined_at and (v_member.left_at is null or m.created_at<v_member.left_at)
 on conflict(message_id,character_id) do update set read_at=excluded.read_at;
 get diagnostics v_count=row_count;
 update public.site_phone_members set last_read_at=now() where conversation_id=p_conversation_id and character_id=p_character_id;
 update public.site_phone_notifications set is_read=true where character_id=p_character_id and conversation_id=p_conversation_id and not is_read;
 return jsonb_build_object('ok',true,'read_count',v_count);
end;
$$;

create or replace function public.site_phone_message_readers(p_character_id text,p_message_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_msg public.site_phone_messages%rowtype; v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select * into v_msg from public.site_phone_messages where id=p_message_id;
 if not found or not exists(select 1 from public.site_phone_members where conversation_id=v_msg.conversation_id and character_id=p_character_id) then raise exception 'Message is not available'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('character_id',r.character_id,'name',coalesce(nullif(cr.payload->>'stageName',''),nullif(cr.payload->>'name',''),'ตัวละคร'),'read_at',r.read_at) order by r.read_at),'[]'::jsonb)
 into v_result from public.site_phone_message_reads r
 left join public.site_records cr on cr.collection='characters' and cr.record_id=r.character_id
 where r.message_id=p_message_id;
 return v_result;
end;
$$;

create or replace function public.site_phone_hide_message(p_character_id text,p_message_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_msg public.site_phone_messages%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select * into v_msg from public.site_phone_messages where id=p_message_id;
 if not found or not exists(select 1 from public.site_phone_members where conversation_id=v_msg.conversation_id and character_id=p_character_id) then raise exception 'Message is not available'; end if;
 insert into public.site_phone_hidden_messages(message_id,character_id) values(p_message_id,p_character_id) on conflict do nothing;
 return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.site_phone_unsend_message(p_character_id text,p_message_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare
 v_profile public.site_profiles%rowtype; v_msg public.site_phone_messages%rowtype; v_char jsonb; v_fee bigint:=0; v_now timestamptz:=now(); v_now_ms bigint; v_ledger jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select * into v_msg from public.site_phone_messages where id=p_message_id for update;
 if not found or v_msg.sender_character_id<>p_character_id then raise exception 'Only the sender can unsend this message'; end if;
 if v_msg.revoked_at is not null then return jsonb_build_object('ok',true,'already_unsent',true); end if;
 if v_now-v_msg.created_at>interval '5 minutes' then
  select unsend_fee into v_fee from public.site_phone_settings where singleton_id=true;
  select payload into v_char from public.site_records where collection='characters' and record_id=p_character_id for update;
  if coalesce((v_char->>'won')::bigint,0)<v_fee then raise exception 'Not enough cash to unsend this message'; end if;
  v_now_ms:=floor(extract(epoch from clock_timestamp())*1000)::bigint;
  v_ledger:=jsonb_build_array(jsonb_build_object('at',v_now_ms,'amt',-v_fee,'note','ค่าธรรมเนียมยกเลิกข้อความ'))||coalesce(v_char->'ledger','[]'::jsonb);
  v_char:=jsonb_set(v_char,'{won}',to_jsonb(greatest(0,coalesce((v_char->>'won')::bigint,0)-v_fee)),true);
  v_char:=jsonb_set(v_char,'{ledger}',(select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) from jsonb_array_elements(v_ledger) with ordinality where ordinality<=30),true);
  update public.site_records set payload=v_char,updated_at=now(),updated_by=auth.uid() where collection='characters' and record_id=p_character_id;
 end if;
 update public.site_phone_messages set body='ข้อความถูกยกเลิก',image_url='',revoked_at=v_now,revoked_by_character_id=p_character_id where id=p_message_id;
 insert into public.site_phone_audit(actor_app_user_id,actor_character_id,action,target_type,target_id,detail)
 values(v_profile.app_user_id,p_character_id,'unsend_message','phone_message',p_message_id,jsonb_build_object('fee',v_fee));
 return jsonb_build_object('ok',true,'fee',v_fee);
end;
$$;

create or replace function public.site_phone_report_message(p_character_id text,p_message_id text,p_reason text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_msg public.site_phone_messages%rowtype; v_id bigint;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 if char_length(trim(coalesce(p_reason,'')))<3 or char_length(p_reason)>800 then raise exception 'Please provide a short report reason'; end if;
 select * into v_msg from public.site_phone_messages where id=p_message_id;
 if not found or not exists(select 1 from public.site_phone_members where conversation_id=v_msg.conversation_id and character_id=p_character_id) then raise exception 'Message is not available'; end if;
 insert into public.site_phone_reports(message_id,reporter_character_id,reason)
 values(p_message_id,p_character_id,trim(p_reason))
 on conflict(message_id,reporter_character_id) do update set reason=excluded.reason,status='pending',created_at=now()
 returning id into v_id;
 insert into public.site_phone_audit(actor_app_user_id,actor_character_id,action,target_type,target_id,detail)
 values(v_profile.app_user_id,p_character_id,'report_message','phone_message',p_message_id,jsonb_build_object('report_id',v_id));
 return jsonb_build_object('ok',true,'report_id',v_id);
end;
$$;

create or replace function public.site_phone_list_contacts(p_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'character_id',c.contact_character_id,'favorite',c.favorite,'nickname',c.nickname,'created_at',c.created_at,
  'name',coalesce(nullif(r.payload->>'stageName',''),nullif(r.payload->>'name',''),'ตัวละคร'),
  'avatar',coalesce(r.payload->>'avatar',''),'stage',coalesce(r.payload->>'stage',0),
  'status',coalesce(r.payload->>'status','approved'),
  'online',case when coalesce(pr.hide_presence,false) then false else pr.last_seen_at>now()-interval '90 seconds' end,
  'last_seen_at',case when coalesce(pr.hide_last_seen,false) then null else pr.last_seen_at end
 ) order by c.favorite desc,coalesce(nullif(r.payload->>'stageName',''),nullif(r.payload->>'name',''),c.contact_character_id))),'[]'::jsonb)
 into v_result from public.site_phone_contacts c
 left join public.site_records r on r.collection='characters' and r.record_id=c.contact_character_id
 left join public.site_phone_presence pr on pr.character_id=c.contact_character_id
 where c.owner_character_id=p_character_id and r.payload->>'status'='approved';
 return v_result;
end;
$$;

create or replace function public.site_phone_add_contact(p_character_id text,p_contact_character_id text,p_nickname text default '')
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_target jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 if p_character_id=p_contact_character_id then raise exception 'Cannot add yourself as a contact'; end if;
 select payload into v_target from public.site_records where collection='characters' and record_id=p_contact_character_id;
 if v_target is null or v_target->>'status'<>'approved' then raise exception 'Contact character is not available'; end if;
 insert into public.site_phone_contacts(owner_character_id,contact_character_id,nickname)
 values(p_character_id,p_contact_character_id,left(trim(coalesce(p_nickname,'')),80))
 on conflict(owner_character_id,contact_character_id) do update set nickname=excluded.nickname;
 return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.site_phone_contact_update(p_character_id text,p_contact_character_id text,p_favorite boolean,p_nickname text default '')
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_count integer;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 update public.site_phone_contacts set favorite=coalesce(p_favorite,false),nickname=left(trim(coalesce(p_nickname,'')),80)
 where owner_character_id=p_character_id and contact_character_id=p_contact_character_id;
 get diagnostics v_count=row_count;
 if v_count=0 then raise exception 'Contact not found'; end if;
 return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.site_phone_remove_contact(p_character_id text,p_contact_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 delete from public.site_phone_contacts where owner_character_id=p_character_id and contact_character_id=p_contact_character_id;
 return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.site_phone_list_blocks(p_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('character_id',b.blocked_character_id,'name',coalesce(nullif(r.payload->>'stageName',''),nullif(r.payload->>'name',''),'ตัวละคร'),'avatar',coalesce(r.payload->>'avatar',''))),'[]'::jsonb)
 into v_result from public.site_phone_blocks b
 left join public.site_records r on r.collection='characters' and r.record_id=b.blocked_character_id
 where b.owner_character_id=p_character_id;
 return v_result;
end;
$$;

create or replace function public.site_phone_block(p_character_id text,p_blocked_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_target jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 if p_character_id=p_blocked_character_id then raise exception 'Cannot block yourself'; end if;
 select payload into v_target from public.site_records where collection='characters' and record_id=p_blocked_character_id;
 if v_target is null or v_target->>'status'<>'approved' then raise exception 'Character is not available'; end if;
 insert into public.site_phone_blocks(owner_character_id,blocked_character_id) values(p_character_id,p_blocked_character_id) on conflict do nothing;
 insert into public.site_phone_audit(actor_app_user_id,actor_character_id,action,target_type,target_id,detail)
 values(v_profile.app_user_id,p_character_id,'block_character','character',p_blocked_character_id,'{}'::jsonb);
 return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.site_phone_unblock(p_character_id text,p_blocked_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 delete from public.site_phone_blocks where owner_character_id=p_character_id and blocked_character_id=p_blocked_character_id;
 insert into public.site_phone_audit(actor_app_user_id,actor_character_id,action,target_type,target_id,detail)
 values(v_profile.app_user_id,p_character_id,'unblock_character','character',p_blocked_character_id,'{}'::jsonb);
 return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.site_phone_list_notifications(p_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select coalesce(jsonb_agg(q.data order by q.created_at desc),'[]'::jsonb)
 into v_result from (
  select n.created_at,jsonb_build_object(
   'id',n.id,'kind',n.kind,'actor_character_id',n.actor_character_id,
   'actor_name',coalesce(nullif(a.payload->>'stageName',''),nullif(a.payload->>'name',''),'STARLIGHT'),
   'conversation_id',n.conversation_id,'message_id',n.message_id,'transfer_id',n.transfer_id,
   'payload',n.payload,'is_read',n.is_read,'created_at',n.created_at
  ) as data
  from public.site_phone_notifications n
  left join public.site_records a on a.collection='characters' and a.record_id=n.actor_character_id
  where n.character_id=p_character_id
  order by n.created_at desc limit 80
 ) q;
 return v_result;
end;
$$;

create or replace function public.site_phone_mark_notification_read(p_character_id text,p_notification_id bigint)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_count integer;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 update public.site_phone_notifications set is_read=true where id=p_notification_id and character_id=p_character_id;
 get diagnostics v_count=row_count;
 if v_count=0 then raise exception 'Notification not found'; end if;
 return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.site_phone_mark_all_notifications_read(p_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_count integer;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 update public.site_phone_notifications set is_read=true where character_id=p_character_id and not is_read;
 get diagnostics v_count=row_count;
 return jsonb_build_object('ok',true,'count',v_count);
end;
$$;

create or replace function public.site_phone_create_group(p_character_id text,p_name text,p_description text default '',p_image_url text default '')
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_id text; v_name text:=trim(coalesce(p_name,'')); v_image text:=trim(coalesce(p_image_url,''));
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 if char_length(v_name)<1 or char_length(v_name)>80 then raise exception 'Group name must be 1 to 80 characters'; end if;
 if char_length(coalesce(p_description,''))>500 then raise exception 'Group description is too long'; end if;
 if v_image<>'' and v_image !~* '^https?://[^[:space:]]+$' then raise exception 'Group image must be an HTTP or HTTPS URL'; end if;
 insert into public.site_phone_conversations(kind,group_name,description,image_url,owner_character_id,created_by_app_user_id)
 values('group',v_name,left(coalesce(p_description,''),500),v_image,p_character_id,v_profile.app_user_id)
 returning id into v_id;
 insert into public.site_phone_members(conversation_id,character_id,owner_app_user_id,is_owner,last_read_at)
 values(v_id,p_character_id,v_profile.app_user_id,true,now());
 return jsonb_build_object('ok',true,'conversation_id',v_id);
end;
$$;

create or replace function public.site_phone_group_invite(p_character_id text,p_conversation_id text,p_invited_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_conv public.site_phone_conversations%rowtype; v_target jsonb; v_invite_id text;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select * into v_conv from public.site_phone_conversations where id=p_conversation_id and kind='group' for update;
 if not found or v_conv.owner_character_id<>p_character_id or v_conv.is_closed then raise exception 'Only the active group owner can invite members'; end if;
 if p_character_id=p_invited_character_id then raise exception 'Cannot invite yourself'; end if;
 select payload into v_target from public.site_records where collection='characters' and record_id=p_invited_character_id;
 if v_target is null or v_target->>'status'<>'approved' then raise exception 'Invited character is not available'; end if;
 if exists(select 1 from public.site_phone_members where conversation_id=p_conversation_id and character_id=p_invited_character_id and left_at is null) then raise exception 'Character is already in this group'; end if;
 if public.site_phone_is_blocked_between(p_character_id,p_invited_character_id) then raise exception 'This character is blocked'; end if;
 select id into v_invite_id from public.site_phone_group_invites where conversation_id=p_conversation_id and invited_character_id=p_invited_character_id and status='pending' limit 1;
 if v_invite_id is null then
  insert into public.site_phone_group_invites(conversation_id,invited_by_character_id,invited_character_id,status)
  values(p_conversation_id,p_character_id,p_invited_character_id,'pending') returning id into v_invite_id;
 end if;
 perform public.site_phone_notify(p_invited_character_id,'group_invite',p_character_id,p_conversation_id,null,null,jsonb_build_object('group_name',v_conv.group_name,'invite_id',v_invite_id));
 return jsonb_build_object('ok',true,'invite_id',v_invite_id,'pending',true);
end;
$$;

create or replace function public.site_phone_list_invites(p_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',i.id,'conversation_id',i.conversation_id,'group_name',c.group_name,'group_image',c.image_url,
  'invited_by_character_id',i.invited_by_character_id,'inviter_name',coalesce(nullif(a.payload->>'stageName',''),nullif(a.payload->>'name',''),'ตัวละคร'),
  'status',i.status,'created_at',i.created_at,
  'member_count',(select count(*) from public.site_phone_members m where m.conversation_id=c.id and m.left_at is null),
  'is_closed',c.is_closed
 ) order by i.created_at desc),'[]'::jsonb)
 into v_result from public.site_phone_group_invites i
 join public.site_phone_conversations c on c.id=i.conversation_id
 left join public.site_records a on a.collection='characters' and a.record_id=i.invited_by_character_id
 where i.invited_character_id=p_character_id and i.status='pending';
 return v_result;
end;
$$;

create or replace function public.site_phone_group_invite_response(p_character_id text,p_invite_id text,p_accept boolean)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_inv public.site_phone_group_invites%rowtype; v_conv public.site_phone_conversations%rowtype; v_settings public.site_phone_settings%rowtype; v_member_count integer;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select * into v_inv from public.site_phone_group_invites where id=p_invite_id and invited_character_id=p_character_id and status='pending' for update;
 if not found then raise exception 'Invitation is no longer pending'; end if;
 select * into v_conv from public.site_phone_conversations where id=v_inv.conversation_id for update;
 if v_conv.is_closed then raise exception 'This group is archived'; end if;
 if not p_accept then
  update public.site_phone_group_invites set status='declined',responded_at=now() where id=p_invite_id;
  return jsonb_build_object('ok',true,'accepted',false);
 end if;
 select * into v_settings from public.site_phone_settings where singleton_id=true;
 select count(*) into v_member_count from public.site_phone_members where conversation_id=v_conv.id and left_at is null;
 if v_member_count>=v_settings.max_group_members then raise exception 'Group is full; this invitation remains pending'; end if;
 insert into public.site_phone_members(conversation_id,character_id,owner_app_user_id,is_owner,joined_at,last_read_at)
 values(v_conv.id,p_character_id,v_profile.app_user_id,false,now(),now())
 on conflict(conversation_id,character_id) do update set owner_app_user_id=excluded.owner_app_user_id,is_owner=false,joined_at=now(),left_at=null,last_read_at=now();
 update public.site_phone_group_invites set status='accepted',responded_at=now() where id=p_invite_id;
 perform public.site_phone_notify(v_conv.owner_character_id,'group_joined',p_character_id,v_conv.id,null,null,jsonb_build_object('group_name',v_conv.group_name));
 return jsonb_build_object('ok',true,'accepted',true,'conversation_id',v_conv.id);
end;
$$;

create or replace function public.site_phone_group_remove_member(p_character_id text,p_conversation_id text,p_target_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_conv public.site_phone_conversations%rowtype; v_count integer;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select * into v_conv from public.site_phone_conversations where id=p_conversation_id and kind='group' for update;
 if not found or v_conv.owner_character_id<>p_character_id or v_conv.is_closed then raise exception 'Only the active group owner can remove members'; end if;
 if p_target_character_id=v_conv.owner_character_id then raise exception 'Transfer ownership before leaving the group'; end if;
 update public.site_phone_members set left_at=now(),is_owner=false
 where conversation_id=p_conversation_id and character_id=p_target_character_id and left_at is null;
 get diagnostics v_count=row_count;
 if v_count=0 then raise exception 'Active group member not found'; end if;
 insert into public.site_phone_notifications(character_id,kind,actor_character_id,conversation_id,payload)
 values(p_target_character_id,'group_removed',p_character_id,p_conversation_id,jsonb_build_object('group_name',v_conv.group_name));
 return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.site_phone_group_transfer_owner(p_character_id text,p_conversation_id text,p_new_owner_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_conv public.site_phone_conversations%rowtype; v_target_member public.site_phone_members%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select * into v_conv from public.site_phone_conversations where id=p_conversation_id and kind='group' for update;
 if not found or v_conv.owner_character_id<>p_character_id or v_conv.is_closed then raise exception 'Only the active group owner can transfer ownership'; end if;
 select * into v_target_member from public.site_phone_members where conversation_id=p_conversation_id and character_id=p_new_owner_character_id and left_at is null for update;
 if not found then raise exception 'New owner must be an active group member'; end if;
 update public.site_phone_members set is_owner=(character_id=p_new_owner_character_id) where conversation_id=p_conversation_id and left_at is null;
 update public.site_phone_conversations set owner_character_id=p_new_owner_character_id,updated_at=now() where id=p_conversation_id;
 perform public.site_phone_notify(p_new_owner_character_id,'group_owner',p_character_id,p_conversation_id,null,null,jsonb_build_object('group_name',v_conv.group_name));
 return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.site_phone_group_leave(p_character_id text,p_conversation_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_conv public.site_phone_conversations%rowtype; v_member public.site_phone_members%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select * into v_conv from public.site_phone_conversations where id=p_conversation_id and kind='group' for update;
 if not found then raise exception 'Group not found'; end if;
 select * into v_member from public.site_phone_members where conversation_id=p_conversation_id and character_id=p_character_id and left_at is null;
 if not found then raise exception 'You are not an active member'; end if;
 if v_conv.owner_character_id=p_character_id then raise exception 'Transfer ownership before leaving the group'; end if;
 update public.site_phone_members set left_at=now(),is_owner=false where conversation_id=p_conversation_id and character_id=p_character_id;
 perform public.site_phone_notify(v_conv.owner_character_id,'group_left',p_character_id,p_conversation_id,null,null,jsonb_build_object('group_name',v_conv.group_name));
 return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.site_phone_group_close(p_character_id text,p_conversation_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_conv public.site_phone_conversations%rowtype; v_member record;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select * into v_conv from public.site_phone_conversations where id=p_conversation_id and kind='group' for update;
 if not found or v_conv.owner_character_id<>p_character_id then raise exception 'Only the group owner can archive this group'; end if;
 update public.site_phone_conversations set is_closed=true,closed_at=now(),updated_at=now() where id=p_conversation_id;
 for v_member in select character_id from public.site_phone_members where conversation_id=p_conversation_id and left_at is null and character_id<>p_character_id loop
  perform public.site_phone_notify(v_member.character_id,'group_archived',p_character_id,p_conversation_id,null,null,jsonb_build_object('group_name',v_conv.group_name));
 end loop;
 return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.site_phone_group_update(p_character_id text,p_conversation_id text,p_name text,p_description text default '',p_image_url text default '')
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_conv public.site_phone_conversations%rowtype; v_name text:=trim(coalesce(p_name,'')); v_image text:=trim(coalesce(p_image_url,''));
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select * into v_conv from public.site_phone_conversations where id=p_conversation_id and kind='group' for update;
 if not found or v_conv.owner_character_id<>p_character_id or v_conv.is_closed then raise exception 'Only the active group owner can edit group details'; end if;
 if char_length(v_name)<1 or char_length(v_name)>80 then raise exception 'Group name must be 1 to 80 characters'; end if;
 if char_length(coalesce(p_description,''))>500 then raise exception 'Group description is too long'; end if;
 if v_image<>'' and v_image !~* '^https?://[^[:space:]]+$' then raise exception 'Group image must be an HTTP or HTTPS URL'; end if;
 update public.site_phone_conversations set group_name=v_name,description=left(coalesce(p_description,''),500),image_url=v_image,updated_at=now()
 where id=p_conversation_id;
 return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.site_phone_group_toggle_preferences(p_character_id text,p_conversation_id text,p_muted boolean,p_mentions_enabled boolean)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_count integer;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 update public.site_phone_members set is_muted=coalesce(p_muted,false),mentions_enabled=coalesce(p_mentions_enabled,true)
 where conversation_id=p_conversation_id and character_id=p_character_id and left_at is null;
 get diagnostics v_count=row_count;
 if v_count=0 then raise exception 'Active conversation membership not found'; end if;
 return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.site_phone_transfer_item(
 p_character_id text,p_recipient_character_id text,p_item_id text,p_quantity integer,p_note text default '',p_request_id text default ''
)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare
 v_profile public.site_profiles%rowtype; v_sender jsonb; v_recipient jsonb; v_item jsonb; v_transfer public.site_phone_item_transfers%rowtype;
 v_sender_inv jsonb:='[]'::jsonb; v_recipient_inv jsonb; v_entry jsonb; v_moved jsonb:='[]'::jsonb; v_new_entry jsonb;
 v_remaining integer; v_now_ms bigint; v_item_name text; v_note text:=left(trim(coalesce(p_note,'')),160); v_transfer_id bigint;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 if p_quantity is null or p_quantity<1 or p_quantity>100 then raise exception 'Quantity must be between 1 and 100'; end if;
 if p_character_id=p_recipient_character_id then raise exception 'Choose a different recipient character'; end if;
 if coalesce(length(trim(p_request_id)),0)<8 or length(p_request_id)>100 then raise exception 'Transfer request id is invalid'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Sender character is not available'; end if;
 select * into v_transfer from public.site_phone_item_transfers where request_id=p_request_id;
 if found then
  if v_transfer.sender_character_id<>p_character_id or v_transfer.recipient_character_id<>p_recipient_character_id or v_transfer.item_id<>p_item_id or v_transfer.quantity<>p_quantity then raise exception 'Request identifier has already been used'; end if;
  return jsonb_build_object('ok',true,'duplicate',true,'transfer_id',v_transfer.id);
 end if;
 perform 1 from public.site_records where collection='characters' and record_id in (p_character_id,p_recipient_character_id) order by record_id for update;
 select payload into v_sender from public.site_records where collection='characters' and record_id=p_character_id;
 select payload into v_recipient from public.site_records where collection='characters' and record_id=p_recipient_character_id;
 if v_recipient is null or v_recipient->>'status'<>'approved' then raise exception 'Recipient character is not available'; end if;
 select payload into v_item from public.site_records where collection='items' and record_id=p_item_id for share;
 if v_item is null then raise exception 'Item not found'; end if;
 if coalesce((v_item->>'transferable')::boolean,true)=false then raise exception 'This item cannot be transferred'; end if;
 if public.site_phone_is_blocked_between(p_character_id,p_recipient_character_id) then raise exception 'This character is blocked'; end if;
 v_item_name:=coalesce(nullif(v_item->>'name',''),'Item');
 v_sender_inv:=coalesce(v_sender->'inv','[]'::jsonb); v_recipient_inv:=coalesce(v_recipient->'inv','[]'::jsonb); v_remaining:=p_quantity;
 for v_entry in select value from jsonb_array_elements(v_sender_inv) loop
  if v_remaining>0 and v_entry->>'iid'=p_item_id then
   v_moved:=v_moved||jsonb_build_array(v_entry);
   v_remaining:=v_remaining-1;
  end if;
 end loop;
 if v_remaining>0 then raise exception 'Not enough of this item in the sender inventory'; end if;
 -- Rebuild sender inventory after selecting the first requested matching instances.
 v_sender_inv:='[]'::jsonb; v_remaining:=p_quantity;
 for v_entry in select value from jsonb_array_elements(coalesce(v_sender->'inv','[]'::jsonb)) loop
  if v_remaining>0 and v_entry->>'iid'=p_item_id then
   v_remaining:=v_remaining-1;
  else
   v_sender_inv:=v_sender_inv||jsonb_build_array(v_entry);
  end if;
 end loop;
 v_now_ms:=floor(extract(epoch from clock_timestamp())*1000)::bigint;
 for v_entry in select value from jsonb_array_elements(v_moved) loop
  v_new_entry:=jsonb_set(v_entry,'{id}',to_jsonb(gen_random_uuid()::text),true);
  v_new_entry:=jsonb_set(v_new_entry,'{transferredAt}',to_jsonb(v_now_ms),true);
  v_recipient_inv:=v_recipient_inv||jsonb_build_array(v_new_entry);
 end loop;
 v_sender:=jsonb_set(v_sender,'{inv}',v_sender_inv,true);
 v_recipient:=jsonb_set(v_recipient,'{inv}',v_recipient_inv,true);
 update public.site_records set payload=v_sender,updated_at=now(),updated_by=auth.uid() where collection='characters' and record_id=p_character_id;
 update public.site_records set payload=v_recipient,updated_at=now(),updated_by=auth.uid() where collection='characters' and record_id=p_recipient_character_id;
 insert into public.site_phone_item_transfers(request_id,sender_character_id,recipient_character_id,item_id,quantity,item_name,note)
 values(p_request_id,p_character_id,p_recipient_character_id,p_item_id,p_quantity,v_item_name,v_note)
 returning id into v_transfer_id;
 perform public.site_phone_notify(p_character_id,'item_sent',p_recipient_character_id,null,null,v_transfer_id,jsonb_build_object('item_name',v_item_name,'quantity',p_quantity,'note',v_note));
 perform public.site_phone_notify(p_recipient_character_id,'item_received',p_character_id,null,null,v_transfer_id,jsonb_build_object('item_name',v_item_name,'quantity',p_quantity,'note',v_note));
 return jsonb_build_object('ok',true,'transfer_id',v_transfer_id,'item_name',v_item_name,'quantity',p_quantity);
end;
$$;

create or replace function public.site_phone_transfer_history(p_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select coalesce(jsonb_agg(q.data order by q.created_at desc),'[]'::jsonb)
 into v_result from (
  select t.created_at,jsonb_build_object(
   'id',t.id,'sender_character_id',t.sender_character_id,'recipient_character_id',t.recipient_character_id,
   'sender_name',coalesce(nullif(s.payload->>'stageName',''),nullif(s.payload->>'name',''),'ตัวละคร'),
   'recipient_name',coalesce(nullif(r.payload->>'stageName',''),nullif(r.payload->>'name',''),'ตัวละคร'),
   'item_id',t.item_id,'item_name',t.item_name,'quantity',t.quantity,'note',t.note,'created_at',t.created_at,
   'direction',case when t.sender_character_id=p_character_id then 'sent' else 'received' end
  ) as data
  from public.site_phone_item_transfers t
  left join public.site_records s on s.collection='characters' and s.record_id=t.sender_character_id
  left join public.site_records r on r.collection='characters' and r.record_id=t.recipient_character_id
  where t.sender_character_id=p_character_id or t.recipient_character_id=p_character_id
  order by t.created_at desc limit 50
 ) q;
 return v_result;
end;
$$;

create or replace function public.site_phone_admin_settings()
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_settings public.site_phone_settings%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not (v_profile.role='admin' or 'manage_economy'=any(coalesce(v_profile.permissions,'{}'::text[]))) then raise exception 'Phone administration permission required'; end if;
 select * into v_settings from public.site_phone_settings where singleton_id=true;
 return jsonb_build_object('max_group_members',v_settings.max_group_members,'unsend_fee',v_settings.unsend_fee);
end;
$$;

create or replace function public.site_phone_admin_update_settings(p_max_group_members integer,p_unsend_fee bigint)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not (v_profile.role='admin' or 'manage_economy'=any(coalesce(v_profile.permissions,'{}'::text[]))) then raise exception 'Phone administration permission required'; end if;
 if p_max_group_members not between 2 and 200 or p_unsend_fee not between 0 and 9000000000000000 then raise exception 'Phone settings are outside the allowed range'; end if;
 update public.site_phone_settings set max_group_members=p_max_group_members,unsend_fee=p_unsend_fee,updated_at=now(),updated_by=auth.uid() where singleton_id=true;
 insert into public.site_phone_audit(actor_app_user_id,action,target_type,target_id,detail)
 values(v_profile.app_user_id,'update_settings','phone_settings','singleton',jsonb_build_object('max_group_members',p_max_group_members,'unsend_fee',p_unsend_fee));
 return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.site_phone_admin_reports()
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not (v_profile.role='admin' or 'manage_posts'=any(coalesce(v_profile.permissions,'{}'::text[]))) then raise exception 'Report review permission required'; end if;
 -- The only admin message-content endpoint: messages are exposed only after a player reports them.
 select coalesce(jsonb_agg(jsonb_build_object(
  'report_id',r.id,'message_id',m.id,'reason',r.reason,'status',r.status,'reported_at',r.created_at,
  'reporter_character_id',r.reporter_character_id,'reporter_name',coalesce(nullif(rc.payload->>'stageName',''),nullif(rc.payload->>'name',''),'ตัวละคร'),
  'sender_character_id',m.sender_character_id,'sender_name',coalesce(nullif(sc.payload->>'stageName',''),nullif(sc.payload->>'name',''),'ตัวละคร'),
  'body',case when m.revoked_at is not null then 'ข้อความถูกยกเลิก' else m.body end,'image_url',case when m.revoked_at is not null then '' else m.image_url end,
  'conversation_id',m.conversation_id,'conversation_kind',c.kind,'conversation_name',c.group_name,
  'review_note',r.review_note
 ) order by r.created_at desc),'[]'::jsonb)
 into v_result
 from public.site_phone_reports r
 join public.site_phone_messages m on m.id=r.message_id
 join public.site_phone_conversations c on c.id=m.conversation_id
 left join public.site_records rc on rc.collection='characters' and rc.record_id=r.reporter_character_id
 left join public.site_records sc on sc.collection='characters' and sc.record_id=m.sender_character_id
 where r.status='pending';
 return v_result;
end;
$$;

create or replace function public.site_phone_admin_report_action(p_report_id bigint,p_action text,p_note text default '')
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_count integer;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not (v_profile.role='admin' or 'manage_posts'=any(coalesce(v_profile.permissions,'{}'::text[]))) then raise exception 'Report review permission required'; end if;
 if p_action not in ('reviewed','dismissed') then raise exception 'Invalid report action'; end if;
 update public.site_phone_reports set status=p_action,reviewed_by_app_user_id=v_profile.app_user_id,reviewed_at=now(),review_note=left(trim(coalesce(p_note,'')),800)
 where id=p_report_id and status='pending';
 get diagnostics v_count=row_count;
 if v_count=0 then raise exception 'Pending report not found'; end if;
 insert into public.site_phone_audit(actor_app_user_id,action,target_type,target_id,detail)
 values(v_profile.app_user_id,'review_report','phone_report',p_report_id::text,jsonb_build_object('action',p_action,'note',left(coalesce(p_note,''),800)));
 return jsonb_build_object('ok',true);
end;
$$;

alter table public.site_mail add column if not exists sender_character_id text;
-- Add email thread IDs so replies remain in one thread in each mailbox.
alter table public.site_mail add column if not exists thread_id text;
update public.site_mail set thread_id=id where thread_id is null or trim(thread_id)='';
alter table public.site_mail alter column thread_id set default gen_random_uuid()::text;
alter table public.site_mail alter column thread_id set not null;
create index if not exists site_mail_thread_sender_idx
 on public.site_mail(sender_app_user_id,thread_id,created_at);
create index if not exists site_mail_thread_recipient_idx
 on public.site_mail(recipient_app_user_id,thread_id,created_at);

-- Keep private mail compatible with character-level blocks: the active sender character is passed by the client.
-- Keep private mail compatible with character-level blocks and thread replies.
create or replace function public.site_mail_send(p_mail jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
 v_profile public.site_profiles%rowtype;
 v_id text:=trim(coalesce(p_mail->>'id',''));
 v_recipient_id text:=trim(coalesce(p_mail->>'recipientId',''));
 v_subject text:=trim(coalesce(p_mail->>'subject',''));
 v_body text:=trim(coalesce(p_mail->>'body',''));
 v_sender_character_id text:=trim(coalesce(p_mail->>'senderCharacterId',''));
 v_thread_id text:=coalesce(nullif(trim(coalesce(p_mail->>'threadId','')),''),v_id);
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found then raise exception 'Account profile has not been initialized'; end if;
 if v_id='' or char_length(v_id)>80 then raise exception 'Message ID is invalid'; end if;
 if v_thread_id='' or char_length(v_thread_id)>80 then raise exception 'Mail thread ID is invalid'; end if;
 if v_recipient_id='' then raise exception 'Recipient is required'; end if;
 if char_length(v_subject)<1 or char_length(v_subject)>120 then raise exception 'Subject must be between 1 and 120 characters'; end if;
 if char_length(v_body)<1 or char_length(v_body)>12000 then raise exception 'Message must be between 1 and 12000 characters'; end if;
 if v_recipient_id=v_profile.app_user_id then raise exception 'Cannot send a message to yourself'; end if;
 if not exists(select 1 from public.site_profiles where app_user_id=v_recipient_id) then raise exception 'Recipient account does not exist'; end if;
 if v_sender_character_id<>'' then
  if not public.site_phone_character_owned(v_sender_character_id,v_profile.app_user_id) then raise exception 'Sender character is not available'; end if;
  if exists(
   select 1 from public.site_phone_blocks b
   where (b.owner_character_id=v_sender_character_id and b.blocked_character_id in (
     select r.record_id from public.site_records r where r.collection='characters' and r.payload->>'ownerId'=v_recipient_id and r.payload->>'status'='approved'
   ))
   or (b.blocked_character_id=v_sender_character_id and b.owner_character_id in (
     select r.record_id from public.site_records r where r.collection='characters' and r.payload->>'ownerId'=v_recipient_id and r.payload->>'status'='approved'
   ))
  ) then raise exception 'This character is blocked for mail'; end if;
 end if;
 insert into public.site_mail(id,thread_id,sender_character_id,sender_app_user_id,recipient_app_user_id,subject,body)
 values(v_id,v_thread_id,nullif(v_sender_character_id,''),v_profile.app_user_id,v_recipient_id,v_subject,v_body);
 return jsonb_build_object('ok',true,'id',v_id,'threadId',v_thread_id);
end;
$$;

create or replace function public.site_mail_list(p_folder text default 'inbox')
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
 v_profile public.site_profiles%rowtype;
 v_messages jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 if p_folder not in ('inbox','sent') then raise exception 'Folder must be inbox or sent'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found then raise exception 'Account profile has not been initialized'; end if;
 select coalesce(jsonb_agg(q.message order by q.created_at desc),'[]'::jsonb)
 into v_messages
 from (
  select m.created_at,
   jsonb_build_object(
    'id',m.id,
    'threadId',coalesce(m.thread_id,m.id),
    'senderCharacterId',m.sender_character_id,
    'senderId',m.sender_app_user_id,
    'senderUsername',s.username,
    'recipientId',m.recipient_app_user_id,
    'recipientUsername',r.username,
    'subject',m.subject,
    'body',m.body,
    'createdAt',floor(extract(epoch from m.created_at)*1000)::bigint,
    'readAt',case when m.read_at is null then null else floor(extract(epoch from m.read_at)*1000)::bigint end
   ) as message
  from public.site_mail m
  join public.site_profiles s on s.app_user_id=m.sender_app_user_id
  join public.site_profiles r on r.app_user_id=m.recipient_app_user_id
  where (p_folder='inbox' and m.recipient_app_user_id=v_profile.app_user_id and not m.recipient_deleted)
     or (p_folder='sent' and m.sender_app_user_id=v_profile.app_user_id and not m.sender_deleted)
 ) q;
 return v_messages;
end;
$$;



-- Bank and email events create notification metadata only; no private message body is exposed.
create or replace function public.site_phone_notify_bank_transaction()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
 v_sender_account text;
 v_recipient_account text;
begin
 if new.kind='deposit' and new.recipient_character_id is not null then
  insert into public.site_phone_notifications(character_id,kind,actor_character_id,transfer_id,payload)
  values(new.recipient_character_id,'bank_deposit',null,new.id,
   jsonb_build_object('amount',new.amount,'fee',new.fee,'account_number',(select account_number from public.site_bank_accounts where id=new.destination_account_id)));
 elsif new.kind='withdraw' and new.sender_character_id is not null then
  insert into public.site_phone_notifications(character_id,kind,actor_character_id,transfer_id,payload)
  values(new.sender_character_id,'bank_withdraw',null,new.id,
   jsonb_build_object('amount',new.amount,'fee',new.fee,'account_number',(select account_number from public.site_bank_accounts where id=new.source_account_id)));
 elsif new.kind='transfer' then
  select account_number into v_sender_account from public.site_bank_accounts where id=new.source_account_id;
  select account_number into v_recipient_account from public.site_bank_accounts where id=new.destination_account_id;
  if new.sender_character_id is not null then
   insert into public.site_phone_notifications(character_id,kind,actor_character_id,transfer_id,payload)
   values(new.sender_character_id,'bank_transfer_sent',new.recipient_character_id,new.id,
    jsonb_build_object('amount',new.amount,'fee',new.fee,'account_number',v_recipient_account));
  end if;
  if new.recipient_character_id is not null then
   insert into public.site_phone_notifications(character_id,kind,actor_character_id,transfer_id,payload)
   values(new.recipient_character_id,'bank_transfer_received',new.sender_character_id,new.id,
    jsonb_build_object('amount',new.amount,'fee',new.fee,'account_number',v_sender_account));
  end if;
 end if;
 return new;
end;
$$;

drop trigger if exists site_phone_bank_transaction_notify on public.site_bank_transactions;
create trigger site_phone_bank_transaction_notify
 after insert on public.site_bank_transactions
 for each row execute function public.site_phone_notify_bank_transaction();

create or replace function public.site_phone_notify_new_mail()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare v_char record;
begin
 for v_char in
  select r.record_id
  from public.site_records r
  where r.collection='characters'
    and r.payload->>'ownerId'=new.recipient_app_user_id
    and r.payload->>'status'='approved'
 loop
  insert into public.site_phone_notifications(character_id,kind,actor_character_id,payload)
  values(v_char.record_id,'mail_received',new.sender_character_id,
   jsonb_build_object('subject',new.subject,'thread_id',coalesce(new.thread_id,new.id)));
 end loop;
 return new;
end;
$$;

drop trigger if exists site_phone_mail_notify on public.site_mail;
create trigger site_phone_mail_notify
 after insert on public.site_mail
 for each row execute function public.site_phone_notify_new_mail();

revoke all on function public.site_phone_notify_bank_transaction() from public,anon,authenticated;
revoke all on function public.site_phone_notify_new_mail() from public,anon,authenticated;

-- Explicit RPC grants: users cannot read or edit communication tables directly.
revoke all on function public.site_phone_character_owned(text,text) from public,anon,authenticated;
revoke all on function public.site_phone_is_blocked_between(text,text) from public,anon,authenticated;
revoke all on function public.site_phone_notify(text,text,text,text,text,bigint,jsonb) from public,anon,authenticated;
revoke all on function public.site_phone_touch_presence(text) from public,anon;
revoke all on function public.site_phone_set_privacy(text,boolean,boolean) from public,anon;
revoke all on function public.site_phone_presence_for_characters(text) from public,anon;
revoke all on function public.site_phone_open_dm(text,text) from public,anon;
revoke all on function public.site_phone_list_conversations(text) from public,anon;
revoke all on function public.site_phone_get_messages(text,text,integer) from public,anon;
revoke all on function public.site_phone_send_message(text,text,text,text,text) from public,anon;
revoke all on function public.site_phone_mark_read(text,text) from public,anon;
revoke all on function public.site_phone_message_readers(text,text) from public,anon;
revoke all on function public.site_phone_hide_message(text,text) from public,anon;
revoke all on function public.site_phone_unsend_message(text,text) from public,anon;
revoke all on function public.site_phone_report_message(text,text,text) from public,anon;
revoke all on function public.site_phone_list_contacts(text) from public,anon;
revoke all on function public.site_phone_add_contact(text,text,text) from public,anon;
revoke all on function public.site_phone_contact_update(text,text,boolean,text) from public,anon;
revoke all on function public.site_phone_remove_contact(text,text) from public,anon;
revoke all on function public.site_phone_list_blocks(text) from public,anon;
revoke all on function public.site_phone_block(text,text) from public,anon;
revoke all on function public.site_phone_unblock(text,text) from public,anon;
revoke all on function public.site_phone_list_notifications(text) from public,anon;
revoke all on function public.site_phone_mark_notification_read(text,bigint) from public,anon;
revoke all on function public.site_phone_mark_all_notifications_read(text) from public,anon;
revoke all on function public.site_phone_create_group(text,text,text,text) from public,anon;
revoke all on function public.site_phone_group_invite(text,text,text) from public,anon;
revoke all on function public.site_phone_list_invites(text) from public,anon;
revoke all on function public.site_phone_group_invite_response(text,text,boolean) from public,anon;
revoke all on function public.site_phone_group_remove_member(text,text,text) from public,anon;
revoke all on function public.site_phone_group_transfer_owner(text,text,text) from public,anon;
revoke all on function public.site_phone_group_leave(text,text) from public,anon;
revoke all on function public.site_phone_group_close(text,text) from public,anon;
revoke all on function public.site_phone_group_update(text,text,text,text,text) from public,anon;
revoke all on function public.site_phone_group_toggle_preferences(text,text,boolean,boolean) from public,anon;
revoke all on function public.site_phone_transfer_item(text,text,text,integer,text,text) from public,anon;
revoke all on function public.site_phone_transfer_history(text) from public,anon;
revoke all on function public.site_phone_admin_settings() from public,anon;
revoke all on function public.site_phone_admin_update_settings(integer,bigint) from public,anon;
revoke all on function public.site_phone_admin_reports() from public,anon;
revoke all on function public.site_phone_admin_report_action(bigint,text,text) from public,anon;

grant execute on function public.site_phone_touch_presence(text) to authenticated;
grant execute on function public.site_phone_set_privacy(text,boolean,boolean) to authenticated;
grant execute on function public.site_phone_presence_for_characters(text) to authenticated;
grant execute on function public.site_phone_open_dm(text,text) to authenticated;
grant execute on function public.site_phone_list_conversations(text) to authenticated;
grant execute on function public.site_phone_get_messages(text,text,integer) to authenticated;
grant execute on function public.site_phone_send_message(text,text,text,text,text) to authenticated;
grant execute on function public.site_phone_mark_read(text,text) to authenticated;
grant execute on function public.site_phone_message_readers(text,text) to authenticated;
grant execute on function public.site_phone_hide_message(text,text) to authenticated;
grant execute on function public.site_phone_unsend_message(text,text) to authenticated;
grant execute on function public.site_phone_report_message(text,text,text) to authenticated;
grant execute on function public.site_phone_list_contacts(text) to authenticated;
grant execute on function public.site_phone_add_contact(text,text,text) to authenticated;
grant execute on function public.site_phone_contact_update(text,text,boolean,text) to authenticated;
grant execute on function public.site_phone_remove_contact(text,text) to authenticated;
grant execute on function public.site_phone_list_blocks(text) to authenticated;
grant execute on function public.site_phone_block(text,text) to authenticated;
grant execute on function public.site_phone_unblock(text,text) to authenticated;
grant execute on function public.site_phone_list_notifications(text) to authenticated;
grant execute on function public.site_phone_mark_notification_read(text,bigint) to authenticated;
grant execute on function public.site_phone_mark_all_notifications_read(text) to authenticated;
grant execute on function public.site_phone_create_group(text,text,text,text) to authenticated;
grant execute on function public.site_phone_group_invite(text,text,text) to authenticated;
grant execute on function public.site_phone_list_invites(text) to authenticated;
grant execute on function public.site_phone_group_invite_response(text,text,boolean) to authenticated;
grant execute on function public.site_phone_group_remove_member(text,text,text) to authenticated;
grant execute on function public.site_phone_group_transfer_owner(text,text,text) to authenticated;
grant execute on function public.site_phone_group_leave(text,text) to authenticated;
grant execute on function public.site_phone_group_close(text,text) to authenticated;
grant execute on function public.site_phone_group_update(text,text,text,text,text) to authenticated;
grant execute on function public.site_phone_group_toggle_preferences(text,text,boolean,boolean) to authenticated;
grant execute on function public.site_phone_transfer_item(text,text,text,integer,text,text) to authenticated;
grant execute on function public.site_phone_transfer_history(text) to authenticated;
grant execute on function public.site_phone_admin_settings() to authenticated;
grant execute on function public.site_phone_admin_update_settings(integer,bigint) to authenticated;
grant execute on function public.site_phone_admin_reports() to authenticated;
grant execute on function public.site_phone_admin_report_action(bigint,text,text) to authenticated;
revoke all on function public.site_mail_send(jsonb) from public,anon;
grant execute on function public.site_mail_send(jsonb) to authenticated;


create or replace function public.site_phone_group_members(p_character_id text,p_conversation_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 if not exists(select 1 from public.site_phone_members where conversation_id=p_conversation_id and character_id=p_character_id) then raise exception 'Conversation is not available'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'character_id',m.character_id,
  'name',coalesce(nullif(r.payload->>'stageName',''),nullif(r.payload->>'name',''),'ตัวละคร'),
  'avatar',coalesce(r.payload->>'avatar',''),
  'is_owner',m.is_owner,'joined_at',m.joined_at,'left_at',m.left_at,
  'is_me',m.character_id=p_character_id
 ) order by m.is_owner desc,m.left_at nulls first,m.joined_at),'[]'::jsonb)
 into v_result from public.site_phone_members m
 left join public.site_records r on r.collection='characters' and r.record_id=m.character_id
 where m.conversation_id=p_conversation_id;
 return v_result;
end;
$$;

create or replace function public.site_phone_group_pin_message(p_character_id text,p_conversation_id text,p_message_id text default null)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_conv public.site_phone_conversations%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select * into v_conv from public.site_phone_conversations where id=p_conversation_id and kind='group' for update;
 if not found or v_conv.owner_character_id<>p_character_id or v_conv.is_closed then raise exception 'Only the active group owner can pin messages'; end if;
 if p_message_id is not null and not exists(select 1 from public.site_phone_messages where id=p_message_id and conversation_id=p_conversation_id) then raise exception 'Message does not belong to this group'; end if;
 update public.site_phone_conversations set pinned_message_id=p_message_id,updated_at=now() where id=p_conversation_id;
 if p_message_id is not null then
  insert into public.site_phone_audit(actor_app_user_id,actor_character_id,action,target_type,target_id,detail)
  values(v_profile.app_user_id,p_character_id,'pin_message','phone_message',p_message_id,jsonb_build_object('conversation_id',p_conversation_id));
 end if;
 return jsonb_build_object('ok',true,'pinned_message_id',p_message_id);
end;
$$;



create or replace function public.site_phone_get_privacy(p_character_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_settings public.site_phone_presence%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select * into v_settings from public.site_phone_presence where character_id=p_character_id;
 return jsonb_build_object('hide_presence',coalesce(v_settings.hide_presence,false),'hide_last_seen',coalesce(v_settings.hide_last_seen,false));
end;
$$;

create or replace function public.site_phone_group_cancel_invite(p_character_id text,p_invite_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_inv public.site_phone_group_invites%rowtype; v_conv public.site_phone_conversations%rowtype; v_count integer;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select * into v_inv from public.site_phone_group_invites where id=p_invite_id and invited_by_character_id=p_character_id and status='pending' for update;
 if not found then raise exception 'Pending invitation not found'; end if;
 select * into v_conv from public.site_phone_conversations where id=v_inv.conversation_id;
 if not found or v_conv.owner_character_id<>p_character_id then raise exception 'Only the current group owner can cancel an invitation'; end if;
 update public.site_phone_group_invites set status='canceled',responded_at=now() where id=p_invite_id and status='pending';
 get diagnostics v_count=row_count;
 return jsonb_build_object('ok',v_count>0);
end;
$$;

revoke all on function public.site_phone_group_cancel_invite(text,text) from public,anon;
grant execute on function public.site_phone_group_cancel_invite(text,text) to authenticated;
revoke all on function public.site_phone_get_privacy(text) from public,anon;
grant execute on function public.site_phone_get_privacy(text) to authenticated;


create or replace function public.site_phone_group_sent_invites(p_character_id text,p_conversation_id text)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_conv public.site_phone_conversations%rowtype; v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not public.site_phone_character_owned(p_character_id,v_profile.app_user_id) then raise exception 'Character is not available'; end if;
 select * into v_conv from public.site_phone_conversations where id=p_conversation_id and kind='group';
 if not found or v_conv.owner_character_id<>p_character_id then raise exception 'Only the group owner can view pending invitations'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',i.id,'invited_character_id',i.invited_character_id,
   'name',coalesce(nullif(r.payload->>'stageName',''),nullif(r.payload->>'name',''),'ตัวละคร'),
   'status',i.status,'created_at',i.created_at
 ) order by i.created_at desc),'[]'::jsonb) into v_result
 from public.site_phone_group_invites i
 left join public.site_records r on r.collection='characters' and r.record_id=i.invited_character_id
 where i.conversation_id=p_conversation_id and i.status='pending';
 return v_result;
end;
$$;

revoke all on function public.site_phone_group_members(text,text) from public,anon;
grant execute on function public.site_phone_group_members(text,text) to authenticated;
revoke all on function public.site_phone_group_pin_message(text,text,text) from public,anon;
grant execute on function public.site_phone_group_pin_message(text,text,text) to authenticated;

revoke all on function public.site_phone_group_sent_invites(text,text) from public,anon;
grant execute on function public.site_phone_group_sent_invites(text,text) to authenticated;
notify pgrst,'reload schema';
commit;
