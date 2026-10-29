-- Staff quotation workflow: read models for the staff quote pages and the two
-- write functions behind them. Everything runs as the signed-in staff member
-- (security invoker), so the existing RLS policies (sales + admin) still decide
-- who may see or change a quote; the functions add the business rules.
--
--   quote_overview         one row per request: counts, totals, attachments
--   quote_item_detail      request lines with product names and current price
--   save_quotation()       price the lines, set the VAT rate, mark as quoted
--   set_quote_status()     take on / won / lost / cancelled / reopen
--   staff_inbox_counts()   numbers for the badges in the staff header
--
-- Status flow:  new → reviewing → quoted → won | lost
--               (new | reviewing | quoted) → cancelled;  won | lost | cancelled → reviewing (reopen)

create view public.quote_overview
with (security_invoker = true)
as
select
  q.id,
  q.reference,
  q.created_at,
  q.status,
  q.contact_name,
  q.company,
  q.contact_method,
  q.contact_value,
  q.country,
  q.city,
  q.target_date,
  q.budget_text,
  q.quoted_total_thb,
  q.vat_rate,
  q.quoted_vat_thb,
  q.quoted_grand_total_thb,
  q.quoted_at,
  q.closed_at,
  q.lost_reason,
  q.assigned_to,
  q.assigned_to = auth.uid() as assigned_to_me,
  coalesce(i.item_count, 0) as item_count,
  coalesce(i.total_qty, 0) as total_qty,
  coalesce(i.unpriced_items, 0) as unpriced_items,
  i.list_total_thb,
  (select count(*) from public.attachments a where a.quote_id = q.id) as attachment_count
from public.quote_requests q
left join lateral (
  select
    count(*) as item_count,
    sum(qi.qty) as total_qty,
    count(*) filter (where qi.list_price_thb is null) as unpriced_items,
    sum(qi.qty * qi.list_price_thb) as list_total_thb
  from public.quote_items qi
  where qi.quote_id = q.id
) i on true;

create view public.quote_item_detail
with (security_invoker = true)
as
select
  qi.id,
  qi.quote_id,
  qi.sku,
  qi.qty,
  qi.note,
  qi.list_price_thb,
  qi.quoted_unit_price_thb,
  qi.qty * qi.quoted_unit_price_thb as quoted_line_thb,
  v.label as variant_label,
  v.price_thb as current_price_thb,
  v.stock_status,
  p.slug,
  p.model,
  p.name_th,
  p.name_en
from public.quote_items qi
join public.variants v on v.sku = qi.sku
join public.products p on p.id = v.product_id;

revoke all on public.quote_overview, public.quote_item_detail from anon;

