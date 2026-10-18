-- STARLIGHT RP: phone banking core
-- Run in Supabase SQL Editor for an existing installation.
-- Cash remains in characters.won. Only these RPCs may move cash to/from bank balances.

begin;

-- Keep the retired cash-to-cash RPC disabled on existing installations too.
drop function if exists public.site_transfer(text, text, integer, text);

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
    'character_id',candidates.character_id,
    'account_number',candidates.account_number,
    'display_name',candidates.display_name
  ) order by candidates.display_name), '[]'::jsonb)
  into v_results
  from (
    select
      ba.character_id,
      ba.account_number,
      coalesce(nullif(cr.payload ->> 'stageName',''),nullif(cr.payload ->> 'name',''),ba.character_id) as display_name
    from public.site_bank_accounts ba
    join public.site_records cr
      on cr.collection='characters' and cr.record_id=ba.character_id
    where ba.character_id<>p_character_id
      and cr.payload ->> 'status'='approved'
      and (
        ba.account_number=v_query
        or (
          length(v_query)>=2
          and position(lower(v_query) in lower(coalesce(nullif(cr.payload ->> 'stageName',''),nullif(cr.payload ->> 'name',''),ba.character_id)))>0
        )
      )
    order by display_name
    limit 10
  ) candidates;

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
    if v_tx.actor_app_user_id<>v_profile.app_user_id or v_tx.kind<>'deposit' or v_tx.recipient_character_id<>p_character_id or v_tx.amount<>p_amount then
      raise exception 'Request identifier has already been used for a different request';
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
    if v_tx.actor_app_user_id<>v_profile.app_user_id or v_tx.kind<>'withdraw' or v_tx.sender_character_id<>p_character_id or v_tx.amount<>p_amount then
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
       or v_tx.sender_character_id<>p_character_id or v_tx.recipient_character_id<>p_recipient_character_id or v_tx.amount<>p_amount or coalesce(v_tx.note,'') is distinct from v_note then
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
    raise exception using message = 'Each fee must be between zero and one hundred percent';
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


create or replace function public.site_bank_fee_info()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.site_profiles%rowtype;
  v_settings public.site_bank_settings%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
  if not found then raise exception 'Account profile has not been initialized'; end if;
  select * into v_settings from public.site_bank_settings where singleton_id=true;
  return jsonb_build_object(
    'deposit_fee_bps',coalesce(v_settings.deposit_fee_bps,0),
    'withdrawal_fee_bps',coalesce(v_settings.withdrawal_fee_bps,0),
    'transfer_fee_bps',coalesce(v_settings.transfer_fee_bps,0)
  );
end;
$$;

revoke all on function public.site_bank_fee_info() from public, anon;
grant execute on function public.site_bank_fee_info() to authenticated;

notify pgrst, 'reload schema';

commit;
