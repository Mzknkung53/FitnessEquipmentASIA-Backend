-- Storage buckets.
--   product-media        public: product photos, manuals (paths stored in product_media)
--   quote-attachments    private: floor plans / room photos sent with a quote
--   service-attachments  private: photos / videos sent with a repair request
--   payment-slips        private: bank-transfer slips
-- Customers never upload straight to Storage: the backend checks the file, uploads
-- it with the service key (or hands out a signed upload URL), then calls
-- register_attachment(). Staff read private files through signed URLs.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('product-media', 'product-media', true, 10485760,
   array['image/webp', 'image/jpeg', 'image/png', 'application/pdf']),
  ('quote-attachments', 'quote-attachments', false, 20971520,
   array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf']),
  ('service-attachments', 'service-attachments', false, 52428800,
   array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'video/mp4', 'video/quicktime']),
  ('payment-slips', 'payment-slips', false, 10485760,
   array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do nothing;

create policy "sales manage product media files" on storage.objects
  for all to authenticated
  using (bucket_id = 'product-media' and (select private.has_role('sales')))
  with check (bucket_id = 'product-media' and (select private.has_role('sales')));

create policy "staff read customer files" on storage.objects
  for select to authenticated
  using (
    (bucket_id in ('quote-attachments', 'payment-slips') and (select private.has_role('sales')))
    or (bucket_id = 'service-attachments' and (select private.has_role('sales', 'service')))
  );

create policy "sales upload payment slips" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'payment-slips' and (select private.has_role('sales')));
