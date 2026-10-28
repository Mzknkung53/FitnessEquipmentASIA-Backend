-- DEMO seed for local development (`supabase db reset` runs this file).
-- Generated from the frontend's src/lib/data/sample-products.ts and sample-stock.ts.
-- Names, prices and specs are placeholders: do NOT run this against production.

insert into public.categories (id, name_th, name_en, sort) values
  ('plate-loaded', 'เครื่องใส่แผ่นน้ำหนัก', 'Plate-Loaded', 10),
  ('cardio', 'คาร์ดิโอ', 'Cardio', 20),
  ('selectorized', 'เครื่องเวทแบบสถานี', 'Selectorized machines', 30),
  ('racks', 'แร็คและฟังก์ชันนอล', 'Racks & functional', 40),
  ('free-weights', 'ฟรีเวทและม้านั่ง', 'Free weights & benches', 50),
  ('accessories', 'อุปกรณ์เสริม', 'Accessories', 60),
  ('flooring', 'พื้นยางและชั้นวาง', 'Flooring & storage', 70);

insert into public.products (slug, model, name_th, name_en, category_id, summary, setting, arrived_at, curated_rank, pictogram, unit_note, specs, usage_steps, status, is_demo) values
  ('fea-pl01-chest-press', 'FEA-PL01', 'เครื่องเพรสอกแบบใส่แผ่นน้ำหนัก', 'Plate-Loaded Chest Press', 'plate-loaded', 'เครื่องเพรสอกแบบใส่แผ่นน้ำหนักสำหรับยิมเชิงพาณิชย์ [คำอธิบายจริงจากทีมสินค้า]', array['commercial'], current_date - 10, 1, null, null, '[{"label":"ขนาดเครื่อง (ย×ก×ส)","value":"[000×000×000] ซม."},{"label":"น้ำหนักเครื่อง","value":"[000] กก."},{"label":"รับน้ำหนักแผ่นสูงสุด","value":"[000] กก."},{"label":"พื้นที่ที่ควรเว้น","value":"[000×000] ซม."}]'::jsonb, array['ปรับระดับเบาะให้ด้ามจับอยู่ระดับกลางอก', 'ใส่แผ่นน้ำหนักให้เท่ากันทั้งสองข้าง', '[ขั้นตอนจริงจากคู่มือของรุ่นนี้]'], 'published', true),
  ('fea-pl02-leg-machine', 'FEA-PL02', 'เครื่องฝึกขาแบบใส่แผ่นน้ำหนัก', 'Plate-Loaded Leg Machine', 'plate-loaded', 'เครื่องฝึกขาแบบใส่แผ่นน้ำหนัก [คำอธิบายจริงจากทีมสินค้า]', array['commercial'], current_date - 10, 2, null, null, '[{"label":"ขนาดเครื่อง (ย×ก×ส)","value":"[000×000×000] ซม."},{"label":"น้ำหนักเครื่อง","value":"[000] กก."},{"label":"รับน้ำหนักแผ่นสูงสุด","value":"[000] กก."},{"label":"พื้นที่ที่ควรเว้น","value":"[000×000] ซม."}]'::jsonb, array['ปรับพนักพิงและแผ่นวางเท้าให้พอดีกับช่วงขา', 'ใส่แผ่นน้ำหนักและล็อกตัวเครื่องก่อนเริ่ม', '[ขั้นตอนจริงจากคู่มือของรุ่นนี้]'], 'published', true),
  ('fea-pl03-shoulder-press', 'FEA-PL03', 'เครื่องเพรสไหล่แบบใส่แผ่นน้ำหนัก', 'Plate-Loaded Shoulder Press', 'plate-loaded', 'เครื่องเพรสไหล่แบบใส่แผ่นน้ำหนัก [คำอธิบายจริงจากทีมสินค้า]', array['commercial'], current_date - 10, 3, null, null, '[{"label":"ขนาดเครื่อง (ย×ก×ส)","value":"[000×000×000] ซม."},{"label":"น้ำหนักเครื่อง","value":"[000] กก."},{"label":"รับน้ำหนักแผ่นสูงสุด","value":"[000] กก."},{"label":"พื้นที่ที่ควรเว้น","value":"[000×000] ซม."}]'::jsonb, array['ตั้งระดับเบาะให้ด้ามจับอยู่ระดับไหล่', '[ขั้นตอนจริงจากคู่มือของรุ่นนี้]'], 'published', true),
  ('fea-t900-treadmill', 'FEA-T900', 'ลู่วิ่งไฟฟ้าเชิงพาณิชย์', 'Commercial Treadmill', 'cardio', 'ลู่วิ่งสำหรับบ้านหรือยิมขนาดเล็ก [คำอธิบายจริงจากทีมสินค้า]', array['home', 'commercial'], current_date - 200, 4, 'treadmill', null, '[{"label":"ไฟฟ้าที่ต้องใช้","value":"[220V]"}]'::jsonb, array['ติดคลิปนิรภัยกับเสื้อผ้าก่อนเริ่ม', 'เริ่มที่ความเร็วต่ำ แล้วค่อยเพิ่ม'], 'published', true),
  ('fea-b300-spin-bike', 'FEA-B300', 'จักรยานนั่งปั่น', 'Spin Bike', 'cardio', '[คำอธิบายจริงจากทีมสินค้า]', array['home', 'commercial'], current_date - 200, 7, 'bike', null, '[]'::jsonb, '{}'::text[], 'published', true),
  ('fea-pr700-power-rack', 'FEA-PR700', 'พาวเวอร์แร็ค', 'Power Rack', 'racks', '[คำอธิบายจริงจากทีมสินค้า]', array['home', 'commercial'], current_date - 200, 5, 'rack', null, '[]'::jsonb, '{}'::text[], 'published', true),
  ('fea-ab120-adjustable-bench', 'FEA-AB120', 'ม้านั่งปรับระดับ', 'Adjustable Bench', 'free-weights', '[คำอธิบายจริงจากทีมสินค้า]', array['home', 'commercial'], current_date - 200, 6, 'bench', null, '[]'::jsonb, '{}'::text[], 'published', true),
  ('fea-kb16-kettlebell', 'FEA-KB16', 'เคตเทิลเบล', 'Kettlebell', 'accessories', '[คำอธิบายจริงจากทีมสินค้า]', array['home', 'commercial'], current_date - 200, 9, 'kettlebell', null, '[]'::jsonb, '{}'::text[], 'published', true),
  ('fea-dr10-dumbbell-rack', 'FEA-DR10', 'ชั้นวางดัมเบล', 'Dumbbell Rack', 'flooring', '[คำอธิบายจริงจากทีมสินค้า]', array['home', 'commercial'], current_date - 200, 8, null, null, '[]'::jsonb, '{}'::text[], 'published', true),
  ('fea-fl50-gym-flooring', 'FEA-FL50', 'แผ่นยางปูพื้นยิม', 'Gym Rubber Flooring', 'flooring', '[คำอธิบายจริงจากทีมสินค้า]', array['home', 'commercial'], current_date - 200, 10, 'flooring', 'ราคาต่อแผ่น', '[]'::jsonb, '{}'::text[], 'published', true);

