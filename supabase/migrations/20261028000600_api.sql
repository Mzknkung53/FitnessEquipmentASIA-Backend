-- The contract between the database and the backend.
--
-- Read models (views, security_invoker so RLS of the caller applies):
--   products_public          storefront catalog, safe for anon
--   current_exchange_rates   latest THB rate per currency
--   variant_stock_summary    unit counts per SKU and state (staff)
--   sales_monthly            revenue, cost and gross margin per month (sales/admin)
--   quote_funnel_monthly     quote volume, win rate, response time (sales/admin)
--
-- Write functions:
--   submit_quote_request, place_order, submit_service_request, register_attachment
--       -> service_role only. The backend validates, rate-limits, then calls these.
--   stock_register_unit, stock_apply_action
--       -> signed-in staff. The backend forwards the staff user's JWT so auth.uid()
--          is recorded as the actor.
--
-- Validation errors raise SQLSTATE 22023 with a short machine-readable message
-- (e.g. 'item_not_purchasable:FEA-PL03-STD'); the backend maps them to HTTP 400.

-- ---------------------------------------------------------------------------
-- Read models
-- ---------------------------------------------------------------------------

create view public.products_public
with (security_invoker = true)
as
select
  p.slug,
  p.model,
  p.name_th,
  p.name_en,
  p.name_zh,
  p.category_id,
  p.summary,
  p.setting,
  coalesce(p.new_override, p.arrived_at > (now() at time zone 'Asia/Bangkok')::date - 45, false) as is_new,
  p.curated_rank,
  p.pictogram,
  p.unit_note,
  p.specs,
  p.usage_steps,
  p.is_demo,
  img.storage_path as image_path,
  img.width as image_width,
  img.height as image_height,
  img.alt as image_alt,
  coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', m.kind, 'storage_path', m.storage_path, 'external_url', m.external_url,
      'width', m.width, 'height', m.height, 'alt', m.alt) order by m.kind, m.sort)
    from public.product_media m
    where m.product_id = p.id
  ), '[]'::jsonb) as media,
  coalesce((
    select jsonb_agg(jsonb_build_object(
      'sku', v.sku, 'label', v.label, 'swatch', v.swatch, 'status', v.stock_status,
      'price_thb', v.price_thb, 'lead_time', v.lead_time) order by v.sort, v.sku)
    from public.variants v
    where v.product_id = p.id and v.is_active
  ), '[]'::jsonb) as variants
from public.products p
left join lateral (
  select m.storage_path, m.width, m.height, m.alt
  from public.product_media m
  where m.product_id = p.id and m.kind = 'image'
  order by m.sort
  limit 1
) img on true
where p.status = 'published';

create view public.current_exchange_rates
with (security_invoker = true)
as
select distinct on (currency) currency, thb_per_unit, source, effective_at
from public.exchange_rates
where effective_at <= now()
order by currency, effective_at desc;

create view public.variant_stock_summary
with (security_invoker = true)
as
select
  v.sku,
  v.stock_status,
  count(u.unit_code) filter (where u.state = 'inbound') as inbound,
  count(u.unit_code) filter (where u.state = 'available') as available,
  count(u.unit_code) filter (where u.state = 'reserved') as reserved,
  count(u.unit_code) filter (where u.state = 'showroom') as showroom,
  count(u.unit_code) filter (where u.state = 'dispatched') as dispatched,
  count(u.unit_code) filter (where u.state = 'service') as service,
  -- 'ready' on the web but nothing sellable on hand: staff should update the status.
  (v.stock_status = 'ready' and count(u.unit_code) filter (where u.state = 'available') = 0) as needs_review
from public.variants v
left join public.stock_units u on u.sku = v.sku
group by v.sku, v.stock_status;

create view public.sales_monthly
with (security_invoker = true)
as
select
  date_trunc('month', o.created_at at time zone 'Asia/Bangkok')::date as month,
  count(distinct o.id) as orders,
  sum(i.line_total_thb) as revenue_thb,
  sum(i.qty * i.unit_cost_thb) as cost_thb,
  sum(i.line_total_thb) - sum(i.qty * i.unit_cost_thb) as gross_profit_thb,
  round((sum(i.line_total_thb) - sum(i.qty * i.unit_cost_thb)) / nullif(sum(i.line_total_thb), 0), 4) as gross_margin,
  count(*) filter (where i.unit_cost_thb is null) as lines_missing_cost
