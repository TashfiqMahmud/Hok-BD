-- Run AFTER schema_update2.sql (existing install). Fresh install: schema.sql already contains this.
alter table teams add column if not exists logo_url text;
alter table players add column if not exists photo_url text;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('media','media',true,2097152,array['image/png','image/jpeg','image/webp']) on conflict (id) do nothing;
create policy "media read" on storage.objects for select using (bucket_id='media');
create policy "media upload" on storage.objects for insert to authenticated with check (bucket_id='media' and my_role() in ('manager','admin'));
create policy "media delete" on storage.objects for delete to authenticated using (bucket_id='media' and my_role() in ('manager','admin'));
