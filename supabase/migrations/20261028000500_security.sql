-- Row Level Security. Default is deny: every table has RLS on, and a role sees
-- only what a policy below allows. The backend's service_role key bypasses RLS,
-- so it must stay server-side and only call the vetted API functions for writes.
--
-- Who can do what (admin passes every check):
--   anon / any visitor : published catalog, exchange rates
--   sales              : catalog edits, costs (read), customers, quotes, service
--   warehouse          : locations, stock (through stock_* functions), catalog read incl. drafts
--   service            : service requests, stock read
--   admin              : everything, incl. cost edits and staff management

alter table public.staff_profiles enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.product_media enable row level security;
alter table public.variants enable row level security;
alter table public.variant_internal enable row level security;
alter table public.variant_price_history enable row level security;
alter table public.exchange_rates enable row level security;
alter table public.locations enable row level security;
alter table public.stock_units enable row level security;
alter table public.stock_movements enable row level security;
alter table public.customers enable row level security;
alter table public.quote_requests enable row level security;
alter table public.quote_items enable row level security;
alter table public.service_requests enable row level security;
alter table public.attachments enable row level security;

-- ---------------------------------------------------------------------------
-- Staff profiles
-- ---------------------------------------------------------------------------

create policy "staff read own profile, admin reads all" on public.staff_profiles
  for select to authenticated
  using (user_id = (select auth.uid()) or (select private.has_role('admin')));

create policy "admin manages staff" on public.staff_profiles
  for all to authenticated
  using ((select private.has_role('admin')))
  with check ((select private.has_role('admin')));

-- ---------------------------------------------------------------------------
-- Catalog: public reads published rows, staff read everything, sales edit
-- ---------------------------------------------------------------------------

create policy "anyone reads categories" on public.categories
  for select to anon, authenticated using (true);
create policy "sales edit categories" on public.categories
  for all to authenticated
  using ((select private.has_role('sales')))
  with check ((select private.has_role('sales')));

create policy "public reads published products" on public.products
  for select to anon, authenticated
  using (status = 'published' or (select private.is_staff()));
create policy "sales edit products" on public.products
  for all to authenticated
  using ((select private.has_role('sales')))
  with check ((select private.has_role('sales')));

create policy "public reads media of published products" on public.product_media
  for select to anon, authenticated
  using (
    (select private.is_staff())
    or exists (select 1 from public.products p where p.id = product_id and p.status = 'published')
  );
create policy "sales edit media" on public.product_media
  for all to authenticated
  using ((select private.has_role('sales')))
  with check ((select private.has_role('sales')));

create policy "public reads active variants of published products" on public.variants
  for select to anon, authenticated
  using (
    (select private.is_staff())
    or (is_active and exists (
      select 1 from public.products p where p.id = product_id and p.status = 'published'))
  );
create policy "sales edit variants" on public.variants
  for all to authenticated
  using ((select private.has_role('sales')))
  with check ((select private.has_role('sales')));

create policy "sales read internal" on public.variant_internal
  for select to authenticated using ((select private.has_role('sales')));
create policy "admin edits internal" on public.variant_internal
  for all to authenticated
  using ((select private.has_role('admin')))
  with check ((select private.has_role('admin')));

create policy "sales read price history" on public.variant_price_history
  for select to authenticated using ((select private.has_role('sales')));

create policy "anyone reads exchange rates" on public.exchange_rates
  for select to anon, authenticated using (true);
create policy "admin adds exchange rates" on public.exchange_rates
  for insert to authenticated with check ((select private.has_role('admin')));

-- ---------------------------------------------------------------------------
-- Inventory: staff read; writes only via stock_* functions (no write policies)
-- ---------------------------------------------------------------------------

create policy "staff read locations" on public.locations
  for select to authenticated using ((select private.is_staff()));
create policy "warehouse edits locations" on public.locations
  for all to authenticated
  using ((select private.has_role('warehouse')))
  with check ((select private.has_role('warehouse')));

create policy "staff read units" on public.stock_units
  for select to authenticated using ((select private.is_staff()));

create policy "staff read movements" on public.stock_movements
  for select to authenticated using ((select private.is_staff()));

-- ---------------------------------------------------------------------------
-- Sales data: never readable by anon. Inserts arrive via submit_* functions.
-- ---------------------------------------------------------------------------

create policy "sales read customers" on public.customers
  for select to authenticated using ((select private.has_role('sales', 'service')));
create policy "sales edit customers" on public.customers
  for update to authenticated
  using ((select private.has_role('sales')))
  with check ((select private.has_role('sales')));

create policy "sales read quotes" on public.quote_requests
  for select to authenticated using ((select private.has_role('sales')));
create policy "sales update quotes" on public.quote_requests
  for update to authenticated
  using ((select private.has_role('sales')))
  with check ((select private.has_role('sales')));

create policy "sales read quote items" on public.quote_items
  for select to authenticated using ((select private.has_role('sales')));
create policy "sales price quote items" on public.quote_items
  for update to authenticated
  using ((select private.has_role('sales')))
  with check ((select private.has_role('sales')));

create policy "service desk reads requests" on public.service_requests
  for select to authenticated using ((select private.has_role('sales', 'service')));
create policy "service desk updates requests" on public.service_requests
  for update to authenticated
  using ((select private.has_role('sales', 'service')))
  with check ((select private.has_role('sales', 'service')));

create policy "staff read attachments" on public.attachments
  for select to authenticated using ((select private.has_role('sales', 'service')));

-- Belt and braces on top of RLS: the anonymous role gets no write privileges at all.
revoke insert, update, delete, truncate on all tables in schema public from anon;
revoke all on all tables in schema private from anon, authenticated;
