-- Sales: customers, quote requests, service requests and their file attachments.
-- The website is a catalog + quotation tool for now: there is no online ordering
-- or payment. Customers have no login; the backend writes these rows through the
-- submit_* functions and staff work them after.

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  display_name text not null,
  company text,
  contact_method public.contact_method not null,
  contact_value text not null,
  email text,
  phone text,
  country text,
  city text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One customer per contact handle, so repeat customers line up across quote requests.
create unique index customers_contact_idx on public.customers (contact_method, lower(contact_value));

create trigger customers_updated_at
  before update on public.customers
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------------
-- Quotes
-- ---------------------------------------------------------------------------

create table public.quote_requests (
  id uuid primary key default gen_random_uuid(),
  reference text unique not null,                   -- Q-2026-00001
  customer_id uuid not null references public.customers (id),
  contact_name text not null,
  company text,
  contact_method public.contact_method not null,
  contact_value text not null,
  country text not null,
  city text not null,
  postcode text,
  installation public.installation_choice not null default 'unsure',
  access_upper_floor boolean not null default false,
  access_lift boolean not null default false,
  access_stairs boolean not null default false,
  access_truck boolean not null default false,
  target_date date,
  budget_text text,                                  -- as typed by the customer
  budget_thb numeric(14, 2),                         -- normalised by staff, for analysis
  message text,
  status public.quote_status not null default 'new',
  assigned_to uuid references auth.users (id),
  -- Quotation amounts. Catalog prices exclude VAT, so VAT is added here.
  quoted_total_thb numeric(14, 2) check (quoted_total_thb >= 0),           -- excl. VAT
  vat_rate numeric(5, 2) not null default 7 check (vat_rate between 0 and 100),
  quoted_vat_thb numeric(14, 2) generated always as (
    round(quoted_total_thb * vat_rate / 100, 2)
  ) stored,
  quoted_grand_total_thb numeric(14, 2) generated always as (
    quoted_total_thb + round(quoted_total_thb * vat_rate / 100, 2)
  ) stored,
  quoted_at timestamptz,
  closed_at timestamptz,                             -- won / lost / cancelled
  lost_reason text,
  source text,                                       -- 'web', 'line', 'showroom', ...
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index quote_requests_status_idx on public.quote_requests (status, created_at desc);
create index quote_requests_customer_idx on public.quote_requests (customer_id);

create trigger quote_requests_updated_at
  before update on public.quote_requests
  for each row execute function private.set_updated_at();

create table public.quote_items (
  id bigint generated always as identity primary key,
  quote_id uuid not null references public.quote_requests (id) on delete cascade,
  sku text not null references public.variants (sku),
  qty int not null check (qty between 1 and 9999),
  note text,
  list_price_thb numeric(12, 2),                     -- web price when requested (null = quote only)
  quoted_unit_price_thb numeric(12, 2) check (quoted_unit_price_thb >= 0),   -- excl. VAT
  unit_cost_thb numeric(12, 2),                      -- cost snapshot when requested, for margin
  unique (quote_id, sku)
);

alter table public.stock_units
  add constraint stock_units_quote_fk foreign key (quote_id) references public.quote_requests (id);
alter table public.stock_movements
  add constraint stock_movements_quote_fk foreign key (quote_id) references public.quote_requests (id);

-- ---------------------------------------------------------------------------
-- Service / repair requests
-- ---------------------------------------------------------------------------

create table public.service_requests (
  id uuid primary key default gen_random_uuid(),
  reference text unique not null,                   -- SR-2026-00001
  customer_id uuid references public.customers (id),
  product_model text not null,                       -- as typed, e.g. FEA-PL01
  unit_code_input text,                              -- machine number as typed by the customer
  unit_code text references public.stock_units (unit_code),  -- set when it matches a known unit
  symptom text not null,
  contact_value text not null,                       -- "LINE ID หรือเบอร์โทรศัพท์"
  status public.service_status not null default 'new',
  under_warranty boolean,
  assigned_to uuid references auth.users (id),
  scheduled_at timestamptz,
  resolved_at timestamptz,
  resolution text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index service_requests_status_idx on public.service_requests (status, created_at desc);

create trigger service_requests_updated_at
  before update on public.service_requests
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------------
-- Attachments (floor plans, repair photos/videos). Files live in private buckets.
-- ---------------------------------------------------------------------------

create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid references public.quote_requests (id) on delete cascade,
  service_request_id uuid references public.service_requests (id) on delete cascade,
  bucket text not null check (bucket in ('quote-attachments', 'service-attachments')),
  storage_path text not null,
  mime_type text not null,
  size_bytes bigint not null check (size_bytes between 1 and 52428800),
  created_at timestamptz not null default now(),
  check (num_nonnulls(quote_id, service_request_id) = 1),
  unique (bucket, storage_path)
);
