-- STARLIGHT RP hotfix: repair contact list stage type mismatch
-- Run this file in Supabase SQL Editor if phone-messaging-migration.sql was already installed
-- and the phone contacts list fails with:
-- COALESCE types text and integer cannot be matched.
-- This only replaces the contact-list RPC; it does not delete or reset user data.
begin;

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
  'avatar',coalesce(r.payload->>'avatar',''),'stage',case when coalesce(r.payload->>'stage','') ~ '^[0-9]{1,3}$' then (r.payload->>'stage')::integer else 0 end,
  'status',coalesce(r.payload->>'status','approved'),
  'online',case when coalesce(pr.hide_presence,false) then false else pr.last_seen_at>now()-interval '90 seconds' end,
  'last_seen_at',case when coalesce(pr.hide_last_seen,false) then null else pr.last_seen_at end
 ) order by c.favorite desc,coalesce(nullif(r.payload->>'stageName',''),nullif(r.payload->>'name',''),c.contact_character_id)),'[]'::jsonb)
 into v_result from public.site_phone_contacts c
 left join public.site_records r on r.collection='characters' and r.record_id=c.contact_character_id
 left join public.site_phone_presence pr on pr.character_id=c.contact_character_id
 where c.owner_character_id=p_character_id and r.payload->>'status'='approved';
 return v_result;
end;
$$;

revoke all on function public.site_phone_list_contacts(text) from public, anon;
grant execute on function public.site_phone_list_contacts(text) to authenticated;
notify pgrst, 'reload schema';

commit;
