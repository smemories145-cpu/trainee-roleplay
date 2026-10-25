-- Additive STARLIGHT hospital, illness, and roleplay-training safeguards.

begin;

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
  v_forum jsonb;
  v_previous_post jsonb;
  v_hospital_kind text;
  v_hospital_words integer := 0;
  v_practice_date text;
  v_practice_counts jsonb;
  v_total_practice integer := 0;
  v_training_count integer := 0;
  v_training_warning boolean := false;
  v_became_sick boolean := false;
  v_consecutive_warning boolean := false;
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
 
  select payload into v_forum from public.site_records where collection='forums' and record_id=coalesce(v_thread ->> 'forumId','');
  if coalesce(v_forum ->> 'name','') ilike '%โรงพยาบาล%' then
    if coalesce(v_thread ->> 'title','') ~ 'แผนกต้อนรับ|แผนกรักษาทั่วไป' then v_hospital_kind := 'queue';
    elsif coalesce(v_thread ->> 'title','') ~ 'ห้องตรวจหมายเลข[[:space:]]*[1-3]' then v_hospital_kind := 'treatment';
    end if;
  end if;

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
 
  if coalesce((v_char ->> 'sick')::boolean,false) and v_hospital_kind is null then
    raise exception 'Character is sick and can only act in hospital threads';
  end if;
  if v_hospital_kind is not null then
    v_hospital_words := coalesce((p_post ->> 'hospitalWordCount')::integer,0);
    if v_hospital_words <= 70 then raise exception 'Hospital roleplay must contain more than 70 words'; end if;
    if v_hospital_kind='queue' and position('รับบัตรคิว' in coalesce(p_post ->> 'note',''))=0 then
      raise exception 'Hospital reception post must include the note รับบัตรคิว';
    elsif v_hospital_kind='treatment' and position('รับการรักษา' in coalesce(p_post ->> 'note',''))=0 then
      raise exception 'Hospital examination post must include the note รับการรักษา';
    end if;
  end if;

  v_content_len := length(btrim(regexp_replace(coalesce(p_post ->> 'content',''), '<[^>]*>', ' ', 'g')));
  if v_content_len < 50 then raise exception 'Post must contain at least 50 characters'; end if;

  v_exp := greatest(0,coalesce((v_thread ->> 'exp')::numeric,0));
  v_won := greatest(0,coalesce((v_thread ->> 'won')::numeric,0));
  v_now_ms := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;

  if coalesce((v_thread ->> 'consecutivePostWarning')::boolean,false) then
    select payload into v_previous_post from public.site_records where collection='posts' and payload ->> 'threadId'=v_tid order by updated_at desc limit 1;
    if v_previous_post is not null and v_previous_post ->> 'charId'=v_cid and not coalesce((v_previous_post ->> 'gm')::boolean,false) then
      v_consecutive_warning := true;
      if not coalesce((v_char ->> 'sick')::boolean,false) then
        v_char := jsonb_set(v_char,'{illnessOriginalStage}',to_jsonb(coalesce((v_char ->> 'stage')::integer,0)),true);
        v_char := jsonb_set(v_char,'{sick}',to_jsonb(true),true);
        v_char := jsonb_set(v_char,'{sickSince}',to_jsonb(v_now_ms),true);
        v_char := jsonb_set(v_char,'{sickReason}',to_jsonb('โพสต์ติดกันในกระทู้โรลเพลย์'),true);
        v_became_sick := true;
      end if;
    end if;
  end if;
  if coalesce((v_thread ->> 'illnessTrigger')::boolean,false) and not coalesce((v_char ->> 'sick')::boolean,false) then
    v_char := jsonb_set(v_char,'{illnessOriginalStage}',to_jsonb(coalesce((v_char ->> 'stage')::integer,0)),true);
    v_char := jsonb_set(v_char,'{sick}',to_jsonb(true),true);
    v_char := jsonb_set(v_char,'{sickSince}',to_jsonb(v_now_ms),true);
    v_char := jsonb_set(v_char,'{sickReason}',to_jsonb('กิจกรรม: '||coalesce(v_thread ->> 'title','กิจกรรม')),true);
    v_became_sick := true;
  end if;
  v_char := jsonb_set(v_char,'{exp}',to_jsonb(coalesce((v_char ->> 'exp')::numeric,0)+v_exp),true);
  v_char := jsonb_set(v_char,'{won}',to_jsonb(coalesce((v_char ->> 'won')::numeric,0)+v_won),true);
  v_ledger := coalesce(v_char -> 'ledger','[]'::jsonb);
  v_ledger := jsonb_build_array(jsonb_build_object('at',v_now_ms,'amt',v_won,'note','โพสต์: '||coalesce(v_thread ->> 'title','กระทู้'))) || v_ledger;
  v_char := jsonb_set(v_char,'{ledger}',(select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) from jsonb_array_elements(v_ledger) with ordinality where ordinality<=30),true);

  v_stat_gain := greatest(0,coalesce((v_thread ->> 'statGain')::integer,0));
  if p_train is not null and coalesce(v_thread -> 'train','[]'::jsonb) ? p_train then
    if coalesce((v_char ->> 'sick')::boolean,false) then raise exception 'Sick characters cannot train'; end if;
    v_practice_date := to_char(timezone('Asia/Bangkok',clock_timestamp()),'YYYY-MM-DD');
    v_practice_counts := coalesce(v_char -> 'practiceCounts' -> 'counts','{}'::jsonb);
    if (v_char -> 'practiceCounts' ->> 'date') is distinct from v_practice_date then v_practice_counts := '{}'::jsonb; end if;
    select coalesce(sum(greatest(0,value::integer)),0) into v_total_practice from jsonb_each_text(v_practice_counts);
    if v_total_practice >= 10 then raise exception 'Daily roleplay training limit reached'; end if;
    v_training_count := v_total_practice + 1;
    v_practice_counts := jsonb_set(v_practice_counts,ARRAY[p_train],to_jsonb(coalesce((v_practice_counts ->> p_train)::integer,0)+1),true);
    v_char := jsonb_set(v_char,'{practiceCounts}',jsonb_build_object('date',v_practice_date,'counts',v_practice_counts),true);
    v_training_warning := v_training_count=10;
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
       'gain',v_new_stat-v_old_stat,'wonGain',v_won,'createdAt',coalesce((p_post ->> 'createdAt')::numeric,v_now_ms),
       'becameSick',v_became_sick,'consecutivePostWarning',v_consecutive_warning,'trainingWarning',v_training_warning,'trainingCount',v_training_count);
  insert into public.site_records(collection,record_id,payload,updated_at,updated_by)
  values ('posts',v_id,v_post,now(),auth.uid());
  update public.site_records set payload=v_char,updated_at=now(),updated_by=auth.uid()
    where collection='characters' and record_id=v_cid;

  return jsonb_build_object('ok',true,'post',v_post,'character',v_char,'gain',v_new_stat-v_old_stat,
    'becameSick',v_became_sick,'consecutivePostWarning',v_consecutive_warning,'trainingWarning',v_training_warning,'trainingCount',v_training_count);
