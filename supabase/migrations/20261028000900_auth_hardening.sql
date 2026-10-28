-- Hardening for the Google-login profiles added in 20261028000800_auth_profiles.sql.
--
-- 1. Staff rights only for a CONFIRMED email. Before this, signing up with email +
--    password using an allowlisted address created an admin row immediately, while
--    the email was still unconfirmed.
-- 2. The allowlist only bootstraps a staff row the first time. It no longer
--    overwrites role or re-enables an account, so an admin setting
--    staff_profiles.is_active = false (or changing the role) now sticks.
-- 3. The private helper functions cannot be called directly by API roles.
--
-- Managing staff after this migration:
--   add:        insert into private.staff_allowlist (email, role, display_name) values (...);
--               (takes effect at that person's next Google sign-in)
--   disable:    update public.staff_profiles set is_active = false where user_id = ...;
--   change role: update public.staff_profiles set role = 'sales' where user_id = ...;

create or replace function private.sync_auth_profiles(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
  v_confirmed boolean;
  v_name text;
  v_avatar text;
  v_role public.staff_role;
  v_staff_name text;
begin
  select lower(coalesce(u.email, '')),
         u.email_confirmed_at is not null,
         coalesce(u.raw_user_meta_data->>'full_name', u.raw_user_meta_data->>'name', split_part(coalesce(u.email, ''), '@', 1)),
         u.raw_user_meta_data->>'avatar_url'
    into v_email, v_confirmed, v_name, v_avatar
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

  -- An unconfirmed address proves nothing about who owns it.
  if not v_confirmed then
    return;
  end if;

  select a.role, a.display_name into v_role, v_staff_name
  from private.staff_allowlist a
  where a.email = v_email;

  if found then
    -- First time only. An existing row belongs to the admins now.
    insert into public.staff_profiles (user_id, display_name, role)
    values (p_user_id, v_staff_name, v_role)
    on conflict (user_id) do nothing;
  end if;
end;
$$;

-- Google confirms the email on the INSERT, but an email/password account confirms
-- later with an UPDATE of email_confirmed_at, so sync then as well.
create or replace function private.handle_user_confirmed()
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

drop trigger if exists on_auth_user_confirmed on auth.users;
create trigger on_auth_user_confirmed
  after update of email_confirmed_at on auth.users
  for each row
  when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
  execute function private.handle_user_confirmed();

revoke execute on function
  private.sync_auth_profiles(uuid),
  private.handle_new_user(),
  private.handle_user_confirmed()
from public, anon, authenticated;

-- ensure_auth_profiles is for signed-in users only.
revoke execute on function public.ensure_auth_profiles() from public, anon;
grant execute on function public.ensure_auth_profiles() to authenticated;
