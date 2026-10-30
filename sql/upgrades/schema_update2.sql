-- Run AFTER schema.sql + schema_update.sql (existing install). Fresh install: schema.sql already contains this.
create table if not exists transfers(id uuid primary key default gen_random_uuid(), player text not null, from_team text, to_team text, kind text not null default 'Transfer', date date not null default current_date, note text, created_at timestamptz default now());
alter table transfers enable row level security;
create policy "public read" on transfers for select using (true);
create policy "admin all" on transfers for all to authenticated using (my_role()='admin') with check (my_role()='admin');
create policy "manager adds outgoing" on transfers for insert to authenticated with check (my_role()='manager' and from_team=my_team());

-- managers may move their own players to another team (a transfer) or release them
drop policy if exists "manager edit" on players;
create policy "manager edit" on players for update to authenticated using (my_role()='manager' and team=my_team()) with check (my_role()='manager');

-- admin-only team rename that also fixes players, tournaments, brackets, transfers and accounts
create or replace function rename_team(old_name text,new_name text) returns void language plpgsql security definer set search_path=public as $$
begin
 if my_role()<>'admin' then raise exception 'admin only'; end if;
 update teams set name=new_name where name=old_name;
 update players set team=new_name where team=old_name;
 update profiles set team=new_name where team=old_name;
 update transfers set from_team=new_name where from_team=old_name;
 update transfers set to_team=new_name where to_team=old_name;
 update tournaments set top8=array_replace(top8,old_name,new_name), winner=case when winner=old_name then new_name else winner end,
  bracket=replace(bracket::text,to_jsonb(old_name)::text,to_jsonb(new_name)::text)::jsonb
  where top8 @> array[old_name] or winner=old_name or bracket::text like '%'||to_jsonb(old_name)::text||'%';
end $$;

-- contract paper storage (public read, only managers/admins upload; 5 MB, PDF/PNG/JPG)
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('contracts','contracts',true,5242880,array['application/pdf','image/png','image/jpeg']) on conflict (id) do nothing;
create policy "contracts read" on storage.objects for select using (bucket_id='contracts');
create policy "contracts upload" on storage.objects for insert to authenticated with check (bucket_id='contracts' and my_role() in ('manager','admin'));
create policy "contracts delete" on storage.objects for delete to authenticated using (bucket_id='contracts' and my_role() in ('manager','admin'));
