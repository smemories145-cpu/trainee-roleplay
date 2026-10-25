-- Require the hospital intake fields in the database RPC too; no user records are changed.
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
    if nullif(trim(p_post ->> 'hospitalPatientName'),'') is null then
      raise exception 'Hospital roleplay form requires patient name';
    end if;
    if nullif(trim(p_post ->> 'hospitalPatientPhoto'),'') is not null
       and (p_post ->> 'hospitalPatientPhoto') !~* '^https?://' then
      raise exception 'Hospital ID Photo must use an http or https image URL';
    end if;
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

  if coalesce((v_thread ->> 'consecutivePostWarning')::boolean,false) then
    select payload into v_previous_post from public.site_records where collection='posts' and payload ->> 'threadId'=v_tid order by nullif(payload ->> 'createdAt','')::numeric desc nulls last,updated_at desc limit 1;
    if v_previous_post is not null and v_previous_post ->> 'charId'=v_cid and not coalesce((v_previous_post ->> 'gm')::boolean,false) and v_now_ms >= coalesce((v_previous_post ->> 'createdAt')::numeric,0) and v_now_ms - coalesce((v_previous_post ->> 'createdAt')::numeric,0) < 15 * 60 * 1000 then
      v_consecutive_warning := true;
      if not coalesce((v_char ->> 'sick')::boolean,false) then
        v_char := jsonb_set(v_char,'{illnessOriginalStage}',to_jsonb(coalesce((v_char ->> 'stage')::integer,0)),true);
        v_char := jsonb_set(v_char,'{sick}',to_jsonb(true),true);
        v_char := jsonb_set(v_char,'{sickSince}',to_jsonb(v_now_ms),true);
        v_char := jsonb_set(v_char,'{sickReason}',to_jsonb('โพสต์ติดกันในกระทู้โรลเพลย์'::text),true);
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