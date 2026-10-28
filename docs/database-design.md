# ออกแบบฐานข้อมูล — Fitness Equipment Asia (Supabase / PostgreSQL)

เอกสารนี้อธิบายโครงสร้างฐานข้อมูลที่อยู่ใน `supabase/migrations/` และวิธีที่ backend คุยกับ Supabase
ออกแบบจากสิ่งที่หน้าเว็บ (repo Frontend) ต้องใช้จริง: แคตตาล็อกสินค้า, ตะกร้าขอใบเสนอราคา, checkout,
ฟอร์มแจ้งซ่อม และหน้าสแกน QR ของพนักงานคลัง

## 1. ภาพรวมสถาปัตยกรรม

```mermaid
flowchart LR
  FE["Frontend<br/>Next.js"] -->|"HTTP / JSON"| BE["Backend API"]
  FE -.->|"อ่านแคตตาล็อกตรงได้<br/>(publishable key, ผ่าน RLS)"| SB
  BE -->|"secret key (service_role)<br/>เรียก submit_* / place_order"| SB[("Supabase<br/>Postgres + Storage + Auth")]
  BE -->|"JWT ของพนักงาน<br/>เรียก stock_* / แก้ใบเสนอราคา"| SB
  STAFF["พนักงาน<br/>(Supabase Auth)"] --> FE
```

หลักการ 3 ข้อ

1. **ปิดไว้ก่อน (deny by default)** — ทุกตารางเปิด Row Level Security (RLS) ใครจะเห็นอะไรต้องมี policy อนุญาตเท่านั้น
2. **ลูกค้าไม่ต้อง login** — ฟอร์มจากหน้าเว็บส่งไปที่ backend, backend ตรวจข้อมูล/กันสแปม แล้วเรียกฟังก์ชันในฐานข้อมูลด้วย secret key
   ฟังก์ชันพวกนี้ (`submit_quote_request`, `place_order`, …) เรียกจาก anon key ไม่ได้
3. **พนักงาน login ด้วย Supabase Auth** — backend ส่ง JWT ของพนักงานต่อให้ Supabase เพื่อให้ RLS ทำงานตามบทบาท
   และบันทึกได้ว่า "ใครเป็นคนทำ" (`auth.uid()`)

## 2. ER Diagram

```mermaid
erDiagram
  categories ||--o{ products : "มี"
  products ||--o{ product_media : "รูป/คู่มือ/วิดีโอ"
  products ||--o{ variants : "SKU"
  variants ||--o| variant_internal : "ต้นทุน (staff)"
  variants ||--o{ variant_price_history : "ประวัติราคา"
  variants ||--o{ stock_units : "เครื่องจริง"
  locations ||--o{ stock_units : "อยู่ที่"
  stock_units ||--o{ stock_movements : "ประวัติการเคลื่อนไหว"
  customers ||--o{ quote_requests : "ขอราคา"
  customers ||--o{ orders : "สั่งซื้อ"
  quote_requests ||--o{ quote_items : "รายการ"
  quote_requests |o--o{ orders : "แปลงเป็นออเดอร์"
  variants ||--o{ quote_items : "ถูกขอราคา"
  orders ||--o{ order_items : "รายการ"
  variants ||--o{ order_items : "ถูกขาย"
  orders ||--o{ payments : "การชำระเงิน"
  orders |o--o{ stock_units : "จอง/ส่งออก"
  stock_units |o--o{ service_requests : "แจ้งซ่อม"
  quote_requests ||--o{ attachments : "แปลนพื้นที่"
  service_requests ||--o{ attachments : "รูป/วิดีโอ"
  staff_profiles }o--|| auth_users : "บัญชีพนักงาน"
```

## 3. ตารางทั้งหมด (19 ตาราง)

### 3.1 แคตตาล็อก

| ตาราง | หน้าที่ | คอลัมน์สำคัญ |
| --- | --- | --- |
| `categories` | หมวดสินค้า | `id` เป็น slug เช่น `plate-loaded`, `name_th/en/zh`, `sort` |
| `products` | รุ่นสินค้า (1 หน้า product) | `slug`, `model`, `name_th/en/zh`, `setting` (home/commercial), `arrived_at` + `new_override` (ป้าย NEW), `curated_rank`, `specs` (jsonb), `status` draft/published/archived, `is_demo` |
| `product_media` | รูป, คู่มือ PDF, วิดีโอ | `kind`, `storage_path` หรือ `external_url`, `width/height/alt`, `sort` |
| `variants` | SKU ที่ขายได้ (สี/สเปก) — **ราคาและสถานะสต็อกอยู่ที่นี่** | `sku`, `price_thb` (**null = สอบถามราคา ไม่ใช่ 0**), `stock_status` ready/preorder/import/out, `lead_time` |
| `variant_internal` | ข้อมูลภายใน แยกตารางเพื่อไม่ให้หลุดไปหน้าเว็บ | `cost_thb`, `supplier`, `hs_code`, ขนาด/น้ำหนักกล่อง |
| `variant_price_history` | บันทึกทุกครั้งที่ราคาขายหรือต้นทุนเปลี่ยน (trigger อัตโนมัติ) | `field`, `old_value`, `new_value`, `changed_by` |
| `exchange_rates` | อัตราแลกเปลี่ยน (แทนค่า 36 ที่ hardcode ใน frontend) | `currency`, `thb_per_unit`, `effective_at` |

