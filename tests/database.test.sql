-- Database behaviour tests: RLS, API functions, stock state machine.
-- Runs inside one transaction and rolls back, so it is safe on a local
-- `supabase start` database that has the seed loaded:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f tests/database.test.sql
-- Any failed check aborts with an error naming the check.

\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null
begin;

-- ---------------------------------------------------------------------------
-- Helpers and fixtures (as postgres)
-- ---------------------------------------------------------------------------

create function pg_temp.ok(p_cond boolean, p_what text)
returns void language plpgsql as $$
begin
  if p_cond is not true then
    raise exception 'FAILED: %', p_what;
  end if;
  raise notice 'ok - %', p_what;
end;
$$;

create function pg_temp.fails(p_sql text, p_like text, p_what text)
returns void language plpgsql as $$
declare
  v_err text;
begin
  begin
    execute p_sql;
  exception when others then
    v_err := sqlerrm;
  end;
  if v_err is null then
    raise exception 'FAILED: % (statement succeeded: %)', p_what, p_sql;
  elsif v_err not like p_like then
    raise exception 'FAILED: % (expected error like "%", got "%")', p_what, p_like, v_err;
  end if;
  raise notice 'ok - %', p_what;
end;
$$;

create function pg_temp.as_user(p_role text, p_sub text default null)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('role', p_role, 'sub', p_sub)::text, true);
  execute format('set local role %I', p_role);
end;
$$;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'warehouse@test'),
  ('00000000-0000-0000-0000-0000000000a2', 'sales@test'),
  ('00000000-0000-0000-0000-0000000000a3', 'admin@test'),
  ('00000000-0000-0000-0000-0000000000a4', 'service@test'),
  ('00000000-0000-0000-0000-0000000000a5', 'not-staff@test');

insert into public.staff_profiles (user_id, display_name, role) values
  ('00000000-0000-0000-0000-0000000000a1', 'Warehouse', 'warehouse'),
  ('00000000-0000-0000-0000-0000000000a2', 'Sales', 'sales'),
  ('00000000-0000-0000-0000-0000000000a3', 'Admin', 'admin'),
  ('00000000-0000-0000-0000-0000000000a4', 'Service', 'service');

with p as (
  insert into public.products (slug, model, name_th, name_en, category_id, status)
  values ('draft-machine', 'FEA-DRAFT', 'ร่าง', 'Draft', 'cardio', 'draft')
  returning id
)
insert into public.variants (sku, product_id, label, stock_status, price_thb)
select 'FEA-DRAFT-1', id, 'ร่าง', 'ready', 1000 from p;

-- ---------------------------------------------------------------------------
-- Anonymous visitor (anon key)
-- ---------------------------------------------------------------------------

select pg_temp.as_user('anon');

select pg_temp.ok((select count(*) from public.products_public) = 10, 'anon sees the 10 published products');
select pg_temp.ok(not exists (select 1 from public.products where slug = 'draft-machine'), 'anon cannot see draft products');
select pg_temp.ok(not exists (select 1 from public.variants where sku = 'FEA-DRAFT-1'), 'anon cannot see draft variants');
select pg_temp.ok(
  (select is_new from public.products_public where slug = 'fea-pl01-chest-press')
  and not (select is_new from public.products_public where slug = 'fea-t900-treadmill'),
  'is_new follows arrived_at (45 days)');
select pg_temp.ok(
  (select jsonb_array_length(variants) from public.products_public where slug = 'fea-pl01-chest-press') = 3,
  'products_public embeds variants');
select pg_temp.ok(
  (select image_path from public.products_public where slug = 'fea-pl01-chest-press') is not null,
  'products_public exposes the primary image');
select pg_temp.ok((select count(*) from public.variant_internal) = 0, 'anon cannot read costs');
select pg_temp.ok((select count(*) from public.customers) = 0, 'anon cannot read customers');
select pg_temp.ok((select count(*) from public.stock_units) = 0, 'anon cannot read stock units');
select pg_temp.ok((select thb_per_unit from public.current_exchange_rates where currency = 'USD') = 36, 'anon reads the current USD rate');
select pg_temp.fails($$insert into public.quote_requests (reference) values ('x')$$,
  'permission denied%', 'anon cannot insert quotes directly');
