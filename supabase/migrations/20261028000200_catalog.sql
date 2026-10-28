-- Catalog: categories, products, media, variants (sellable SKUs), internal
-- costs, price history and exchange rates.
--
-- Public-safe columns live on products/variants. Anything the storefront must
-- never see (cost, supplier, packaging) lives in variant_internal, so the
-- public read path never has to filter columns.

create table public.categories (
  id text primary key check (id ~ '^[a-z0-9-]+$'),   -- 'plate-loaded', 'cardio', ...
  name_th text not null,
  name_en text not null,
  name_zh text,
  sort int not null default 0,
  created_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null check (slug ~ '^[a-z0-9-]+$'),
  model text unique not null,                       -- FEA-PL01
  name_th text not null,
  name_en text not null,
  name_zh text,
  category_id text not null references public.categories (id),
  summary text,
  setting text[] not null default '{}'
    check (setting <@ array['home', 'commercial']),
  arrived_at date,                                   -- drives the NEW badge
  new_override boolean,                              -- null = automatic, true/false = forced by staff
  curated_rank int,                                  -- lower = shown first in "ทีมงานแนะนำ"
  pictogram text,                                    -- fallback icon when there is no photo
  unit_note text,                                    -- e.g. "ราคาต่อแผ่น"
  specs jsonb not null default '[]'
    check (jsonb_typeof(specs) = 'array'),           -- [{"label": "...", "value": "..."}]
  usage_steps text[] not null default '{}',
  status text not null default 'draft' check (status in ('draft', 'published', 'archived')),
  is_demo boolean not null default false,            -- sample content to replace before launch
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index products_category_idx on public.products (category_id) where status = 'published';
create index products_curated_idx on public.products (curated_rank) where status = 'published';

create trigger products_updated_at
  before update on public.products
  for each row execute function private.set_updated_at();

-- Photos, manuals and videos. Files sit in Supabase Storage (bucket product-media);
-- videos may be an external URL instead.
create table public.product_media (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products (id) on delete cascade,
  kind text not null check (kind in ('image', 'manual', 'video')),
  storage_path text,
  external_url text,
  width int check (width > 0),
  height int check (height > 0),
  alt text,
  sort int not null default 0,
  created_at timestamptz not null default now(),
  check (num_nonnulls(storage_path, external_url) = 1),
  check (kind <> 'image' or (width is not null and height is not null and alt is not null))
);

create index product_media_product_idx on public.product_media (product_id, kind, sort);

create table public.variants (
  sku text primary key check (sku ~ '^[A-Z0-9-]+$'),
  product_id uuid not null references public.products (id) on delete cascade,
  label text not null,
  swatch text check (swatch ~ '^#[0-9a-fA-F]{6}$'),
  stock_status public.stock_status not null default 'import',
  price_thb numeric(12, 2) check (price_thb > 0),   -- excl. VAT; null = quote only, never 0
  lead_time text,                                    -- shown only when staff supply it
  sort int not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index variants_product_idx on public.variants (product_id, sort);

create trigger variants_updated_at
  before update on public.variants
  for each row execute function private.set_updated_at();

-- Staff-only facts per SKU: cost, supplier and packaging for shipping estimates.
create table public.variant_internal (
  sku text primary key references public.variants (sku) on delete cascade,
  cost_thb numeric(12, 2) check (cost_thb >= 0),
  supplier text,
  hs_code text,                                      -- customs code for LA / MM / CN shipments
  package_length_cm numeric(8, 1) check (package_length_cm > 0),
  package_width_cm numeric(8, 1) check (package_width_cm > 0),
  package_height_cm numeric(8, 1) check (package_height_cm > 0),
  package_weight_kg numeric(8, 2) check (package_weight_kg > 0),
  updated_at timestamptz not null default now()
);

create trigger variant_internal_updated_at
  before update on public.variant_internal
  for each row execute function private.set_updated_at();

-- Every change to a selling price or cost is kept, for margin and pricing analysis.
create table public.variant_price_history (
  id bigint generated always as identity primary key,
  sku text not null references public.variants (sku) on delete cascade,
  field text not null check (field in ('price_thb', 'cost_thb')),
  old_value numeric(12, 2),
  new_value numeric(12, 2),
  changed_by uuid references auth.users (id),
  changed_at timestamptz not null default now()
);

create index variant_price_history_sku_idx on public.variant_price_history (sku, changed_at desc);

create function private.log_price_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- tg_argv[0] names the column; read it through jsonb so one function serves both tables.
  v_old numeric := to_jsonb(old) ->> tg_argv[0];
  v_new numeric := to_jsonb(new) ->> tg_argv[0];
begin
  if v_new is distinct from v_old then
    insert into public.variant_price_history (sku, field, old_value, new_value, changed_by)
    values (new.sku, tg_argv[0], v_old, v_new, auth.uid());
  end if;
  return new;
end;
$$;

create trigger variants_price_history
  after update of price_thb on public.variants
  for each row execute function private.log_price_change('price_thb');

create trigger variant_internal_price_history
  after update of cost_thb on public.variant_internal
  for each row execute function private.log_price_change('cost_thb');

-- THB per one unit of foreign currency. The newest row per currency is current;
-- orders snapshot the rate they were placed with.
create table public.exchange_rates (
  id bigint generated always as identity primary key,
  currency char(3) not null check (currency ~ '^[A-Z]{3}$' and currency <> 'THB'),
  thb_per_unit numeric(12, 6) not null check (thb_per_unit > 0),
  source text not null,                              -- 'manual', 'bot.or.th', ...
  effective_at timestamptz not null default now(),
  created_by uuid references auth.users (id)
);

create index exchange_rates_current_idx on public.exchange_rates (currency, effective_at desc);
