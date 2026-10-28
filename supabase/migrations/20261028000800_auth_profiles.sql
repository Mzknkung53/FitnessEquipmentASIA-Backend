-- Customer Google login profiles + staff allowlist (admin bootstrap).
-- First Google sign-in with an allowlisted email creates staff_profiles automatically.

create table private.staff_allowlist (
  email text primary key check (email = lower(email)),
  role public.staff_role not null,
  display_name text not null
);

insert into private.staff_allowlist (email, role, display_name)
values ('chatchye3@gmail.com', 'admin', 'Chatchye');

create table public.customer_profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  email text not null,
  display_name text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index customer_profiles_email_idx on public.customer_profiles (lower(email));

create trigger customer_profiles_updated_at
  before update on public.customer_profiles
  for each row execute function private.set_updated_at();

alter table public.customer_profiles enable row level security;

create policy "customer reads own profile" on public.customer_profiles
  for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_staff()));

create policy "customer updates own profile" on public.customer_profiles
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "staff read all customer profiles" on public.customer_profiles
  for select to authenticated
  using ((select private.is_staff()));

create or replace function private.sync_auth_profiles(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
  v_name text;
  v_avatar text;
  v_role public.staff_role;
  v_staff_name text;
begin
  select lower(coalesce(u.email, '')),
         coalesce(u.raw_user_meta_data->>'full_name', u.raw_user_meta_data->>'name', split_part(coalesce(u.email, ''), '@', 1)),
         u.raw_user_meta_data->>'avatar_url'
    into v_email, v_name, v_avatar
  from auth.users u
  where u.id = p_user_id;

  if v_email is null or v_email = '' then
    return;
  end if;

  insert into public.customer_profiles (user_id, email, display_name, avatar_url)
  values (p_user_id, v_email, nullif(v_name, ''), v_avatar)
  on conflict (user_id) do update
    set email = excluded.email,
        display_name = coalesce(excluded.display_name, public.customer_profiles.display_name),
        avatar_url = coalesce(excluded.avatar_url, public.customer_profiles.avatar_url),
        updated_at = now();

  select a.role, a.display_name into v_role, v_staff_name
  from private.staff_allowlist a
  where a.email = v_email;

  if found then
    insert into public.staff_profiles (user_id, display_name, role)
    values (p_user_id, v_staff_name, v_role)
    on conflict (user_id) do update
      set display_name = excluded.display_name,
          role = excluded.role,
          is_active = true,
          updated_at = now();
  end if;
end;
$$;

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.sync_auth_profiles(new.id);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- Callable after Google login so existing accounts also get profiles/staff rows.
create or replace function public.ensure_auth_profiles()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  v_email text;
  v_is_staff boolean;
  v_role public.staff_role;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  perform private.sync_auth_profiles(uid);

  select c.email into v_email from public.customer_profiles c where c.user_id = uid;
  select s.role, true into v_role, v_is_staff
  from public.staff_profiles s
  where s.user_id = uid and s.is_active;

  return jsonb_build_object(
    'email', v_email,
    'is_staff', coalesce(v_is_staff, false),
    'role', v_role
  );
end;
$$;

grant execute on function public.ensure_auth_profiles() to authenticated;