/*
  save_quotation(quote_id, lines, vat_rate, total_thb?) -> { quoted_total_thb, quoted_vat_thb, quoted_grand_total_thb }
  lines: [{ "id": <quote_items.id>, "price": <unit price THB excl. VAT> }, ...]
  Every line of the request needs a price. A request without lines (advice only)
  is quoted with total_thb instead. Prices exclude VAT; vat_rate is 7 in Thailand,
  usually 0 for exports.
*/
create function public.save_quotation(
  p_quote_id uuid, p_lines jsonb, p_vat_rate numeric, p_total_thb numeric default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_quote public.quote_requests;
  v_items int;
  v_unpriced text;
  v_total numeric;
begin
  if not private.has_role('sales') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_quote from public.quote_requests where id = p_quote_id for update;
  if not found then
    perform private.bad_input('unknown_quote');
  end if;
  if v_quote.status not in ('new', 'reviewing', 'quoted') then
    perform private.bad_input('quote_closed');
  end if;
  if p_vat_rate is null or p_vat_rate < 0 or p_vat_rate > 100 then
    perform private.bad_input('invalid:vat_rate');
  end if;
  if jsonb_typeof(coalesce(p_lines, '[]')) <> 'array' then
    perform private.bad_input('invalid:lines');
  end if;
  if exists (
    select 1 from jsonb_array_elements(coalesce(p_lines, '[]')) e
    where (e ->> 'price') is null
       or (e ->> 'price') !~ '^[0-9]{1,10}(\.[0-9]{1,2})?$'
  ) then
    perform private.bad_input('invalid:price');
  end if;

  update public.quote_items qi
  set quoted_unit_price_thb = (e ->> 'price')::numeric
  from jsonb_array_elements(coalesce(p_lines, '[]')) e
  where qi.quote_id = p_quote_id and qi.id = (e ->> 'id')::bigint;

  select count(*) into v_items from public.quote_items where quote_id = p_quote_id;
  if v_items > 0 then
    select sku into v_unpriced from public.quote_items
    where quote_id = p_quote_id and quoted_unit_price_thb is null
    limit 1;
    if found then
      perform private.bad_input('missing:price:' || v_unpriced);
    end if;
    select sum(qty * quoted_unit_price_thb) into v_total from public.quote_items where quote_id = p_quote_id;
  else
    if p_total_thb is null or p_total_thb < 0 then
      perform private.bad_input('missing:total');
    end if;
    v_total := round(p_total_thb, 2);
  end if;

  update public.quote_requests
  set quoted_total_thb = v_total,
      vat_rate = p_vat_rate,
      status = 'quoted',
      quoted_at = now(),
      assigned_to = coalesce(assigned_to, auth.uid())
  where id = p_quote_id
  returning * into v_quote;

  return jsonb_build_object(
    'quoted_total_thb', v_quote.quoted_total_thb,
    'quoted_vat_thb', v_quote.quoted_vat_thb,
    'quoted_grand_total_thb', v_quote.quoted_grand_total_thb);
end;
$$;

/*
  set_quote_status(quote_id, status, lost_reason?)
    reviewing  from new (take it on), or from won/lost/cancelled (reopen)
    won        from quoted only (needs a quoted price, for the sales reports)
    lost       from new / reviewing / quoted, with an optional reason
    cancelled  from new / reviewing / quoted
  'quoted' is set by save_quotation, never directly.
*/
create function public.set_quote_status(
  p_quote_id uuid, p_status public.quote_status, p_lost_reason text default null)
returns public.quote_status
language plpgsql
set search_path = ''
as $$
declare
  v_from public.quote_status;
  v_ok boolean;
begin
  if not private.has_role('sales') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select status into v_from from public.quote_requests where id = p_quote_id for update;
  if not found then
    perform private.bad_input('unknown_quote');
  end if;

  v_ok := case p_status
    when 'reviewing' then v_from in ('new', 'won', 'lost', 'cancelled')
    when 'won' then v_from = 'quoted'
    when 'lost' then v_from in ('new', 'reviewing', 'quoted')
    when 'cancelled' then v_from in ('new', 'reviewing', 'quoted')
    else false
  end;
  if not v_ok then
    perform private.bad_input(format('invalid_transition:%s:%s', v_from, p_status));
  end if;

  update public.quote_requests
  set status = p_status,
      assigned_to = coalesce(assigned_to, auth.uid()),
      closed_at = case when p_status in ('won', 'lost', 'cancelled') then now() end,
      lost_reason = case when p_status = 'lost' then nullif(left(btrim(p_lost_reason), 500), '') end
  where id = p_quote_id;

  return p_status;
end;
$$;

-- Badge numbers for the staff header. Counts only what the caller may see (RLS),
-- so roles without access get zeros.
create function public.staff_inbox_counts()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'new_quotes', (select count(*) from public.quote_requests where status = 'new'),
    'open_quotes', (select count(*) from public.quote_requests where status in ('new', 'reviewing')),
    'new_service', (select count(*) from public.service_requests where status = 'new'));
$$;

-- These functions run as the caller, so the caller needs the error helper too
-- (it only raises an exception).
grant execute on function private.bad_input(text) to authenticated;

revoke execute on function
  public.save_quotation(uuid, jsonb, numeric, numeric),
  public.set_quote_status(uuid, public.quote_status, text),
  public.staff_inbox_counts()
from public, anon;

grant execute on function
  public.save_quotation(uuid, jsonb, numeric, numeric),
  public.set_quote_status(uuid, public.quote_status, text),
  public.staff_inbox_counts()
to authenticated;