### 3.2 คลังสินค้า (หน้า `/staff` สแกน QR)

| ตาราง | หน้าที่ | คอลัมน์สำคัญ |
| --- | --- | --- |
| `locations` | ตำแหน่งในคลัง/โชว์รูม | `id` เช่น `WH-A-02-14`, `kind` receiving/warehouse/showroom/service/transit |
| `stock_units` | เครื่องจริงแต่ละเครื่อง = 1 QR | `unit_code` (`U-000184`), `sku`, `serial`, `location_id`, `state`, `order_id` |
| `stock_movements` | ประวัติทุกการเคลื่อนไหว **แก้/ลบไม่ได้** (trigger บล็อก) | `action`, `from_state → to_state`, `from/to_location_id`, `actor`, `note` |

### 3.3 การขายและบริการ

| ตาราง | หน้าที่ | คอลัมน์สำคัญ |
| --- | --- | --- |
| `customers` | ลูกค้า 1 คนต่อ 1 ช่องทางติดต่อ (LINE ID เดียวกันไม่ซ้ำ ไม่สนตัวพิมพ์) | `contact_method`, `contact_value`, `company`, `country` |
| `quote_requests` | คำขอใบเสนอราคา (หน้า `/quote`) | `reference` `Q-2026-00001`, ข้อมูลติดต่อ, การติดตั้ง, การขนเข้า 4 ช่อง, `budget_text`, `status`, `quoted_total_thb`, `quoted_at`, `lost_reason` |
| `quote_items` | สินค้าในคำขอ | `sku`, `qty`, `note`, `list_price_thb` (ราคาหน้าเว็บตอนขอ), `quoted_unit_price_thb` (ราคาที่เสนอจริง) |
| `orders` | คำสั่งซื้อจาก checkout | `reference` `SO-2026-00001`, ที่อยู่, `fulfilment` delivery/pickup, `payment_option`, `status`, `subtotal/shipping/installation/discount/vat_thb`, `total_thb` (คำนวณอัตโนมัติ), `fx_thb_per_unit` |
| `order_items` | รายการในออเดอร์ | `unit_price_thb` และ `unit_cost_thb` **เก็บ snapshot** ณ วันที่สั่ง |
| `payments` | การชำระเงินแต่ละครั้ง (มัดจำ/ส่วนที่เหลือ) | `method`, `amount_thb`, `status`, `provider_ref`, `slip_path` |
| `service_requests` | แจ้งซ่อม (หน้า `/showroom`) | `reference` `SR-2026-00001`, `product_model`, `unit_code_input` (ที่ลูกค้าพิมพ์) + `unit_code` (ถ้าตรงกับเครื่องจริง), `symptom`, `status` |
| `attachments` | ไฟล์แนบของใบเสนอราคา/แจ้งซ่อม | `bucket`, `storage_path`, `mime_type`, `size_bytes` |

### 3.4 พนักงาน

| ตาราง | หน้าที่ |
| --- | --- |
| `staff_profiles` | ผูก `auth.users` กับบทบาท `admin` / `sales` / `warehouse` / `service` — สมัคร Auth อย่างเดียวยังไม่ได้สิทธิ์อะไร ต้องมีแถวในตารางนี้ |

## 4. สิทธิ์การเข้าถึง (RLS)

admin ผ่านทุกเงื่อนไข / ✓ = อ่าน / ✎ = แก้ไข / fn = ทำได้ผ่านฟังก์ชันเท่านั้น