insert into public.product_media (product_id, kind, storage_path, width, height, alt)
select p.id, 'image', m.path, m.w, m.h, m.alt
from (values
  ('fea-pl01-chest-press', 'products/fea-pl01-chest-press.webp', 1179, 1446, 'เครื่องเพรสอกแบบใส่แผ่นน้ำหนัก มุมหน้า'),
  ('fea-pl02-leg-machine', 'products/fea-pl02-leg-machine.webp', 1179, 1452, 'เครื่องฝึกขาแบบใส่แผ่นน้ำหนัก'),
  ('fea-pl03-shoulder-press', 'products/fea-pl03-shoulder-press.webp', 1179, 1267, 'เครื่องเพรสไหล่แบบใส่แผ่นน้ำหนัก มุมหน้า')
) as m (slug, path, w, h, alt)
join public.products p on p.slug = m.slug;

insert into public.variants (sku, product_id, label, swatch, stock_status, price_thb, sort)
select v.sku, p.id, v.label, v.swatch, v.status::public.stock_status, v.price, v.sort
from (values
  ('fea-pl01-chest-press', 'FEA-PL01-SLV', 'เงินแฮมเมอร์โทน', '#8f8d89', 'ready', 89000::numeric, 0),
  ('fea-pl01-chest-press', 'FEA-PL01-BLK', 'ดำด้าน', '#1b1a18', 'preorder', 89000::numeric, 1),
  ('fea-pl01-chest-press', 'FEA-PL01-CUS', 'สีตามสั่ง (สำหรับยิม)', '#c8101a', 'import', null::numeric, 2),
  ('fea-pl02-leg-machine', 'FEA-PL02-BLK', 'ดำด้าน', '#1b1a18', 'preorder', 95000::numeric, 0),
  ('fea-pl02-leg-machine', 'FEA-PL02-CUS', 'สีตามสั่ง (สำหรับยิม)', '#c8101a', 'import', null::numeric, 1),
  ('fea-pl03-shoulder-press', 'FEA-PL03-STD', 'รุ่นมาตรฐาน', '#8f8d89', 'import', null::numeric, 0),
  ('fea-t900-treadmill', 'FEA-T900-BLK', 'ดำ', '#1b1a18', 'ready', 49900::numeric, 0),
  ('fea-b300-spin-bike', 'FEA-B300-BLK', 'ดำ', '#1b1a18', 'preorder', 18900::numeric, 0),
  ('fea-b300-spin-bike', 'FEA-B300-PRO', 'รุ่นยิม', '#4a4642', 'preorder', 24900::numeric, 1),
  ('fea-pr700-power-rack', 'FEA-PR700-BLK', 'ดำ', '#1b1a18', 'ready', 32500::numeric, 0),
  ('fea-ab120-adjustable-bench', 'FEA-AB120-BLK', 'ดำ', '#1b1a18', 'ready', 7900::numeric, 0),
  ('fea-kb16-kettlebell', 'FEA-KB16-16', '16 กก.', '#1b1a18', 'out', 1290::numeric, 0),
  ('fea-dr10-dumbbell-rack', 'FEA-DR10-BLK', 'ดำ', '#1b1a18', 'ready', 6900::numeric, 0),
  ('fea-fl50-gym-flooring', 'FEA-FL50-15', 'หนา 15 มม.', '#2a2724', 'ready', 890::numeric, 0),
  ('fea-fl50-gym-flooring', 'FEA-FL50-20', 'หนา 20 มม.', '#1b1a18', 'ready', 1090::numeric, 1)
) as v (slug, sku, label, swatch, status, price, sort)
join public.products p on p.slug = v.slug;

