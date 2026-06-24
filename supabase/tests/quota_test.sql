-- supabase/tests/quota_test.sql
begin;
select plan(4);

-- Seed a fake auth user (FK target).
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'q@test.com');

-- First call under a cap of 2 → allowed, used = 1.
select results_eq(
  $$ select allowed, used from public.check_and_increment_quota(
       '00000000-0000-0000-0000-000000000001', 2) $$,
  $$ values (true, 1) $$,
  'first call allowed, used=1');

-- Second call → allowed, used = 2.
select results_eq(
  $$ select allowed, used from public.check_and_increment_quota(
       '00000000-0000-0000-0000-000000000001', 2) $$,
  $$ values (true, 2) $$,
  'second call allowed, used=2');

-- Third call → blocked, used stays 2.
select results_eq(
  $$ select allowed, used from public.check_and_increment_quota(
       '00000000-0000-0000-0000-000000000001', 2) $$,
  $$ values (false, 2) $$,
  'third call blocked at cap');

-- Profile row was auto-created by the trigger.
select is(
  (select count(*)::int from public.profiles
     where id = '00000000-0000-0000-0000-000000000001'),
  1, 'profile auto-created on user insert');

select * from finish();
rollback;
