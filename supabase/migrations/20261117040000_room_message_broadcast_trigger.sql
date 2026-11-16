-- Live chat: make sure every new room message is broadcast to the room channel.
--
-- public.broadcast_room_message() has been defined many times in earlier
-- migrations, but no migration ever attached it to public.room_messages (the
-- table was created in the dashboard, so the trigger may or may not exist in a
-- given database). Without the trigger, nobody receives messages live and users
-- have to refresh. This migration removes any existing copies of the trigger and
-- creates exactly one, so it is safe to run on any database state.
--
-- It is a BEFORE INSERT trigger because the function sets new.room_mode for the
-- legacy general / official-live rooms before the row is stored. The broadcast
-- is written in the same transaction, so a message that fails to insert is
-- never broadcast.
begin;

do $migration$
declare
  existing record;
begin
  for existing in
    select t.tgname
    from pg_trigger as t
    where t.tgrelid = 'public.room_messages'::regclass
      and not t.tgisinternal
      and t.tgfoid = 'public.broadcast_room_message()'::regprocedure
  loop
    execute format('drop trigger %I on public.room_messages', existing.tgname);
  end loop;
end
$migration$;

create trigger room_messages_broadcast_new
  before insert on public.room_messages
  for each row execute function public.broadcast_room_message();

notify pgrst, 'reload schema';
commit;
