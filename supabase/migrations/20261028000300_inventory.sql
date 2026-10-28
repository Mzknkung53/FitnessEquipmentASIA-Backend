-- Inventory: physical units identified by the internal QR code, where they are,
-- and an append-only movement log. Units change only through the
-- stock_* functions in the API migration, which also write the log.

create table public.locations (
  id text primary key check (id ~ '^[A-Z0-9-]+$'),   -- WH-A-02-14, SHOWROOM-PL
  name text not null,                                 -- "คลัง A · แถว 2 · ช่อง 14"
  kind text not null check (kind in ('receiving', 'warehouse', 'showroom', 'service', 'transit')),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.stock_units (
  unit_code text primary key check (unit_code ~ '^U-[0-9]{6}$'),  -- encoded in the unit QR
  sku text not null references public.variants (sku),
  serial text,
  location_id text not null references public.locations (id),
  condition text,
  state public.unit_state not null default 'inbound',
  order_id uuid,                                      -- set while reserved / after dispatch (FK added with orders)
  received_at date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index stock_units_serial_idx on public.stock_units (sku, serial) where serial is not null;
create index stock_units_sku_state_idx on public.stock_units (sku, state);

create trigger stock_units_updated_at
  before update on public.stock_units
  for each row execute function private.set_updated_at();

create table public.stock_movements (
  id bigint generated always as identity primary key,
  unit_code text not null references public.stock_units (unit_code),
  action public.stock_action not null,
  from_state public.unit_state,
  to_state public.unit_state not null,
  from_location_id text references public.locations (id),
  to_location_id text not null references public.locations (id),
  order_id uuid,
  note text,
  actor uuid not null references auth.users (id),
  created_at timestamptz not null default now()
);

create index stock_movements_unit_idx on public.stock_movements (unit_code, created_at desc);

-- The log is evidence: no edits, no deletes, for anyone.
create function private.forbid_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = '42501';
end;
$$;

create trigger stock_movements_append_only
  before update or delete on public.stock_movements
  for each row execute function private.forbid_change();
