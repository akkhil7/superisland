-- supabase/migrations/0001_profiles_and_quota.sql

-- One profile row per auth user.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "profiles are self-readable"
  on public.profiles for select
  using (auth.uid() = id);

-- Auto-create a profile when an auth user is created.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Per-user, per-UTC-day call counter.
create table if not exists public.usage_daily (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  count int not null default 0,
  primary key (user_id, day)
);

alter table public.usage_daily enable row level security;

create policy "usage is self-readable"
  on public.usage_daily for select
  using (auth.uid() = user_id);

-- Atomic: increment today's counter for a user unless it would exceed the cap.
-- Returns whether the call is allowed and the resulting used-count.
create or replace function public.check_and_increment_quota(p_user uuid, p_cap int)
returns table(allowed boolean, used int)
language plpgsql security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_count int;
begin
  insert into public.usage_daily (user_id, day, count)
    values (p_user, v_today, 0)
    on conflict (user_id, day) do nothing;

  select count into v_count from public.usage_daily
    where user_id = p_user and day = v_today for update;

  if v_count >= p_cap then
    return query select false, v_count;
  else
    update public.usage_daily set count = count + 1
      where user_id = p_user and day = v_today
      returning count into v_count;
    return query select true, v_count;
  end if;
end;
$$;