select pg_temp.fails($$select public.submit_quote_request('{}')$$,
  'permission denied for function%', 'anon cannot call submit_quote_request');
select pg_temp.fails($$select * from public.won_quotes_monthly$$,
  'permission denied%', 'anon cannot read won_quotes_monthly');

reset role;

-- ---------------------------------------------------------------------------
-- Backend (service_role): public form submissions
-- ---------------------------------------------------------------------------

select pg_temp.as_user('service_role');

select set_config('test.quote1', public.submit_quote_request($${
  "contact_name": " สมชาย ",
  "contact_method": "line",
  "contact_value": "SomchaiGym",
  "country": "ไทย",
  "city": "เชียงใหม่",
  "installation": "yes",
  "access": {"upper_floor": true, "lift": false, "stairs": true, "truck_access": true},
  "budget": "1,500,000 บาท",
  "items": [
    {"sku": "FEA-PL01-SLV", "qty": 2},
    {"sku": "FEA-PL01-SLV", "qty": 1, "note": "เพิ่มอีก 1"},
    {"sku": "FEA-PL03-STD", "qty": 4}
  ]
}$$)::text, true);

select pg_temp.ok(current_setting('test.quote1')::jsonb ->> 'reference' ~ '^Q-[0-9]{4}-[0-9]{5}$', 'quote gets a Q-YYYY-NNNNN reference');
select pg_temp.ok(
  (select qty from public.quote_items where quote_id = (current_setting('test.quote1')::jsonb ->> 'id')::uuid and sku = 'FEA-PL01-SLV') = 3,
  'duplicate quote lines are merged');
select pg_temp.ok(
  (select list_price_thb from public.quote_items where quote_id = (current_setting('test.quote1')::jsonb ->> 'id')::uuid and sku = 'FEA-PL03-STD') is null,
  'quote-only SKU keeps a null price, never 0');
select pg_temp.ok(
  (select access_upper_floor and access_stairs and not access_lift from public.quote_requests where id = (current_setting('test.quote1')::jsonb ->> 'id')::uuid),
  'access checkboxes are stored');

select public.submit_quote_request($${"contact_name": "สมชาย", "contact_method": "line",
  "contact_value": "somchaigym", "country": "ไทย", "city": "เชียงใหม่", "items": [{"sku": "FEA-T900-BLK", "qty": 1}]}$$);
select pg_temp.ok((select count(*) from public.customers where contact_method = 'line') = 1, 'same LINE ID (any case) maps to one customer');

select pg_temp.fails($$select public.submit_quote_request('{"contact_method":"line","contact_value":"a","country":"TH","city":"x","items":[{"sku":"FEA-T900-BLK","qty":1}]}')$$,
  'missing:contact_name', 'quote requires a contact name');
select pg_temp.fails($$select public.submit_quote_request('{"contact_name":"a","contact_method":"fax","contact_value":"a","country":"TH","city":"x","items":[{"sku":"FEA-T900-BLK","qty":1}]}')$$,
  'invalid:contact_method', 'quote rejects unknown contact methods');
select set_config('test.advice', public.submit_quote_request(
  '{"contact_name":"a","contact_method":"email","contact_value":"a@b.co","country":"TH","city":"x","items":[]}')::text, true);
select pg_temp.ok(
  (select count(*) from public.quote_items where quote_id = (current_setting('test.advice')::jsonb ->> 'id')::uuid) = 0,
  'advice-only quote request (no items) is accepted');
select pg_temp.fails($$select public.submit_quote_request('{"contact_name":"a","contact_method":"line","contact_value":"a","country":"TH","city":"x","items":{"sku":"x"}}')$$,
  'invalid:items', 'quote items must be a list');
select pg_temp.fails($$select public.submit_quote_request('{"contact_name":"a","contact_method":"line","contact_value":"a","country":"TH","city":"x","items":[{"sku":"FEA-DRAFT-1","qty":1}]}')$$,
  'unknown_sku:FEA-DRAFT-1', 'quote rejects SKUs of unpublished products');
select pg_temp.fails($$select public.submit_quote_request('{"contact_name":"a","contact_method":"line","contact_value":"a","country":"TH","city":"x","items":[{"sku":"FEA-T900-BLK","qty":0}]}')$$,
  'invalid:qty', 'quote rejects qty 0');
