begin;

-- Create anonymous Unofficial room feeds for the existing MITS departments.
-- The shared rooms table and its current authenticated SELECT policy are reused.
insert into public.rooms (id, name)
values
  ('dept-ad', 'AI & Data Science'),
  ('dept-ai', 'Artificial Intelligence'),
  ('dept-am', 'AI & Machine Learning'),
  ('dept-cb', 'CS & Business Systems'),
  ('dept-cd', 'CS & Design'),
  ('dept-ce', 'Civil Engineering'),
  ('dept-cm', 'Chemical Engineering'),
  ('dept-cs', 'Computer Science & Engg'),
  ('dept-ec', 'Electronics & Communication'),
  ('dept-ee', 'Electrical Engineering'),
  ('dept-el', 'Electronics Engineering'),
  ('dept-et', 'Electronics & Telecommunication'),
  ('dept-io', 'Internet of Things (IoT)'),
  ('dept-ir', 'IT (AI & Robotics)'),
  ('dept-it', 'Information Technology'),
  ('dept-mc', 'Mathematics & Computing'),
  ('dept-me', 'Mechanical Engineering'),
  ('dept-tc', 'CS & Technology'),
  ('dept-ar', 'Architecture (B.Arch)')
on conflict (id) do update
set name = excluded.name;

notify pgrst, 'reload schema';
commit;