| ข้อมูล | ผู้เข้าชม (anon) | sales | warehouse | service |
| --- | --- | --- | --- | --- |
| สินค้าที่ published, หมวด, อัตราแลกเปลี่ยน | ✓ | ✓✎ | ✓ | ✓ |
| สินค้า draft | – | ✓✎ | ✓ | ✓ |
| ต้นทุน `variant_internal`, ประวัติราคา | – | ✓ (แก้ต้นทุนได้เฉพาะ admin) | – | – |
| คลัง `stock_units`, `stock_movements` | – | ✓ | ✓ fn | ✓ fn (service/restock) |
| ลูกค้า | – | ✓✎ | – | ✓ |
| ใบเสนอราคา | – (ส่งผ่าน backend) | ✓✎ | – | – |
| ออเดอร์ | – (ส่งผ่าน backend) | ✓✎ | ✓ | – |
| การชำระเงิน | – | ✓✎ | – | – |
| แจ้งซ่อม | – (ส่งผ่าน backend) | ✓✎ | – | ✓✎ |
| รายงาน `sales_monthly`, `quote_funnel_monthly` | – | ✓ | – | – |

## 5. Backend คุยกับฐานข้อมูลอย่างไร

### 5.1 Views (อ่าน)

| View | ใช้ทำอะไร |
| --- | --- |
| `products_public` | แคตตาล็อกหน้าเว็บ: สินค้า published + variants + รูปหลัก + `is_new` (มาถึงภายใน 45 วัน หรือ staff บังคับ) — anon อ่านได้ |
| `current_exchange_rates` | อัตราล่าสุดต่อสกุลเงิน |
| `variant_stock_summary` | จำนวนเครื่องแยกตามสถานะต่อ SKU + `needs_review` (หน้าเว็บบอก "พร้อมส่ง" แต่ไม่มีของ) |
| `sales_monthly` | ยอดขาย, ต้นทุน, กำไรขั้นต้น, Gross margin รายเดือน |
| `quote_funnel_monthly` | จำนวนคำขอ, เสนอแล้ว, Win rate, เวลาเฉลี่ยจนเสนอราคา (ชม.), มูลค่าที่ปิดได้ |

ทุก view ตั้ง `security_invoker = true` แปลว่า RLS ของคนที่เรียกยังทำงาน (Supabase แนะนำแบบนี้)

### 5.2 ฟังก์ชัน (เขียน)

| ฟังก์ชัน | ใครเรียกได้ | ทำอะไร |
| --- | --- | --- |
| `submit_quote_request(payload)` | backend (secret key) | ตรวจข้อมูล, สร้าง/อัปเดตลูกค้า, ออกเลข `Q-…`, รวมรายการ SKU ซ้ำ, เก็บราคาหน้าเว็บ ณ ตอนนั้น |
| `place_order(payload)` | backend | รับเฉพาะ SKU ที่มีราคาและ `ready` (ตรงกับ `canBuy()` ใน frontend), **คิดราคาจากฐานข้อมูล ไม่เชื่อราคาที่ client ส่งมา**, snapshot ต้นทุนและอัตราแลกเปลี่ยน |
| `submit_service_request(payload)` | backend | ออกเลข `SR-…`, จับคู่หมายเลขเครื่องถ้ามีในระบบ |
| `register_attachment(ref, bucket, path, mime, size)` | backend | ผูกไฟล์ที่อัปโหลดแล้วกับใบเสนอราคา/แจ้งซ่อม |
| `stock_register_unit(...)` | พนักงาน warehouse | ลงทะเบียนเครื่องใหม่เป็น `inbound` |
| `stock_apply_action(unit, action, ...)` | พนักงาน warehouse (service: เฉพาะ service/restock) | เปลี่ยนสถานะเครื่องตามกฎด้านล่าง + เขียนประวัติ |

ข้อผิดพลาดจากการตรวจข้อมูลจะเป็น SQLSTATE `22023` พร้อมข้อความสั้น ๆ เช่น `missing:contact_name`,
`unknown_sku:FEA-X`, `item_not_purchasable:FEA-PL03-STD`, `invalid_transition:dispatched:move`
backend แปลงเป็น HTTP 400 ได้ทันที; `forbidden` (`42501`) แปลงเป็น 403

### 5.3 กฎการเปลี่ยนสถานะเครื่อง (state machine)

```mermaid
stateDiagram-v2
  [*] --> inbound: register
  inbound --> available: receive
  available --> showroom: move (ไปโซนโชว์รูม)
  showroom --> available: move (ออกจากโชว์รูม)
  available --> reserved: reserve
  showroom --> reserved: reserve
  reserved --> available: release
  available --> dispatched: dispatch
  reserved --> dispatched: dispatch
  inbound --> service: service
  available --> service: service
  reserved --> service: service
  showroom --> service: service
  dispatched --> service: service (รับคืน)
  service --> available: restock
```

### 5.4 ตัวอย่างโค้ดฝั่ง backend (Node.js + supabase-js)