select pg_temp.fails($$select public.submit_quote_request('{"contact_name":"a","contact_method":"line","contact_value":"a","country":"TH","city":"x","items":[{"sku":"FEA-T900-BLK"}]}')$$,
  'invalid:qty', 'quote rejects a missing qty');

select pg_temp.ok(
  (select unit_cost_thb from public.quote_items where quote_id = (current_setting('test.quote1')::jsonb ->> 'id')::uuid and sku = 'FEA-PL01-SLV') = 55180,
  'quote line snapshots unit cost for margin analysis');
select pg_temp.ok(not exists (
  select 1 from information_schema.routines where routine_schema = 'public' and routine_name = 'place_order'),
  'no online ordering function exists (catalog + quotation only)');

select set_config('test.sr1', public.submit_service_request(
  '{"product_model":"fea-pl01","unit_code":"u-000184","symptom":"เสียงดัง","contact_value":"LINE: abc"}')::text, true);
select pg_temp.ok(
  (select unit_code = 'U-000184' and product_model = 'FEA-PL01' from public.service_requests where reference = current_setting('test.sr1')::jsonb ->> 'reference'),
  'service request links a known unit code');
select public.submit_service_request('{"product_model":"X","unit_code":"ABC","symptom":"s","contact_value":"c"}');
select pg_temp.ok(
  (select unit_code is null and unit_code_input = 'ABC' from public.service_requests where unit_code_input = 'ABC'),
  'unknown unit code is kept as typed, not linked');
select pg_temp.ok(
  public.register_attachment(current_setting('test.quote1')::jsonb ->> 'reference', 'quote-attachments',
    'Q/plan.pdf', 'application/pdf', 1024) is not null,
  'attachment registers against a quote reference');
select pg_temp.fails($$select public.register_attachment('Q-0000-00000', 'quote-attachments', 'x', 'application/pdf', 1)$$,
  'unknown_reference', 'attachment needs a real reference');

reset role;

-- ---------------------------------------------------------------------------
-- Warehouse staff: stock state machine
-- ---------------------------------------------------------------------------

select pg_temp.as_user('authenticated', '00000000-0000-0000-0000-0000000000a1');

select pg_temp.ok((select state from public.stock_apply_action('U-000201', 'receive')) = 'available', 'receive: inbound -> available');
select pg_temp.fails($$select public.stock_apply_action('U-000201', 'receive')$$,
  'invalid_transition:available:receive', 'cannot receive twice');
select pg_temp.ok((select state from public.stock_apply_action('U-000201', 'move', 'SHOWROOM-PL')) = 'showroom', 'moving into the showroom makes it a showroom unit');
select pg_temp.ok((select state from public.stock_apply_action('U-000201', 'move', 'WH-A-02-14')) = 'available', 'moving out of the showroom makes it available');
select pg_temp.ok(
  (select state = 'reserved' and quote_id = (current_setting('test.quote1')::jsonb ->> 'id')::uuid
   from public.stock_apply_action('U-000184', 'reserve', null, (current_setting('test.quote1')::jsonb ->> 'id')::uuid, 'Q')),
  'reserve links the quote');
select pg_temp.ok((select state from public.stock_apply_action('U-000184', 'dispatch')) = 'dispatched', 'dispatch a reserved unit');
select pg_temp.fails($$select public.stock_apply_action('U-000184', 'move', 'SHOWROOM-PL')$$,
  'invalid_transition:dispatched:move', 'dispatched units cannot be moved');
select pg_temp.fails($$select public.stock_apply_action('U-000184', 'move', 'NOWHERE')$$,
  'unknown_location', 'move needs a known location');
select pg_temp.ok(
  (select count(*) = 3 and bool_and(actor = '00000000-0000-0000-0000-0000000000a1')
   from public.stock_movements where unit_code = 'U-000201'),
  'every action is logged with the staff user as actor');
select pg_temp.ok((select state from public.stock_register_unit('U-000300', 'FEA-T900-BLK', 'RECEIVING', 'SN-1')) = 'inbound', 'register a new unit as inbound');
update public.stock_units set state = 'available' where unit_code = 'U-000300';
select pg_temp.ok((select state from public.stock_units where unit_code = 'U-000300') = 'inbound',
  'warehouse cannot edit units directly (must use stock functions)');
