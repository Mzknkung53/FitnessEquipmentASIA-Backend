-- Foundation: shared enums, helper schema, staff roles.
--
-- Conventions used in every migration:
--   * Business tables live in `public` (exposed by the Supabase Data API) with RLS on.
--   * Helpers that must never be called over the API live in `private`.
--   * Money is numeric(12,2) in THB. A null price means "quote only" and is never 0.
--   * security definer functions always pin `search_path = ''` and fully qualify names.

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

create type public.staff_role as enum ('admin', 'sales', 'warehouse', 'service');

create type public.stock_status as enum ('ready', 'preorder', 'import', 'out');
create type public.unit_state as enum ('inbound', 'available', 'reserved', 'showroom', 'dispatched', 'service');
create type public.stock_action as enum ('register', 'receive', 'move', 'reserve', 'release', 'dispatch', 'service', 'restock');

create type public.contact_method as enum ('line', 'wechat', 'whatsapp', 'phone', 'email');
create type public.installation_choice as enum ('yes', 'no', 'unsure');

create type public.quote_status as enum ('new', 'reviewing', 'quoted', 'won', 'lost', 'cancelled');
create type public.order_status as enum (
  'pending_confirmation',  -- team confirms shipping / installation cost first
  'awaiting_payment',
  'paid',
  'preparing',
  'shipped',
  'completed',
  'cancelled'
);
create type public.fulfilment_method as enum ('delivery', 'pickup');
create type public.payment_option as enum ('bank_transfer', 'card', 'deposit');
create type public.payment_status as enum ('pending', 'confirmed', 'failed', 'refunded');
create type public.service_status as enum ('new', 'scheduled', 'in_progress', 'resolved', 'closed');

-- ---------------------------------------------------------------------------
-- Generic helpers
-- ---------------------------------------------------------------------------

create function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Human-readable, gap-tolerant references per prefix and year: Q-2026-00001.
create table private.reference_counters (
  prefix text not null,
  year int not null,
  last_value int not null default 0,
  primary key (prefix, year)
);

create function private.next_reference(p_prefix text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_year int := extract(year from now() at time zone 'Asia/Bangkok')::int;
  v_next int;
begin
  insert into private.reference_counters as c (prefix, year, last_value)
  values (p_prefix, v_year, 1)
  on conflict (prefix, year) do update set last_value = c.last_value + 1
  returning last_value into v_next;
  return format('%s-%s-%s', p_prefix, v_year, lpad(v_next::text, 5, '0'));
end;
$$;

revoke all on function private.next_reference(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Staff
-- ---------------------------------------------------------------------------
-- Customers do not log in. Only staff have Supabase Auth accounts; a row here
-- is what turns an auth user into staff. Creating the auth user alone grants nothing.

create table public.staff_profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  role public.staff_role not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger staff_profiles_updated_at
  before update on public.staff_profiles
  for each row execute function private.set_updated_at();

-- Used inside RLS policies. Admin passes every role check. Wrap calls as
-- `(select private.has_role(...))` so Postgres evaluates them once per statement.
create function private.has_role(variadic p_roles public.staff_role[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.staff_profiles s
    where s.user_id = auth.uid()
      and s.is_active
      and (s.role = 'admin' or s.role = any (p_roles))
  );
$$;

create function private.is_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.staff_profiles s where s.user_id = auth.uid() and s.is_active
  );
$$;

grant execute on function private.has_role(public.staff_role[]) to anon, authenticated, service_role;
grant execute on function private.is_staff() to anon, authenticated, service_role;