end;
$$;

create or replace function public.site_practice(p_character_id text,p_stat text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin
 raise exception 'Practice must be recorded through roleplay posts in eligible threads';
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
  if coalesce((v_char ->> 'sick')::boolean,false) then raise exception 'Sick characters cannot claim salary'; end if;
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
  if coalesce((v_char ->> 'sick')::boolean,false) then raise exception 'Sick characters cannot shop'; end if;
 if v_item is null then raise exception 'Item not found'; end if;
 if p_item_id='starlight_medicine_bottle' or coalesce((v_item ->> 'hospitalOnly')::boolean,false) then raise exception 'This medicine is issued only by the hospital'; end if;
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
  if coalesce((v_char ->> 'sick')::boolean,false) then raise exception 'Sick characters cannot deposit money'; end if;
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
  if coalesce((v_char ->> 'sick')::boolean,false) then raise exception 'Sick characters cannot withdraw money'; end if;
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
  if coalesce((v_sender_char ->> 'sick')::boolean,false) then raise exception 'Sick characters cannot transfer money'; end if;
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


-- Additive hospital tables and RPCs; never reset or delete player records.
create table if not exists public.site_hospital_treatments (
 id bigint generated always as identity primary key,
 character_id text not null,
 queue_post_id text not null unique,
 treatment_post_id text,
 room_number integer not null check (room_number between 1 and 3),
 room_thread_id text not null,
 doctor_name text not null,
 status text not null default 'queued' check (status in ('queued','awaiting_payment','paid_medicine_received','medicine_expired','cured','cancelled')),
 payment_method text check (payment_method in ('cash','bank')),
 payment_request_id text unique,
 paid_at timestamptz,
 medicine_received_at timestamptz,
 medicine_expires_at timestamptz,
 medicine_inventory_item_id text,
 medicine_used_at timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index if not exists site_hospital_treatments_character_idx on public.site_hospital_treatments(character_id,created_at desc);
create index if not exists site_hospital_treatments_room_idx on public.site_hospital_treatments(room_number,status,created_at);
create unique index if not exists site_hospital_one_active_treatment_per_character on public.site_hospital_treatments(character_id) where status in ('queued','awaiting_payment','paid_medicine_received');
alter table public.site_hospital_treatments enable row level security;

insert into public.site_records(collection,record_id,payload,updated_at)
values('items','starlight_medicine_bottle',jsonb_build_object(
 'id','starlight_medicine_bottle','name','ขวดยา STARLIGHT MEDICAL CENTER',
 'cat','ยาและเวชภัณฑ์','price',0,'img','starlight_medicine_bottle.svg',
 'desc','ยาที่ได้รับจากโรงพยาบาล ใช้ได้ 1 ครั้งภายใน 3 ชั่วโมงหลังรับยา หากหมดอายุต้องพบแพทย์เพื่อรับยาใหม่',
 'stock',0,'hiddenFromShop',true,'hospitalOnly',true,'transferable',false
),now())
on conflict(collection,record_id) do update set payload=public.site_records.payload||excluded.payload,updated_at=now();

create or replace function public.site_hospital_submit_queue(p_character_id text,p_post_id text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp
as $$
declare
 v_profile public.site_profiles%rowtype; v_char jsonb; v_post jsonb; v_thread jsonb; v_forum jsonb;
 v_active public.site_hospital_treatments%rowtype; v_room_number integer; v_room_thread_id text; v_doctor text; v_inv jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found then raise exception 'Account profile has not been initialized'; end if;
 select payload into v_char from public.site_records where collection='characters' and record_id=p_character_id for update;
 if v_char is null or v_char ->> 'ownerId' is distinct from v_profile.app_user_id or v_char ->> 'status' is distinct from 'approved' then raise exception 'Character is not available'; end if;
 if not coalesce((v_char ->> 'sick')::boolean,false) then raise exception 'Character is not sick and does not need a hospital queue'; end if;
 select * into v_active from public.site_hospital_treatments where character_id=p_character_id and status in ('queued','awaiting_payment','paid_medicine_received') order by id desc limit 1 for update;
 if found then
  if v_active.status='paid_medicine_received' and v_active.medicine_expires_at<=now() then
   select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) into v_inv from jsonb_array_elements(coalesce(v_char -> 'inv','[]'::jsonb)) with ordinality where value ->> 'id' is distinct from v_active.medicine_inventory_item_id;
   v_char:=jsonb_set(v_char,'{inv}',v_inv,true);
   update public.site_records set payload=v_char,updated_at=now(),updated_by=auth.uid() where collection='characters' and record_id=p_character_id;
   update public.site_hospital_treatments set status='medicine_expired',updated_at=now() where id=v_active.id;
  else
   if v_active.status='queued' then return jsonb_build_object('ok',true,'already_queued',true,'room_number',v_active.room_number,'doctor_name',v_active.doctor_name); end if;
   raise exception 'A hospital treatment is already in progress. Use the medicine or wait for expiry';
  end if;
 end if;
 select payload into v_post from public.site_records where collection='posts' and record_id=p_post_id;
 if v_post is null or v_post ->> 'charId' is distinct from p_character_id or v_post ->> 'userId' is distinct from v_profile.app_user_id then raise exception 'Queue post does not belong to this character'; end if;
 if position('รับบัตรคิว' in coalesce(v_post ->> 'note',''))=0 then raise exception 'Queue post note must include รับบัตรคิว'; end if;
 if coalesce((v_post ->> 'hospitalWordCount')::integer,0)<=70 then raise exception 'Queue roleplay must contain more than 70 words'; end if;
 select payload into v_thread from public.site_records where collection='threads' and record_id=v_post ->> 'threadId';
 if v_thread is null or coalesce(v_thread ->> 'title','') !~ 'แผนกต้อนรับ|แผนกรักษาทั่วไป' then raise exception 'Queue must be posted in the hospital reception thread'; end if;
 select payload into v_forum from public.site_records where collection='forums' and record_id=v_thread ->> 'forumId';
 if coalesce(v_forum ->> 'name','') not ilike '%โรงพยาบาล%' then raise exception 'Queue thread is not inside the hospital forum'; end if;
 select candidate.room_number,candidate.room_thread_id,candidate.doctor_name into v_room_number,v_room_thread_id,v_doctor
 from (
   select (substring(payload ->> 'title' from 'ห้องตรวจหมายเลข[[:space:]]*([1-3])'))::integer room_number,record_id room_thread_id,
    case substring(payload ->> 'title' from 'ห้องตรวจหมายเลข[[:space:]]*([1-3])') when '1' then 'คุณหมอลี' when '2' then 'คุณหมอจาง' else 'คุณหมอชิม' end doctor_name
   from public.site_records where collection='threads' and payload ->> 'forumId'=v_thread ->> 'forumId'
    and coalesce(payload ->> 'title','') ~ 'ห้องตรวจหมายเลข[[:space:]]*[1-3]' and coalesce(payload ->> 'status','open')<>'deleted'
 ) candidate
 order by (select count(*) from public.site_hospital_treatments h where h.room_number=candidate.room_number and h.status='queued'),candidate.room_number limit 1;
 if v_room_number is null or v_room_thread_id is null then raise exception 'Hospital examination rooms are not configured'; end if;
 insert into public.site_hospital_treatments(character_id,queue_post_id,room_number,room_thread_id,doctor_name,status)
 values(p_character_id,p_post_id,v_room_number,v_room_thread_id,v_doctor,'queued') returning * into v_active;
 return jsonb_build_object('ok',true,'treatment_id',v_active.id,'room_number',v_room_number,'doctor_name',v_doctor,'room_thread_id',v_room_thread_id);
end; $$;

create or replace function public.site_hospital_pay(p_character_id text,p_treatment_post_id text,p_payment_method text,p_request_id text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp
as $$
declare
 v_profile public.site_profiles%rowtype; v_char jsonb; v_post jsonb; v_thread jsonb; v_forum jsonb;
 v_treatment public.site_hospital_treatments%rowtype; v_bank public.site_bank_accounts%rowtype;
 v_now_ms bigint; v_expiry timestamptz; v_inventory_id text; v_inv jsonb; v_ledger jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 if p_payment_method not in ('cash','bank') then raise exception 'Invalid hospital payment method'; end if;
 if coalesce(length(trim(p_request_id)),0)<8 or length(p_request_id)>100 then raise exception 'Invalid request identifier'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found then raise exception 'Account profile has not been initialized'; end if;
 select * into v_treatment from public.site_hospital_treatments where character_id=p_character_id and treatment_post_id=p_treatment_post_id order by id desc limit 1 for update;
 if found and v_treatment.status in ('paid_medicine_received','cured') then return jsonb_build_object('ok',true,'already_paid',true,'medicine_expires_at',v_treatment.medicine_expires_at); end if;
 select * into v_treatment from public.site_hospital_treatments where character_id=p_character_id and status='queued' order by id desc limit 1 for update;
 if not found then raise exception 'No active hospital queue for this character'; end if;
 select payload into v_char from public.site_records where collection='characters' and record_id=p_character_id for update;
 if v_char is null or v_char ->> 'ownerId' is distinct from v_profile.app_user_id or v_char ->> 'status' is distinct from 'approved' then raise exception 'Character is not available'; end if;
 if not coalesce((v_char ->> 'sick')::boolean,false) then raise exception 'Character is not sick'; end if;
 select payload into v_post from public.site_records where collection='posts' and record_id=p_treatment_post_id;
 if v_post is null or v_post ->> 'charId' is distinct from p_character_id or v_post ->> 'userId' is distinct from v_profile.app_user_id then raise exception 'Treatment post does not belong to this character'; end if;
 if v_post ->> 'threadId' is distinct from v_treatment.room_thread_id then raise exception 'Go to the room assigned by the hospital queue'; end if;
 if position('รับการรักษา' in coalesce(v_post ->> 'note',''))=0 then raise exception 'Treatment post note must include รับการรักษา'; end if;
 if coalesce((v_post ->> 'hospitalWordCount')::integer,0)<=70 then raise exception 'Treatment roleplay must contain more than 70 words'; end if;
 select payload into v_thread from public.site_records where collection='threads' and record_id=v_post ->> 'threadId';
 select payload into v_forum from public.site_records where collection='forums' and record_id=v_thread ->> 'forumId';
 if coalesce(v_forum ->> 'name','') not ilike '%โรงพยาบาล%' then raise exception 'Treatment thread is not inside the hospital forum'; end if;
 if p_payment_method='cash' then
  if coalesce((v_char ->> 'won')::bigint,0)<1000 then raise exception 'Insufficient cash for hospital treatment'; end if;
  v_char:=jsonb_set(v_char,'{won}',to_jsonb(coalesce((v_char ->> 'won')::bigint,0)-1000),true);
  v_ledger:=jsonb_build_array(jsonb_build_object('at',floor(extract(epoch from clock_timestamp())*1000)::bigint,'amt',-1000,'note','ค่ารักษา STARLIGHT MEDICAL CENTER'))||coalesce(v_char -> 'ledger','[]'::jsonb);
  v_char:=jsonb_set(v_char,'{ledger}',(select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) from jsonb_array_elements(v_ledger) with ordinality where ordinality<=30),true);
 else
  select * into v_bank from public.site_bank_accounts where character_id=p_character_id and owner_app_user_id=v_profile.app_user_id for update;
  if not found then raise exception 'Open a bank account first'; end if;
  if v_bank.balance<1000 then raise exception 'Insufficient bank balance for hospital treatment'; end if;
  update public.site_bank_accounts set balance=balance-1000 where id=v_bank.id;
  insert into public.site_bank_transactions(request_id,kind,actor_app_user_id,sender_character_id,source_account_id,amount,fee,note)
   values(p_request_id,'withdraw',v_profile.app_user_id,p_character_id,v_bank.id,1000,0,'ค่ารักษา STARLIGHT MEDICAL CENTER');
 end if;
 v_now_ms:=floor(extract(epoch from clock_timestamp())*1000)::bigint; v_expiry:=now()+interval '3 hours'; v_inventory_id:=gen_random_uuid()::text;
 v_inv:=coalesce(v_char -> 'inv','[]'::jsonb)||jsonb_build_array(jsonb_build_object('id',v_inventory_id,'iid','starlight_medicine_bottle','at',v_now_ms,'expiresAt',v_now_ms+10800000,'treatmentId',v_treatment.id));
 v_char:=jsonb_set(v_char,'{inv}',v_inv,true);
 update public.site_records set payload=v_char,updated_at=now(),updated_by=auth.uid() where collection='characters' and record_id=p_character_id;
 update public.site_hospital_treatments set treatment_post_id=p_treatment_post_id,status='paid_medicine_received',payment_method=p_payment_method,payment_request_id=p_request_id,paid_at=now(),medicine_received_at=now(),medicine_expires_at=v_expiry,medicine_inventory_item_id=v_inventory_id,updated_at=now() where id=v_treatment.id;
 return jsonb_build_object('ok',true,'already_paid',false,'treatment_id',v_treatment.id,'medicine_expires_at',v_expiry,'medicine_inventory_item_id',v_inventory_id);
end; $$;

create or replace function public.site_hospital_use_medicine(p_character_id text,p_inventory_item_id text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_char jsonb; v_treatment public.site_hospital_treatments%rowtype; v_inv jsonb; v_now_ms bigint;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found then raise exception 'Account profile has not been initialized'; end if;
 select payload into v_char from public.site_records where collection='characters' and record_id=p_character_id for update;
 if v_char is null or v_char ->> 'ownerId' is distinct from v_profile.app_user_id then raise exception 'Character is not available to this account'; end if;
 select * into v_treatment from public.site_hospital_treatments where character_id=p_character_id and medicine_inventory_item_id=p_inventory_item_id and status='paid_medicine_received' order by id desc limit 1 for update;
 if not found then raise exception 'This medicine is not active for the character'; end if;
 if not exists(select 1 from jsonb_array_elements(coalesce(v_char -> 'inv','[]'::jsonb)) item where item ->> 'id'=p_inventory_item_id and item ->> 'iid'='starlight_medicine_bottle') then raise exception 'Medicine item is missing from inventory'; end if;
 select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) into v_inv from jsonb_array_elements(coalesce(v_char -> 'inv','[]'::jsonb)) with ordinality where value ->> 'id' is distinct from p_inventory_item_id;
 if v_treatment.medicine_expires_at<=now() then
  v_char:=jsonb_set(v_char,'{inv}',v_inv,true);
  update public.site_records set payload=v_char,updated_at=now(),updated_by=auth.uid() where collection='characters' and record_id=p_character_id;
  update public.site_hospital_treatments set status='medicine_expired',updated_at=now() where id=v_treatment.id;
  return jsonb_build_object('ok',true,'expired',true,'cured',false);
 end if;
 if not coalesce((v_char ->> 'sick')::boolean,false) then raise exception 'Character is no longer sick'; end if;
 if v_char ? 'illnessOriginalStage' then v_char:=jsonb_set(v_char,'{stage}',to_jsonb(coalesce((v_char ->> 'illnessOriginalStage')::integer,coalesce((v_char ->> 'stage')::integer,0))),true); end if;
 v_char:=jsonb_set(v_char,'{sick}',to_jsonb(false),true); v_char:=v_char-'illnessOriginalStage'-'sickSince'-'sickReason'; v_char:=jsonb_set(v_char,'{inv}',v_inv,true);
 v_now_ms:=floor(extract(epoch from clock_timestamp())*1000)::bigint;
 update public.site_records set payload=v_char,updated_at=now(),updated_by=auth.uid() where collection='characters' and record_id=p_character_id;
 update public.site_hospital_treatments set status='cured',medicine_used_at=now(),updated_at=now() where id=v_treatment.id;
 return jsonb_build_object('ok',true,'expired',false,'cured',true,'character',v_char,'used_at',v_now_ms);
end; $$;

create or replace function public.site_hospital_admin_set_sick(p_character_id text,p_sick boolean)
returns jsonb language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_profile public.site_profiles%rowtype; v_char jsonb; v_now_ms bigint;
begin
 if auth.uid() is null then raise exception 'Sign in is required'; end if;
 select * into v_profile from public.site_profiles where auth_user_id=(select auth.uid());
 if not found or not (v_profile.role='admin' or 'manage_characters'=any(coalesce(v_profile.permissions,array[]::text[]))) then raise exception 'Permission denied'; end if;
 select payload into v_char from public.site_records where collection='characters' and record_id=p_character_id for update;
 if v_char is null then raise exception 'Character not found'; end if;
 if coalesce(p_sick,false) then
  if not coalesce((v_char ->> 'sick')::boolean,false) then
   v_char:=jsonb_set(v_char,'{illnessOriginalStage}',to_jsonb(coalesce((v_char ->> 'stage')::integer,0)),true);
   v_now_ms:=floor(extract(epoch from clock_timestamp())*1000)::bigint;
   v_char:=jsonb_set(v_char,'{sickSince}',to_jsonb(v_now_ms),true);
  end if;
  v_char:=jsonb_set(v_char,'{sick}',to_jsonb(true),true); v_char:=jsonb_set(v_char,'{sickReason}',to_jsonb('กำหนดโดยผู้ดูแลระบบ'),true);
 else
  if v_char ? 'illnessOriginalStage' then v_char:=jsonb_set(v_char,'{stage}',to_jsonb(coalesce((v_char ->> 'illnessOriginalStage')::integer,coalesce((v_char ->> 'stage')::integer,0))),true); end if;
  v_char:=jsonb_set(v_char,'{sick}',to_jsonb(false),true); v_char:=v_char-'illnessOriginalStage'-'sickSince'-'sickReason';
 end if;
 update public.site_records set payload=v_char,updated_at=now(),updated_by=auth.uid() where collection='characters' and record_id=p_character_id;
 return jsonb_build_object('ok',true,'character',v_char);
end; $$;

revoke all on function public.site_hospital_submit_queue(text,text) from public,anon;
revoke all on function public.site_hospital_pay(text,text,text,text) from public,anon;
revoke all on function public.site_hospital_use_medicine(text,text) from public,anon;
revoke all on function public.site_hospital_admin_set_sick(text,boolean) from public,anon;
grant execute on function public.site_hospital_submit_queue(text,text) to authenticated;
grant execute on function public.site_hospital_pay(text,text,text,text) to authenticated;
grant execute on function public.site_hospital_use_medicine(text,text) to authenticated;
grant execute on function public.site_hospital_admin_set_sick(text,boolean) to authenticated;


commit;