select pg_temp.ok((select count(*) from public.variant_internal) = 0, 'warehouse cannot read costs');
select pg_temp.ok((select count(*) from public.customers) = 0, 'warehouse cannot read customers');
select pg_temp.ok((select available from public.variant_stock_summary where sku = 'FEA-PL02-BLK') = 1, 'stock summary counts available units');

reset role;
select pg_temp.fails($$update public.stock_movements set note = 'edited'$$,
  '%append-only%', 'movement log cannot be edited, even by the owner');
select pg_temp.fails($$delete from public.stock_movements$$,
  '%append-only%', 'movement log cannot be deleted, even by the owner');

-- ---------------------------------------------------------------------------
-- Sales staff
-- ---------------------------------------------------------------------------

select pg_temp.as_user('authenticated', '00000000-0000-0000-0000-0000000000a2');

select pg_temp.fails($$select public.stock_apply_action('U-000185', 'release')$$,
  'forbidden', 'sales cannot move stock');
select pg_temp.ok((select count(*) from public.quote_requests) = 3, 'sales reads quote requests');
select pg_temp.ok((select count(*) from public.variant_internal) > 0, 'sales reads costs');
select pg_temp.ok(exists (select 1 from public.products where slug = 'draft-machine'), 'staff see draft products');
update public.variants set price_thb = 92000 where sku = 'FEA-PL01-SLV';
select pg_temp.ok(
  (select old_value = 89000 and new_value = 92000 and changed_by = '00000000-0000-0000-0000-0000000000a2'
   from public.variant_price_history where sku = 'FEA-PL01-SLV'),
  'price change is recorded with who changed it');
update public.variant_internal set cost_thb = 1 where sku = 'FEA-PL01-SLV';
select pg_temp.ok((select cost_thb from public.variant_internal where sku = 'FEA-PL01-SLV') = 55180, 'only admin edits costs');
update public.quote_items set quoted_unit_price_thb = 85000 where quote_id = (current_setting('test.quote1')::jsonb ->> 'id')::uuid and sku = 'FEA-PL01-SLV';
update public.quote_items set quoted_unit_price_thb = 70000, unit_cost_thb = 40000 where quote_id = (current_setting('test.quote1')::jsonb ->> 'id')::uuid and sku = 'FEA-PL03-STD';
update public.quote_requests set quoted_total_thb = 535000, quoted_at = now(), status = 'won', closed_at = now()
  where id = (current_setting('test.quote1')::jsonb ->> 'id')::uuid;
select pg_temp.ok(
  (select quoted_vat_thb = 37450 and quoted_grand_total_thb = 572450 from public.quote_requests
   where id = (current_setting('test.quote1')::jsonb ->> 'id')::uuid),
  'quotation adds 7% VAT on top of the ex-VAT total');
select pg_temp.ok(
  (select revenue_thb = 535000 and cost_thb = 325540 and gross_profit_thb = 209460 from public.won_quotes_monthly),
  'won_quotes_monthly computes revenue, cost and gross profit');
select pg_temp.ok((select requests = 3 and won = 1 and win_rate = 1 from public.quote_funnel_monthly), 'quote_funnel_monthly counts requests and win rate');
select pg_temp.fails($$insert into public.staff_profiles (user_id, display_name, role) values ('00000000-0000-0000-0000-0000000000a5', 'x', 'admin')$$,
  'new row violates row-level security policy%', 'sales cannot create staff accounts');

reset role;

-- ---------------------------------------------------------------------------
-- Service staff, signed-in non-staff, admin
-- ---------------------------------------------------------------------------

select pg_temp.as_user('authenticated', '00000000-0000-0000-0000-0000000000a4');
select pg_temp.ok((select count(*) from public.service_requests) = 2, 'service staff read service requests');
select pg_temp.ok((select count(*) from public.quote_requests) = 0, 'service staff cannot read quotes');
select pg_temp.ok((select state from public.stock_apply_action('U-000185', 'service')) = 'service', 'service staff can pull a unit into service');
select pg_temp.fails($$select public.stock_apply_action('U-000201', 'reserve')$$,
  'forbidden', 'service staff cannot reserve stock');
reset role;