```ts
import { createClient } from "@supabase/supabase-js";

// ใช้เฉพาะฝั่ง server เท่านั้น ห้ามส่ง secret key ไป browser
const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SECRET_KEY!, {
  auth: { persistSession: false },
});

// POST /api/quotes
const { data, error } = await admin.rpc("submit_quote_request", { payload: body });
if (error?.code === "22023") return res.status(400).json({ error: error.message });
// data = { id, reference: "Q-2026-00001" }

// พนักงานสแกน QR แล้วกด "รับเข้า" — ใช้ JWT ของพนักงาน เพื่อให้ RLS และ actor ถูกต้อง
const asStaff = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_PUBLISHABLE_KEY!, {
  global: { headers: { Authorization: `Bearer ${staffAccessToken}` } },
  auth: { persistSession: false },
});
await asStaff.rpc("stock_apply_action", { p_unit_code: "U-000201", p_action: "receive" });

// แคตตาล็อก (หน้า /products)
const { data: products } = await admin.from("products_public").select("*").order("curated_rank");
```

## 6. เหตุผลของการออกแบบ (ใช้ประกอบรายงานได้)

1. **ราคาเป็น `null` ได้ แต่ห้ามเป็น 0** (`check (price_thb > 0)`) — ตรงกับกติกาใน frontend ที่ว่าสินค้าที่ไม่มีราคาต้องแสดง "สอบถามราคา"
2. **แยกต้นทุนออกเป็นตาราง `variant_internal`** แทนการซ่อนคอลัมน์ — ทำให้ anon อ่าน `variants` ได้ทั้งแถวโดยไม่มีทางเห็นต้นทุน
3. **Snapshot ราคา/ต้นทุน/อัตราแลกเปลี่ยนในออเดอร์** — ราคาสินค้าเปลี่ยนภายหลังก็ไม่กระทบยอดในออเดอร์เก่า และคำนวณกำไรขั้นต้นย้อนหลังได้ถูกต้อง
4. **ประวัติราคา (`variant_price_history`)** — เก็บอัตโนมัติด้วย trigger ใช้วิเคราะห์ความยืดหยุ่นของราคา (price elasticity) หรือ margin trend ได้
5. **`stock_movements` แบบ append-only** — เป็นหลักฐานตรวจสอบ (audit trail) เหมือนสมุดบัญชีที่แก้ไม่ได้ ถ้าผิดให้บันทึกรายการแก้ใหม่
6. **เปลี่ยนสต็อกผ่านฟังก์ชันเท่านั้น** — การสแกน QR แค่เปิดข้อมูล การเปลี่ยนสถานะต้องผ่านกฎ state machine และบันทึกผู้ทำทุกครั้ง
7. **เลขอ้างอิงอ่านง่าย** `Q-2026-00001`, `SO-…`, `SR-…` — นับแยกต่อปี (เวลาไทย) ปลอดภัยเมื่อมีหลายคำขอพร้อมกัน
8. **ลูกค้าไม่ซ้ำตามช่องทางติดต่อ** — ลูกค้าที่ขอราคาหลายครั้งจะรวมเป็นคนเดียว ใช้คำนวณ conversion rate / customer lifetime value ได้
9. **ข้อมูล spec เป็น `jsonb`** — สินค้าแต่ละประเภทมีสเปกไม่เหมือนกัน และใช้แค่แสดงผล ไม่ได้ใช้ค้นหา จึงไม่ต้องแยกตาราง

## 7. สิ่งที่ยังต้องตัดสินใจ / ทำต่อ

- **ภาษีมูลค่าเพิ่ม (VAT)** — หน้า checkout ยังเป็น `[รอยืนยัน]` ตอนนี้เป็นคอลัมน์ `vat_thb` ให้พนักงานกรอก ถ้าจะคิดอัตโนมัติ 7% ต้องยืนยันว่าราคาบนเว็บรวม VAT แล้วหรือยัง
- **ผู้ให้บริการรับชำระเงิน** — ตาราง `payments` รองรับ `provider` / `provider_ref` แล้ว รอเลือกเจ้า (เช่น Omise, 2C2P, Stripe)
- **การตัดสต็อกตอนสั่งซื้อ** — ตอนนี้ `place_order` ไม่จองเครื่องอัตโนมัติ (ตรงกับ frontend ที่บอกว่ายังไม่จองสต็อก) พนักงานจองด้วยการสแกน
- **warehouse เห็นต้นทุนใน `order_items`** — ยอมรับไว้เพื่อให้หยิบของได้ ถ้าไม่ต้องการ ให้ทำ view pick-list แยก
- ชื่อหมวด `plate-loaded` ใน sample data ของ frontend สลับ `nameTh`/`nameEn` กัน ใน seed เก็บตามภาษาที่ถูกต้องแล้ว
