-- STARLIGHT RP illness and hospital treatment system
-- Safe to run repeatedly. Review and run manually in Supabase SQL Editor after reviewing the PR.
-- This migration does not modify existing records except when a player triggers a qualifying training post.

create table if not exists public.site_hospital_treatments (
  id bigint generated always as identity primary key,
  character_id text not null,
  owner_app_user_id text not null,
  queue_post_id text not null unique,
  treatment_post_id text unique,
  room_number integer not null check (room_number between 1 and 3),
  doctor_name text not null,
  payment_method text,
  amount bigint not null default 1000 check (amount=1000),
  status text not null default 'queued' check (status in ('queued','paid_medicine_received','cured','expired')),
  medicine_received_at timestamptz,
  medicine_expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists site_hospital_treatments_character_idx
  on public.site_hospital_treatments(character_id, created_at desc);
alter table public.site_hospital_treatments enable row level security;
revoke all on table public.site_hospital_treatments from anon, authenticated;

-- Keep the current secure server-side post creation flow and add daily per-character/per-skill counters.
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
  v_train_count integer := 0;
  v_train_day date := (clock_timestamp() at time zone 'Asia/Bangkok')::date;
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

  if p_train is not null then
    select count(*)::integer into v_train_count
    from public.site_records r
    where r.collection='posts'
      and r.payload ->> 'charId'=v_cid
      and r.payload ->> 'train'=p_train
      and coalesce((r.payload ->> 'createdAt')::numeric,0)>0
      and (to_timestamp(((r.payload ->> 'createdAt')::numeric)/1000) at time zone 'Asia/Bangkok')::date=v_train_day;
    v_train_count := v_train_count + 1;
    if v_train_count >= 11 then
      v_char := jsonb_set(v_char,'{sick}', 'true'::jsonb, true);
      v_char := jsonb_set(v_char,'{illnessOriginalStage}',to_jsonb(coalesce((v_char ->> 'stage')::integer,0)),true);
      v_char := jsonb_set(v_char,'{sickSince}',to_jsonb(v_now_ms),true);
      v_char := jsonb_set(v_char,'{sickReason}',to_jsonb('ฝึกทักษะ '||p_train||' เกิน 10 ครั้งในวันเดียว'),true);
    end if;
  end if;

  v_post := p_post
    || jsonb_build_object('charId',v_cid,'gm',false,'train',p_train,
       'gain',v_new_stat-v_old_stat,'wonGain',v_won,'trainingCount',case when p_train is null then null else v_train_count end,'trainingWarning',case when v_train_count=10 then true else false end,'becameSick',case when v_train_count>=11 then true else false end,'createdAt',coalesce((p_post ->> 'createdAt')::numeric,v_now_ms));
  insert into public.site_records(collection,record_id,payload,updated_at,updated_by)
  values ('posts',v_id,v_post,now(),auth.uid());
  update public.site_records set payload=v_char,updated_at=now(),updated_by=auth.uid()
    where collection='characters' and record_id=v_cid;

  return jsonb_build_object('ok',true,'post',v_post,'character',v_char,'gain',v_new_stat-v_old_stat);
end;
$$;


revoke all on function public.site_create_post(jsonb,text) from public, anon;
grant execute on function public.site_create_post(jsonb,text) to authenticated;

create or replace function public.site_hospital_submit_queue(p_character_id text, p_post_id text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_profile public.site_profiles%rowtype;
  v_char jsonb;
  v_post jsonb;
  v_thread jsonb;
  v_room integer;
  v_doctor text;
  v_annotation text;
  v_existing public.site_hospital_treatments%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_profile from public.site_profiles where auth_user_id=auth.uid();
  select payload into v_char from public.site_records where collection='characters' and record_id=p_character_id for update;
  if v_char is null or v_char->>'ownerId' is distinct from v_profile.app_user_id or v_char->>'status' is distinct from 'approved' then raise exception 'Character is not available'; end if;
  if coalesce((v_char->>'sick')::boolean,false) is not true then raise exception 'ตัวละครนี้ไม่ได้อยู่ในสถานะป่วย'; end if;
  select payload into v_post from public.site_records where collection='posts' and record_id=p_post_id for update;
  if v_post is null or v_post->>'charId' is distinct from p_character_id or v_post->>'userId' is distinct from v_profile.app_user_id then raise exception 'โพสต์ไม่ใช่ของตัวละครนี้'; end if;
  select payload into v_thread from public.site_records where collection='threads' and record_id=(v_post->>'threadId');
  if v_thread is null or (coalesce(v_thread->>'title','') not ilike '%แผนกต้อนรับ%' and coalesce(v_thread->>'title','') not ilike '%แผนกรักษาทั่วไป%') then raise exception 'กรุณาใช้โพสต์ในกระทู้แผนกรักษาทั่วไป'; end if;
  if length(btrim(regexp_replace(coalesce(v_post->>'content',''),'<[^>]*>',' ','g'))) <= 70 then raise exception 'โรลเพลย์ต้องมีความยาวมากกว่า 70 คำ'; end if;
  if coalesce(v_post->>'note','') not ilike '%รับบัตรคิว%' and coalesce(v_post->>'content','') not ilike '%รับบัตรคิว%' then raise exception 'กรุณาระบุหมายเหตุ รับบัตรคิว'; end if;
  select * into v_existing from public.site_hospital_treatments where queue_post_id=p_post_id;
  if found then return jsonb_build_object('ok',true,'already_processed',true,'room_number',v_existing.room_number,'doctor_name',v_existing.doctor_name); end if;
  v_room := 1+floor(random()*3)::integer;
  v_doctor := case v_room when 1 then 'คุณหมอลี' when 2 then 'คุณหมอจาง' else 'คุณหมอชิม' end;
  insert into public.site_hospital_treatments(character_id,owner_app_user_id,queue_post_id,room_number,doctor_name)
    values(p_character_id,v_profile.app_user_id,p_post_id,v_room,v_doctor);
  v_annotation := '<div style="margin-top:18px;padding:14px 16px;border-left:4px solid #39804b;background:#eff8ef;color:#28743c;font-size:16px;font-weight:700;">เข้ารับการตรวจที่ห้องตรวจหมายเลข '||v_room||' พบ'||v_doctor||'</div>';
  update public.site_records set payload=jsonb_set(v_post,'{content}',to_jsonb(coalesce(v_post->>'content','')||E'\n'||v_annotation),true),updated_at=now(),updated_by=auth.uid()
    where collection='posts' and record_id=p_post_id;
  return jsonb_build_object('ok',true,'room_number',v_room,'doctor_name',v_doctor,'refresh_required',true);
end $$;

create or replace function public.site_hospital_pay(p_character_id text,p_treatment_post_id text,p_payment_method text,p_request_id text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_profile public.site_profiles%rowtype;
  v_char jsonb;
  v_post jsonb;
  v_thread jsonb;
  v_treatment public.site_hospital_treatments%rowtype;
  v_bank public.site_bank_accounts%rowtype;
  v_now timestamptz := clock_timestamp();
  v_item_id text := 'starlight_medicine_bottle';
  v_inv jsonb;
  v_annotation text;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  if p_payment_method not in ('cash','bank') then raise exception 'ช่องทางชำระเงินไม่ถูกต้อง'; end if;
  if nullif(trim(p_request_id),'') is null then raise exception 'Request ID is required'; end if;
  select * into v_profile from public.site_profiles where auth_user_id=auth.uid();
  select payload into v_char from public.site_records where collection='characters' and record_id=p_character_id for update;
  if v_char is null or v_char->>'ownerId' is distinct from v_profile.app_user_id or v_char->>'status' is distinct from 'approved' then raise exception 'Character is not available'; end if;
  select * into v_treatment from public.site_hospital_treatments where treatment_post_id=p_treatment_post_id for update;
  if not found then
    select payload into v_post from public.site_records where collection='posts' and record_id=p_treatment_post_id for update;
    if v_post is null or v_post->>'charId' is distinct from p_character_id or v_post->>'userId' is distinct from v_profile.app_user_id then raise exception 'โพสต์เข้าห้องตรวจไม่ถูกต้อง'; end if;
    select payload into v_thread from public.site_records where collection='threads' and record_id=(v_post->>'threadId');
    if v_thread is null or coalesce(v_thread->>'title','') not ilike '%ห้องตรวจหมายเลข%' then raise exception 'กรุณาใช้โพสต์ในกระทู้ห้องตรวจที่ถูกต้อง'; end if;
    if length(btrim(regexp_replace(coalesce(v_post->>'content',''),'<[^>]*>',' ','g'))) <= 70 then raise exception 'โรลเพลย์ต้องมีความยาวมากกว่า 70 คำ'; end if;
    if coalesce(v_post->>'note','') not ilike '%รับการรักษ%' and coalesce(v_post->>'content','') not ilike '%รับการรักษ%' then raise exception 'กรุณาระบุหมายเหตุ รับการรักษา'; end if;
    select * into v_treatment from public.site_hospital_treatments
      where character_id=p_character_id and status='queued' order by created_at desc limit 1 for update;
    if not found then raise exception 'ไม่พบคิวรักษาที่รอชำระเงิน'; end if;
    update public.site_hospital_treatments set treatment_post_id=p_treatment_post_id,updated_at=now()
      where id=v_treatment.id;
    v_treatment.treatment_post_id:=p_treatment_post_id;
  end if;
  if v_treatment.character_id<>p_character_id or v_treatment.owner_app_user_id<>v_profile.app_user_id then raise exception 'รายการรักษาไม่ใช่ของตัวละครนี้'; end if;
  if v_treatment.status='paid_medicine_received' then return jsonb_build_object('ok',true,'already_paid',true,'expires_at',v_treatment.medicine_expires_at); end if;
  if v_treatment.status<>'queued' then raise exception 'รายการรักษานี้ไม่สามารถชำระเงินได้'; end if;
  if p_payment_method='cash' then
    if coalesce((v_char->>'won')::bigint,0)<1000 then raise exception 'เงินสดไม่เพียงพอ'; end if;
    v_char:=jsonb_set(v_char,'{won}',to_jsonb(coalesce((v_char->>'won')::bigint,0)-1000),true);
    v_char:=jsonb_set(v_char,'{ledger}',jsonb_build_array(jsonb_build_object('at',floor(extract(epoch from v_now)*1000)::bigint,'amt',-1000,'note','ค่ารักษาพยาบาล'))||coalesce(v_char->'ledger','[]'::jsonb),true);
  else
    select * into v_bank from public.site_bank_accounts where character_id=p_character_id and owner_app_user_id=v_profile.app_user_id for update;
    if not found then raise exception 'ตัวละครนี้ยังไม่มีบัญชีธนาคาร'; end if;
    if v_bank.balance<1000 then raise exception 'ยอดเงินในบัญชีไม่เพียงพอ'; end if;
    update public.site_bank_accounts set balance=balance-1000 where id=v_bank.id;
    insert into public.site_bank_transactions(request_id,kind,actor_app_user_id,sender_character_id,source_account_id,amount,fee,note)
      values('hospital:'||p_request_id,'withdraw',v_profile.app_user_id,p_character_id,v_bank.id,1000,0,'ค่ารักษาพยาบาล');
  end if;
  v_inv:=coalesce(v_char->'inv','[]'::jsonb)||jsonb_build_array(jsonb_build_object('id',gen_random_uuid()::text,'iid',v_item_id,'at',floor(extract(epoch from v_now)*1000)::bigint));
  v_char:=jsonb_set(v_char,'{inv}',v_inv,true);
  update public.site_records set payload=v_char,updated_at=now(),updated_by=auth.uid() where collection='characters' and record_id=p_character_id;
  update public.site_hospital_treatments set status='paid_medicine_received',payment_method=p_payment_method,medicine_received_at=v_now,medicine_expires_at=v_now+interval '3 hours',updated_at=v_now where id=v_treatment.id;
  v_annotation:='<div style="margin-top:18px;padding:12px 16px;border-left:4px solid #39804b;background:#eff8ef;color:#28743c;font-size:16px;font-weight:700;">รักษาเสร็จสิ้น · ได้รับยารักษาแล้ว</div>';
  update public.site_records set payload=jsonb_set(payload,'{content}',to_jsonb(coalesce(payload->>'content','')||E'\n'||v_annotation),true),updated_at=now(),updated_by=auth.uid()
    where collection='posts' and record_id=p_treatment_post_id;
  return jsonb_build_object('ok',true,'amount',1000,'medicine_received_at',v_now,'medicine_expires_at',v_now+interval '3 hours');
end $$;

create or replace function public.site_hospital_use_medicine(p_character_id text,p_inventory_item_id text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_profile public.site_profiles%rowtype;
  v_char jsonb;
  v_inv jsonb;
  v_found boolean:=false;
  v_treatment public.site_hospital_treatments%rowtype;
  v_item jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in is required'; end if;
  select * into v_profile from public.site_profiles where auth_user_id=auth.uid();
  select payload into v_char from public.site_records where collection='characters' and record_id=p_character_id for update;
  if v_char is null or v_char->>'ownerId' is distinct from v_profile.app_user_id or v_char->>'status' is distinct from 'approved' then raise exception 'Character is not available'; end if;
  select * into v_treatment from public.site_hospital_treatments where character_id=p_character_id and status='paid_medicine_received' order by medicine_received_at desc limit 1 for update;
  if not found then raise exception 'ไม่พบยาที่อยู่ในช่วงเวลาใช้งาน'; end if;
  if clock_timestamp()>v_treatment.medicine_expires_at then
    update public.site_hospital_treatments set status='expired',updated_at=now() where id=v_treatment.id;
    raise exception 'ยาหมดอายุแล้ว กรุณารับบัตรคิวและรักษาใหม่';
  end if;
  v_inv:=coalesce(v_char->'inv','[]'::jsonb);
  select value into v_item from jsonb_array_elements(v_inv) where value->>'id'=p_inventory_item_id and value->>'iid'='starlight_medicine_bottle' limit 1;
  if v_item is null then raise exception 'ไม่พบขวดยาในกระเป๋าตัวละคร'; end if;
  select coalesce(jsonb_agg(value),'[]'::jsonb) into v_inv from jsonb_array_elements(v_inv) where value->>'id'<>p_inventory_item_id;
  v_char:=jsonb_set(v_char,'{inv}',v_inv,true);
  v_char:=jsonb_set(v_char,'{sick}','false'::jsonb,true);
  v_char:=v_char-'sickSince'-'sickReason';
  update public.site_records set payload=v_char,updated_at=now(),updated_by=auth.uid() where collection='characters' and record_id=p_character_id;
  update public.site_hospital_treatments set status='cured',updated_at=now() where id=v_treatment.id;
  return jsonb_build_object('ok',true,'cured',true,'character',v_char);
end $$;

revoke all on function public.site_hospital_submit_queue(text,text) from public,anon;
revoke all on function public.site_hospital_pay(text,text,text,text) from public,anon;
revoke all on function public.site_hospital_use_medicine(text,text) from public,anon;
grant execute on function public.site_hospital_submit_queue(text,text) to authenticated;
grant execute on function public.site_hospital_pay(text,text,text,text) to authenticated;
grant execute on function public.site_hospital_use_medicine(text,text) to authenticated;


-- Seed the medicine item without overwriting an existing administrator-managed item.
insert into public.site_records(collection,record_id,payload,updated_at)
values (
 'items',
 'starlight_medicine_bottle',
 jsonb_build_object(
   'id','starlight_medicine_bottle',
   'name','ขวดยารักษา',
   'description','ยารักษาอาการป่วยจากการฝึกทักษะหรือโรลเพลย์ ใช้ได้ 1 ครั้งภายใน 3 ชั่วโมงหลังได้รับยา',
   'price',0,
   'stock',-1,
   'category','medicine',
   'image','assets/starlight_medicine_bottle.svg',
   'icon','assets/starlight_medicine_bottle.svg',
   'usable',true
 ),
 now()
)
on conflict (collection,record_id) do nothing;