select pg_temp.as_user('authenticated', '00000000-0000-0000-0000-0000000000a5');
select pg_temp.ok((select count(*) from public.products_public) = 10, 'signed-in non-staff sees the public catalog');
select pg_temp.ok((select count(*) from public.quote_requests) = 0, 'signed-in non-staff sees no quotes');
select pg_temp.ok((select count(*) from public.stock_units) = 0, 'signed-in non-staff sees no stock');
select pg_temp.fails($$select public.stock_apply_action('U-000201', 'reserve')$$,
  'forbidden', 'signed-in non-staff cannot move stock');
reset role;

select pg_temp.as_user('authenticated', '00000000-0000-0000-0000-0000000000a3');
update public.variant_internal set cost_thb = 50000 where sku = 'FEA-PL01-SLV';
select pg_temp.ok((select cost_thb from public.variant_internal where sku = 'FEA-PL01-SLV') = 50000, 'admin edits costs');
select pg_temp.ok((select count(*) from public.staff_profiles) = 4, 'admin reads all staff');
reset role;

-- ---------------------------------------------------------------------------
-- Google login profiles and the staff allowlist
-- ---------------------------------------------------------------------------

insert into private.staff_allowlist (email, role, display_name)
values ('new-sales@test', 'sales', 'New Sales');

-- Email/password sign-up with an allowlisted address, not yet confirmed.
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
values ('00000000-0000-0000-0000-0000000000b1', 'New-Sales@test', null, '{"full_name": "Someone"}');
select pg_temp.ok(
  exists (select 1 from public.customer_profiles where user_id = '00000000-0000-0000-0000-0000000000b1'),
  'sign-up creates a customer profile');
select pg_temp.ok(
  not exists (select 1 from public.staff_profiles where user_id = '00000000-0000-0000-0000-0000000000b1'),
  'unconfirmed email gets no staff rights, even if allowlisted');

select pg_temp.as_user('authenticated', '00000000-0000-0000-0000-0000000000b1');
select pg_temp.ok((public.ensure_auth_profiles() ->> 'is_staff')::boolean = false,
  'ensure_auth_profiles cannot grant staff to an unconfirmed email');
reset role;

-- The address gets confirmed later.
update auth.users set email_confirmed_at = now() where id = '00000000-0000-0000-0000-0000000000b1';
select pg_temp.ok(
  (select role = 'sales' and is_active from public.staff_profiles where user_id = '00000000-0000-0000-0000-0000000000b1'),
  'confirming the email grants the allowlisted role');

-- Google sign-in: confirmed on insert.
insert into auth.users (id, email, email_confirmed_at)
values ('00000000-0000-0000-0000-0000000000b2', 'chatchye3@gmail.com', now());
select pg_temp.ok(
  (select role = 'admin' from public.staff_profiles where user_id = '00000000-0000-0000-0000-0000000000b2'),
  'confirmed allowlisted Google account becomes staff');

-- Admin disables and demotes; the next page view must not undo it.
update public.staff_profiles set is_active = false where user_id = '00000000-0000-0000-0000-0000000000b1';
update public.staff_profiles set role = 'warehouse' where user_id = '00000000-0000-0000-0000-0000000000b2';
select pg_temp.as_user('authenticated', '00000000-0000-0000-0000-0000000000b1');
select pg_temp.ok((public.ensure_auth_profiles() ->> 'is_staff')::boolean = false,
  'disabled staff stays disabled after ensure_auth_profiles');
reset role;
select pg_temp.as_user('authenticated', '00000000-0000-0000-0000-0000000000b2');
select pg_temp.ok((public.ensure_auth_profiles() ->> 'role') = 'warehouse',
  'role changed by an admin is not reset by the allowlist');
reset role;

select pg_temp.as_user('anon');
select pg_temp.fails($$select public.ensure_auth_profiles()$$,
  'permission denied for function%', 'anon cannot call ensure_auth_profiles');
select pg_temp.fails($$select private.sync_auth_profiles('00000000-0000-0000-0000-0000000000b1')$$,
  'permission denied for function%', 'anon cannot call the private sync helper');
reset role;
select pg_temp.as_user('authenticated', '00000000-0000-0000-0000-0000000000a5');
select pg_temp.fails($$select private.sync_auth_profiles('00000000-0000-0000-0000-0000000000b2')$$,
  'permission denied for function%', 'signed-in users cannot call the private sync helper');
select pg_temp.ok((select count(*) from public.customer_profiles) = 1, 'customers only see their own profile');
reset role;

\echo 'All database tests passed.'
rollback;
