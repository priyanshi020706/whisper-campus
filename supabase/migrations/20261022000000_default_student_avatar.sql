begin;

-- Existing profiles can predate avatar selection. Give only blank profiles a
-- stable default and retain all user-selected avatar seeds.
update public.profiles
set avatar_seed = '8E6CFF'
where avatar_seed is null or btrim(avatar_seed) = '';

alter table public.profiles
  alter column avatar_seed set default '8E6CFF';

commit;