-- Placeholder costs so the margin views have something to show.
insert into public.variant_internal (sku, cost_thb, supplier)
select sku, round(price_thb * 0.62, 2), '[ผู้ผลิตตัวอย่าง]'
from public.variants
where price_thb is not null;

insert into public.exchange_rates (currency, thb_per_unit, source)
values ('USD', 36, 'manual (demo rate)');

insert into public.locations (id, name, kind) values
  ('RECEIVING', 'พื้นที่รับของ', 'receiving'),
  ('WH-A-02-14', 'คลัง A · แถว 2 · ช่อง 14', 'warehouse'),
  ('SHOWROOM-PL', 'โชว์รูม · โซน Plate-Loaded', 'showroom'),
  ('SERVICE', 'ศูนย์บริการ', 'service');

-- Inserted directly, so they have no movement history; real units go through
-- stock_register_unit() / stock_apply_action().
insert into public.stock_units (unit_code, sku, serial, location_id, condition, state, received_at) values
  ('U-000184', 'FEA-PL01-SLV', '[SN-ตัวอย่าง-184]', 'WH-A-02-14', 'ใหม่ ยังไม่แกะกล่อง', 'available', '2026-10-12'),
  ('U-000185', 'FEA-PL01-SLV', '[SN-ตัวอย่าง-185]', 'SHOWROOM-PL', 'เครื่องโชว์', 'showroom', '2026-10-12'),
  ('U-000201', 'FEA-PL02-BLK', '[SN-ตัวอย่าง-201]', 'RECEIVING', 'ใหม่', 'inbound', null);