from public.orders o
join public.order_items i on i.order_id = o.id
where o.status <> 'cancelled'
group by 1;

create view public.quote_funnel_monthly
with (security_invoker = true)
as
select
  date_trunc('month', q.created_at at time zone 'Asia/Bangkok')::date as month,
  count(*) as requests,
  count(*) filter (where q.quoted_at is not null) as quoted,
  count(*) filter (where q.status = 'won') as won,
  count(*) filter (where q.status = 'lost') as lost,
  round(count(*) filter (where q.status = 'won')::numeric
        / nullif(count(*) filter (where q.status in ('won', 'lost')), 0), 4) as win_rate,
  round(avg(extract(epoch from q.quoted_at - q.created_at) / 3600)::numeric, 1) as avg_hours_to_quote,
  sum(q.quoted_total_thb) filter (where q.status = 'won') as won_value_thb
from public.quote_requests q
group by 1;

revoke all on public.sales_monthly, public.quote_funnel_monthly from anon;

-- ---------------------------------------------------------------------------
-- Private helpers for the write functions
-- ---------------------------------------------------------------------------

create function private.bad_input(p_code text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception '%', p_code using errcode = '22023';
end;
$$;

-- Required, trimmed, length-capped text field from a JSON payload.
create function private.req_text(p jsonb, p_key text, p_max int default 200)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := nullif(btrim(p ->> p_key), '');
begin
  if v is null then
    perform private.bad_input('missing:' || p_key);
  end if;
  if length(v) > p_max then
    perform private.bad_input('too_long:' || p_key);
  end if;
  return v;
end;
$$;

create function private.opt_text(p jsonb, p_key text, p_max int default 200)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := nullif(btrim(p ->> p_key), '');
begin
  if length(v) > p_max then
    perform private.bad_input('too_long:' || p_key);
  end if;
  return v;
end;
$$;

-- Find or create the customer for a contact handle; refresh the details we were given.
create function private.upsert_customer(
  p_name text, p_company text, p_method public.contact_method, p_value text,
  p_email text, p_phone text, p_country text, p_city text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.customers as c
    (display_name, company, contact_method, contact_value, email, phone, country, city)
  values (p_name, p_company, p_method, p_value, p_email, p_phone, p_country, p_city)
  on conflict (contact_method, lower(contact_value)) do update set
    display_name = excluded.display_name,
    company = coalesce(excluded.company, c.company),
    email = coalesce(excluded.email, c.email),
    phone = coalesce(excluded.phone, c.phone),
    country = coalesce(excluded.country, c.country),
    city = coalesce(excluded.city, c.city)
  returning id into v_id;
  return v_id;
end;
$$;

-- Payload items -> one row per SKU (duplicates summed), validated against the public catalog.
create function private.read_items(p jsonb)
returns table (sku text, qty int, note text, price_thb numeric, stock_status public.stock_status)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_missing text;
begin
  if jsonb_typeof(p -> 'items') is distinct from 'array'
     or jsonb_array_length(p -> 'items') = 0 then
    perform private.bad_input('missing:items');
  end if;
  if jsonb_array_length(p -> 'items') > 100 then
    perform private.bad_input('too_many:items');
  end if;
  if exists (
    select 1 from jsonb_array_elements(p -> 'items') e
    where coalesce(e ->> 'qty', '') !~ '^[1-9][0-9]{0,3}$'
  ) then
    perform private.bad_input('invalid:qty');
  end if;

  select e ->> 'sku' into v_missing
  from jsonb_array_elements(p -> 'items') e
  where not exists (
    select 1
    from public.variants v
    join public.products pr on pr.id = v.product_id
    where v.sku = e ->> 'sku' and v.is_active and pr.status = 'published'
  )
  limit 1;
  if found then
    perform private.bad_input('unknown_sku:' || coalesce(v_missing, 'null'));
  end if;

  return query
  select v.sku, least(sum((e ->> 'qty')::int), 9999)::int,
         nullif(left(string_agg(btrim(e ->> 'note'), ' / '), 500), ''),
         v.price_thb, v.stock_status
  from jsonb_array_elements(p -> 'items') e
  join public.variants v on v.sku = e ->> 'sku'
  group by v.sku, v.price_thb, v.stock_status;
end;
$$;

-- ---------------------------------------------------------------------------
-- Public form submissions (service_role only)
-- ---------------------------------------------------------------------------

/*
  submit_quote_request(payload) -> { id, reference }
  payload: {
    contact_name, company?, contact_method, contact_value, country, city, postcode?,
    installation?: 'yes'|'no'|'unsure',
    access?: { upper_floor, lift, stairs, truck_access },
    target_date?: 'YYYY-MM-DD', budget?, message?, source?,
    items: [{ sku, qty, note? }]
  }
*/
create function public.submit_quote_request(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := private.req_text(payload, 'contact_name', 120);
  v_company text := private.opt_text(payload, 'company', 160);
  v_method public.contact_method;
  v_value text := private.req_text(payload, 'contact_value', 160);
  v_country text := private.req_text(payload, 'country', 80);
  v_city text := private.req_text(payload, 'city', 120);
  v_customer uuid;
  v_quote uuid;
  v_ref text;
begin
  begin
    v_method := (payload ->> 'contact_method')::public.contact_method;
  exception when invalid_text_representation then
    perform private.bad_input('invalid:contact_method');
  end;
  if v_method is null then
    perform private.bad_input('missing:contact_method');
  end if;

  v_customer := private.upsert_customer(
    v_name, v_company, v_method, v_value,
    case when v_method = 'email' then v_value end,
    case when v_method in ('phone', 'whatsapp') then v_value end,
    v_country, v_city);

  v_ref := private.next_reference('Q');

  insert into public.quote_requests (
    reference, customer_id, contact_name, company, contact_method, contact_value,
    country, city, postcode, installation,
    access_upper_floor, access_lift, access_stairs, access_truck,
    target_date, budget_text, message, source)
  values (
    v_ref, v_customer, v_name, v_company, v_method, v_value,
    v_country, v_city, private.opt_text(payload, 'postcode', 20),
    coalesce((payload ->> 'installation')::public.installation_choice, 'unsure'),
    coalesce((payload #>> '{access,upper_floor}')::boolean, false),
    coalesce((payload #>> '{access,lift}')::boolean, false),
    coalesce((payload #>> '{access,stairs}')::boolean, false),
    coalesce((payload #>> '{access,truck_access}')::boolean, false),
    (payload ->> 'target_date')::date,
    private.opt_text(payload, 'budget', 120),
    private.opt_text(payload, 'message', 4000),
    coalesce(private.opt_text(payload, 'source', 40), 'web'))
  returning id into v_quote;

  insert into public.quote_items (quote_id, sku, qty, note, list_price_thb)
  select v_quote, i.sku, i.qty, i.note, i.price_thb
  from private.read_items(payload) i;

  return jsonb_build_object('id', v_quote, 'reference', v_ref);
exception
  when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
    raise exception 'invalid:payload' using errcode = '22023';
end;
$$;

/*
  place_order(payload) -> { id, reference, subtotal_thb }
  Direct checkout. Only SKUs with a fixed price and stock_status 'ready'.
  Prices come from the database, never from the client.
  payload: {
    contact_name, phone, email?, country, city, postcode?, address?,
    fulfilment: 'delivery'|'pickup', payment_option: 'bank_transfer'|'card'|'deposit',
    currency?: 'THB'|'USD', items: [{ sku, qty }]
  }
*/
create function public.place_order(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := private.req_text(payload, 'contact_name', 120);
  v_phone text := private.req_text(payload, 'phone', 40);
  v_email text := private.opt_text(payload, 'email', 160);
  v_country text := private.req_text(payload, 'country', 80);
  v_city text := private.req_text(payload, 'city', 120);
  v_address text := private.opt_text(payload, 'address', 1000);
  v_fulfilment public.fulfilment_method;
  v_payment public.payment_option;
  v_currency text := upper(coalesce(nullif(payload ->> 'currency', ''), 'THB'));
  v_rate numeric;
  v_bad text;
  v_customer uuid;
  v_order uuid;
  v_ref text;
  v_subtotal numeric;
begin
  begin
    v_fulfilment := (payload ->> 'fulfilment')::public.fulfilment_method;
    v_payment := (payload ->> 'payment_option')::public.payment_option;
  exception when invalid_text_representation then
    perform private.bad_input('invalid:fulfilment_or_payment');
  end;
  if v_fulfilment is null or v_payment is null then
    perform private.bad_input('missing:fulfilment_or_payment');
  end if;
  if v_fulfilment = 'delivery' and v_address is null then
    perform private.bad_input('missing:address');
  end if;

  if v_currency <> 'THB' then
    select r.thb_per_unit into v_rate from public.current_exchange_rates r where r.currency = v_currency;
    if v_rate is null then
      perform private.bad_input('unsupported:currency');
    end if;
  end if;

  select i.sku into v_bad from private.read_items(payload) i
  where i.price_thb is null or i.stock_status <> 'ready'
  limit 1;
  if found then
    perform private.bad_input('item_not_purchasable:' || v_bad);
  end if;

  select sum(i.qty * i.price_thb) into v_subtotal from private.read_items(payload) i;

  v_customer := private.upsert_customer(
    v_name, null, 'phone', v_phone, v_email, v_phone, v_country, v_city);
  v_ref := private.next_reference('SO');

  insert into public.orders (
    reference, customer_id, contact_name, phone, email, country, city, postcode, address,
    fulfilment, payment_option, display_currency, fx_thb_per_unit, subtotal_thb,
    shipping_thb)
  values (
    v_ref, v_customer, v_name, v_phone, v_email, v_country, v_city,
    private.opt_text(payload, 'postcode', 20), v_address,
    v_fulfilment, v_payment, v_currency, v_rate, v_subtotal,
    case when v_fulfilment = 'pickup' then 0 end)
  returning id into v_order;

  insert into public.order_items (order_id, sku, qty, unit_price_thb, unit_cost_thb)
  select v_order, i.sku, i.qty, i.price_thb, vi.cost_thb
  from private.read_items(payload) i
  left join public.variant_internal vi on vi.sku = i.sku;

  return jsonb_build_object('id', v_order, 'reference', v_ref, 'subtotal_thb', v_subtotal);
end;
$$;

/*
  submit_service_request(payload) -> { id, reference }
  payload: { product_model, unit_code?, symptom, contact_value }
*/
create function public.submit_service_request(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_input text := upper(private.opt_text(payload, 'unit_code', 60));
  v_id uuid;
  v_ref text := private.next_reference('SR');
begin
  insert into public.service_requests (
    reference, product_model, unit_code_input, unit_code, symptom, contact_value)
  values (
    v_ref,
    upper(private.req_text(payload, 'product_model', 60)),
    v_input,
    (select u.unit_code from public.stock_units u where u.unit_code = v_input),
    private.req_text(payload, 'symptom', 4000),
    private.req_text(payload, 'contact_value', 160))
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'reference', v_ref);
end;
$$;

/*
  register_attachment(reference, bucket, storage_path, mime_type, size_bytes) -> attachment id
  Call after the backend has uploaded the file to the private bucket.
*/
create function public.register_attachment(
  p_reference text, p_bucket text, p_storage_path text, p_mime_type text, p_size_bytes bigint)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_quote uuid;
  v_service uuid;
  v_id uuid;
begin
  if p_mime_type !~ '^(image/(jpeg|png|webp|heic)|video/(mp4|quicktime)|application/pdf)$' then
    perform private.bad_input('unsupported:mime_type');
  end if;

  select q.id into v_quote from public.quote_requests q where q.reference = p_reference;
  select s.id into v_service from public.service_requests s where s.reference = p_reference;
  if v_quote is null and v_service is null then
    perform private.bad_input('unknown_reference');
  end if;

  insert into public.attachments (quote_id, service_request_id, bucket, storage_path, mime_type, size_bytes)
  values (v_quote, v_service, p_bucket, p_storage_path, p_mime_type, p_size_bytes)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Staff stock functions (signed-in staff; actor = auth.uid())
-- ---------------------------------------------------------------------------

create function public.stock_register_unit(
  p_unit_code text, p_sku text, p_location_id text,
  p_serial text default null, p_condition text default null, p_note text default null)
returns public.stock_units
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_unit public.stock_units;
begin
  if not private.has_role('warehouse') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  insert into public.stock_units (unit_code, sku, serial, location_id, condition, state)
  values (upper(p_unit_code), p_sku, p_serial, p_location_id, p_condition, 'inbound')
  returning * into v_unit;

  insert into public.stock_movements (unit_code, action, from_state, to_state, to_location_id, note, actor)
  values (v_unit.unit_code, 'register', null, 'inbound', p_location_id, p_note, auth.uid());

  return v_unit;
end;
$$;

/*
  stock_apply_action(unit_code, action, location_id?, order_id?, note?)

  action    allowed from                    to
  receive   inbound                         available
  move      any but dispatched              same state, new location*
  reserve   available, showroom             reserved   (order_id optional)
  release   reserved                        available  (clears order_id)
  dispatch  available, reserved             dispatched
  service   any                             service    (returns, repairs, quarantine)
  restock   service                         available

  * moving an available unit into a showroom location makes it 'showroom', and a
    showroom unit moved anywhere else becomes 'available' again.
*/
create function public.stock_apply_action(
  p_unit_code text, p_action public.stock_action,
  p_location_id text default null, p_order_id uuid default null, p_note text default null)
returns public.stock_units
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_unit public.stock_units;
  v_to_state public.unit_state;
  v_to_location text;
  v_location_kind text;
begin
  if not (private.has_role('warehouse')
          or (p_action in ('service', 'restock') and private.has_role('service'))) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_unit from public.stock_units where unit_code = upper(p_unit_code) for update;
  if not found then
    perform private.bad_input('unknown_unit');
  end if;

  v_to_location := coalesce(p_location_id, v_unit.location_id);
  select l.kind into v_location_kind from public.locations l where l.id = v_to_location and l.is_active;
  if v_location_kind is null then
    perform private.bad_input('unknown_location');
  end if;

  v_to_state := case p_action
    when 'receive' then case when v_unit.state = 'inbound' then 'available' end
    when 'move' then
      case
        when v_unit.state = 'dispatched' or p_location_id is null then null
        when v_unit.state = 'available' and v_location_kind = 'showroom' then 'showroom'
        when v_unit.state = 'showroom' and v_location_kind <> 'showroom' then 'available'
        else v_unit.state::text
      end
    when 'reserve' then case when v_unit.state in ('available', 'showroom') then 'reserved' end
    when 'release' then case when v_unit.state = 'reserved' then 'available' end
    when 'dispatch' then case when v_unit.state in ('available', 'reserved') then 'dispatched' end
    when 'service' then 'service'
    when 'restock' then case when v_unit.state = 'service' then 'available' end
  end::public.unit_state;

  if v_to_state is null then
    perform private.bad_input(format('invalid_transition:%s:%s', v_unit.state, p_action));
  end if;

  insert into public.stock_movements (
    unit_code, action, from_state, to_state, from_location_id, to_location_id, order_id, note, actor)
  values (
    v_unit.unit_code, p_action, v_unit.state, v_to_state, v_unit.location_id, v_to_location,
    coalesce(p_order_id, v_unit.order_id), p_note, auth.uid());

  update public.stock_units
  set state = v_to_state,
      location_id = v_to_location,
      received_at = case when p_action = 'receive' then (now() at time zone 'Asia/Bangkok')::date else received_at end,
      order_id = case
        when p_action = 'release' then null
        when p_action in ('reserve', 'dispatch') then coalesce(p_order_id, order_id)
        else order_id
      end
  where unit_code = v_unit.unit_code
  returning * into v_unit;

  return v_unit;
end;
$$;

-- ---------------------------------------------------------------------------
-- Execute grants. Supabase grants EXECUTE to anon/authenticated by default,
-- so take it away first and hand it back deliberately.
-- ---------------------------------------------------------------------------

revoke execute on function
  public.submit_quote_request(jsonb),
  public.place_order(jsonb),
  public.submit_service_request(jsonb),
  public.register_attachment(text, text, text, text, bigint),
  public.stock_register_unit(text, text, text, text, text, text),
  public.stock_apply_action(text, public.stock_action, text, uuid, text)
from public, anon, authenticated;

revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.has_role(public.staff_role[]) to anon, authenticated;
grant execute on function private.is_staff() to anon, authenticated;

grant execute on function
  public.submit_quote_request(jsonb),
  public.place_order(jsonb),
  public.submit_service_request(jsonb),
  public.register_attachment(text, text, text, text, bigint)
to service_role;

grant execute on function
  public.stock_register_unit(text, text, text, text, text, text),
  public.stock_apply_action(text, public.stock_action, text, uuid, text)
to authenticated, service_role;
