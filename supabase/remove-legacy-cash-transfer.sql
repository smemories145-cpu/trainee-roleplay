-- STARLIGHT RP: remove the old cash-to-cash character transfer path.
-- Run once in Supabase Dashboard > SQL Editor for existing installations.
-- The old RPC moved money directly between characters.won and bypassed bank accounts.
begin;

drop function if exists public.site_transfer(text, text, integer, text);

notify pgrst, 'reload schema';

commit;
