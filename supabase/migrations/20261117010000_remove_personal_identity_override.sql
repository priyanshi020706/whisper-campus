-- Removes a trigger that forces one specific account's real name. Real names
-- are entered by users through save_my_identity and should never be overridden
-- per person in the schema. Existing identity rows are left as they are.
begin;

drop trigger if exists keep_ritesh_identity_fixed on public.identity_records;
drop function if exists public.keep_ritesh_identity_fixed();

notify pgrst, 'reload schema';
commit;
