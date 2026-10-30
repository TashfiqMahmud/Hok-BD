-- Already ran the previous schema? Run ONLY this file (keeps your data). Fresh install? Use schema.sql instead.
alter table profiles add column if not exists team text;
alter table profiles drop constraint if exists profiles_role_check;
alter table profiles add constraint profiles_role_check check (role in ('pending','organizer','manager','admin'));

create or replace function my_team() returns text language sql stable security definer set search_path=public as $$ select team from profiles where id=auth.uid() $$;
create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$ begin insert into profiles(id,email,name,team) values(new.id,new.email,coalesce(new.raw_user_meta_data->>'name',''),nullif(new.raw_user_meta_data->>'team','')); return new; end $$;

create policy "manager add" on players for insert to authenticated with check (my_role()='manager' and team=my_team());
create policy "manager edit" on players for update to authenticated using (my_role()='manager' and team=my_team()) with check (my_role()='manager' and team=my_team());
create policy "manager delete" on players for delete to authenticated using (my_role()='manager' and team=my_team());
