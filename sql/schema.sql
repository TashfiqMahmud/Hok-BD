-- Run in Supabase: SQL Editor > New query > paste > Run
-- (This replaces the old schema. It is safe to re-run while the tables are still empty.)
drop table if exists tournaments, players, teams, profiles cascade;

create table profiles(id uuid primary key references auth.users on delete cascade, email text, name text, role text not null default 'pending' check (role in ('pending','organizer','manager','admin')), team text, created_at timestamptz default now());
create table teams(id uuid primary key default gen_random_uuid(), name text unique not null, country text not null default 'OT');
create table players(id uuid primary key default gen_random_uuid(), name text not null, role text, team text, contract_end date, contract_url text);
create table tournaments(id uuid primary key default gen_random_uuid(), name text not null, tier text not null check (tier in ('official','unofficial')), category text not null default 'SA', season int not null, status text not null default 'upcoming' check (status in ('upcoming','live','completed')), start_date date, description text, organizer text, owner uuid references auth.users, winner text, bracket jsonb, top8 text[] not null default '{}', created_at timestamptz default now());

create function my_role() returns text language sql stable security definer set search_path=public as $$ select role from profiles where id=auth.uid() $$;
create function my_team() returns text language sql stable security definer set search_path=public as $$ select team from profiles where id=auth.uid() $$;
create function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$ begin insert into profiles(id,email,name,team) values(new.id,new.email,coalesce(new.raw_user_meta_data->>'name',''),nullif(new.raw_user_meta_data->>'team','')); return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

alter table profiles enable row level security; alter table teams enable row level security; alter table players enable row level security; alter table tournaments enable row level security;

create policy "own or admin read" on profiles for select using (id=auth.uid() or my_role()='admin');
create policy "admin updates roles" on profiles for update to authenticated using (my_role()='admin') with check (my_role()='admin');

create policy "public read" on teams for select using (true);
create policy "organizer add" on teams for insert to authenticated with check (my_role() in ('organizer','admin'));
create policy "admin edit" on teams for update to authenticated using (my_role()='admin');
create policy "admin delete" on teams for delete to authenticated using (my_role()='admin');

create policy "public read" on players for select using (true);
create policy "admin write" on players for all to authenticated using (my_role()='admin') with check (my_role()='admin');
create policy "manager add" on players for insert to authenticated with check (my_role()='manager' and team=my_team());
create policy "manager edit" on players for update to authenticated using (my_role()='manager' and team=my_team()) with check (my_role()='manager' and team=my_team());
create policy "manager delete" on players for delete to authenticated using (my_role()='manager' and team=my_team());

create policy "public read" on tournaments for select using (true);
create policy "organizer create" on tournaments for insert to authenticated with check (my_role() in ('organizer','admin') and owner=auth.uid());
create policy "owner or admin edit" on tournaments for update to authenticated using (my_role()='admin' or (my_role()='organizer' and owner=auth.uid())) with check (my_role()='admin' or (my_role()='organizer' and owner=auth.uid()));
create policy "owner or admin delete" on tournaments for delete to authenticated using (my_role()='admin' or (my_role()='organizer' and owner=auth.uid()));

-- FIRST ADMIN: sign up on the website once, then run this with your email:
-- update profiles set role='admin' where email='you@example.com';

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

alter table teams add column if not exists logo_url text;
alter table players add column if not exists photo_url text;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('media','media',true,2097152,array['image/png','image/jpeg','image/webp']) on conflict (id) do nothing;
create policy "media read" on storage.objects for select using (bucket_id='media');
create policy "media upload" on storage.objects for insert to authenticated with check (bucket_id='media' and my_role() in ('manager','admin'));
create policy "media delete" on storage.objects for delete to authenticated using (bucket_id='media' and my_role() in ('manager','admin'));

-- Adds: LFT/LFS board, news, player accounts, prize pool, match schedule reports and the automatic referee.

-- player accounts (self sign-up, can post LFT/LFS)
alter table profiles drop constraint if exists profiles_role_check;
alter table profiles add constraint profiles_role_check check (role in ('pending','player','organizer','manager','admin'));
create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$ begin insert into profiles(id,email,name,team,role) values(new.id,new.email,coalesce(new.raw_user_meta_data->>'name',''),nullif(new.raw_user_meta_data->>'team',''),case when new.raw_user_meta_data->>'want'='player' then 'player' else 'pending' end); return new; end $$;

alter table tournaments add column if not exists prize_pool text;

-- LFT (player looking for team) / LFS (team looking for players): any logged-in user, max 3 posts per day
create table if not exists lf_posts(id uuid primary key default gen_random_uuid(), kind text not null check (kind in ('LFT','LFS')), name text not null, role text, country text default 'OT', contact text not null, message text, owner uuid references auth.users default auth.uid(), created_at timestamptz default now());
alter table lf_posts enable row level security;
create policy "public read" on lf_posts for select using (true);
create policy "logged in post" on lf_posts for insert to authenticated with check (owner=auth.uid() and (select count(*) from lf_posts p where p.owner=auth.uid() and p.created_at>now()-interval '1 day')<3);
create policy "owner or admin delete" on lf_posts for delete to authenticated using (owner=auth.uid() or my_role()='admin');

-- news: posted by admins and organizers
create table if not exists news(id uuid primary key default gen_random_uuid(), title text not null, category text not null default 'Tournament', body text, url text, author text, owner uuid references auth.users default auth.uid(), created_at timestamptz default now());
alter table news enable row level security;
create policy "public read" on news for select using (true);
create policy "staff post" on news for insert to authenticated with check (my_role() in ('organizer','admin') and owner=auth.uid());
create policy "owner or admin delete" on news for delete to authenticated using (owner=auth.uid() or my_role()='admin');

-- match reports sent by the two teams (written only by the submit_report function)
create table if not exists match_reports(id uuid primary key default gen_random_uuid(), tournament_id uuid references tournaments on delete cascade, match_key text not null, team text not null, my_score int not null, opp_score int not null, proof text, reporter uuid default auth.uid(), created_at timestamptz default now(), unique(tournament_id,match_key,team));
alter table match_reports enable row level security;
create policy "public read" on match_reports for select using (true);
create policy "admin delete" on match_reports for delete to authenticated using (my_role()='admin');

-- referee helpers: winner of a match from its scores
create or replace function _w(x jsonb, a text, c text) returns text language sql immutable as $$
 select case when x->>'x' is null or x->>'y' is null or (x->>'x')::numeric=(x->>'y')::numeric then null when (x->>'x')::numeric>(x->>'y')::numeric then a else c end $$;

-- works out who plays in every match and the final top 8 once the whole bracket is decided
create or replace function calc_bracket(b jsonb) returns jsonb language plpgsql immutable as $$
declare qa text[]; qb text[]; qw text[]; ql text[]; sa text[]; sbb text[]; sw text[]; sl text[]; fa text; fb text; fw text; fl text; i int; top jsonb;
begin
 for i in 1..4 loop
  qa[i]:=nullif(b->'q'->(i-1)->>'a',''); qb[i]:=nullif(b->'q'->(i-1)->>'b','');
  qw[i]:=_w(b->'q'->(i-1),qa[i],qb[i]); ql[i]:=_w(b->'q'->(i-1),qb[i],qa[i]);
 end loop;
 sa[1]:=qw[1]; sbb[1]:=qw[2]; sa[2]:=qw[3]; sbb[2]:=qw[4];
 for i in 1..2 loop
  sw[i]:=_w(b->'s'->(i-1),sa[i],sbb[i]); sl[i]:=_w(b->'s'->(i-1),sbb[i],sa[i]);
 end loop;
 fa:=sw[1]; fb:=sw[2]; fw:=_w(b->'f',fa,fb); fl:=_w(b->'f',fb,fa);
 if fw is not null and sl[1] is not null and sl[2] is not null and ql[1] is not null and ql[2] is not null and ql[3] is not null and ql[4] is not null then
  top:=to_jsonb(array[fw,fl,sl[1],sl[2],ql[1],ql[2],ql[3],ql[4]]);
 end if;
 return jsonb_build_object('teams',jsonb_build_object('q0',jsonb_build_array(qa[1],qb[1]),'q1',jsonb_build_array(qa[2],qb[2]),'q2',jsonb_build_array(qa[3],qb[3]),'q3',jsonb_build_array(qa[4],qb[4]),'s0',jsonb_build_array(sa[1],sbb[1]),'s1',jsonb_build_array(sa[2],sbb[2]),'f',jsonb_build_array(fa,fb)),'top8',top);
end $$;

-- THE AUTOMATIC REFEREE: a manager of one of the two teams reports the score.
-- Both teams report; if the two reports match, the result is confirmed, the bracket advances,
-- and when the final is decided the standings, winner and "completed" status are set automatically.
create or replace function submit_report(p_tid uuid, p_key text, p_mine int, p_opp int, p_proof text) returns text language plpgsql security definer set search_path=public as $$
declare t tournaments%rowtype; c jsonb; pair jsonb; a text; b text; me text; o match_reports%rowtype; path text[]; ox int; oy int; nb jsonb;
begin
 select * into t from tournaments where id=p_tid;
 if not found or t.bracket is null then raise exception 'Tournament or bracket not found'; end if;
 c:=calc_bracket(t.bracket); pair:=c->'teams'->p_key;
 if pair is null then raise exception 'Unknown match'; end if;
 a:=pair->>0; b:=pair->>1; me:=my_team();
 if my_role()<>'manager' or me is null or a is null or b is null or me not in (a,b) then raise exception 'Only the managers of the two teams can report, and both teams must be decided'; end if;
 if p_mine<0 or p_opp<0 or p_mine=p_opp then raise exception 'Scores must be different numbers'; end if;
 path:=case when p_key='f' then array['f'] else array[left(p_key,1),right(p_key,1)] end;
 if (t.bracket #>> array_append(path,'x')) is not null then raise exception 'This match already has a confirmed result. Ask the organizer to change it.'; end if;
 insert into match_reports(tournament_id,match_key,team,my_score,opp_score,proof,reporter) values(p_tid,p_key,me,p_mine,p_opp,p_proof,auth.uid())
  on conflict (tournament_id,match_key,team) do update set my_score=excluded.my_score,opp_score=excluded.opp_score,proof=excluded.proof,reporter=excluded.reporter,created_at=now();
 select * into o from match_reports where tournament_id=p_tid and match_key=p_key and team<>me;
 if not found then return 'Saved. Waiting for the other team to report the same score.'; end if;
 if o.my_score<>p_opp or o.opp_score<>p_mine then return 'Reports differ. The organizer will review and decide.'; end if;
 if me=a then ox:=p_mine; oy:=p_opp; else ox:=p_opp; oy:=p_mine; end if;
 nb:=jsonb_set(jsonb_set(t.bracket,array_append(path,'x'),to_jsonb(ox),true),array_append(path,'y'),to_jsonb(oy),true);
 c:=calc_bracket(nb);
 if c->'top8' <> 'null'::jsonb then
  update tournaments set bracket=nb,top8=array(select jsonb_array_elements_text(c->'top8')),winner=c->'top8'->>0,status='completed' where id=p_tid;
  return 'Confirmed. The tournament is complete and the champion is set.';
 end if;
 update tournaments set bracket=nb,status='live' where id=p_tid;
 return 'Confirmed by both teams. The bracket has been updated.';
end $$;


-- schema_update5.sql additions: keep fresh-install schema aligned with the incremental upgrade.
-- schema_update5.sql — moderation, tournament operations and private identity handling
-- Run this AFTER schema_update4.sql. Non-destructive; does not drop existing public records.

create extension if not exists pgcrypto with schema extensions;

-- New news lanes. Historical category values are preserved; the UI maps old values.
alter table public.transfers add column if not exists image_url text;
alter table public.news alter column category set default 'Esports News';

-- Anonymous community submissions are private until an administrator approves them.
create table if not exists public.public_submissions (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('news','transfer','LFT','LFS')),
  payload jsonb not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  submitter_name text,
  submitter_email text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewer uuid references auth.users
);
alter table public.public_submissions enable row level security;
grant select on public.public_submissions to authenticated;
drop policy if exists "admin review submissions" on public.public_submissions;
create policy "admin review submissions" on public.public_submissions for all to authenticated using (my_role()='admin') with check (my_role()='admin');

create or replace function public.submit_public_post(p_kind text,p_payload jsonb,p_name text default null,p_email text default null)
returns uuid language plpgsql security definer set search_path=public,extensions as $$
declare new_id uuid; n text; e text; title_ text; body_ text;
begin
 if p_kind not in ('news','transfer','LFT','LFS') then raise exception 'Unsupported post type'; end if;
 if jsonb_typeof(p_payload)<>'object' or length(p_payload::text)>12000 then raise exception 'Invalid post data'; end if;
 n:=left(trim(coalesce(p_name,'')),100); e:=lower(left(trim(coalesce(p_email,'')),254));
 if e !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then raise exception 'A valid email is required for moderation follow-up'; end if;
 if p_kind='news' then
   title_:=trim(coalesce(p_payload->>'title','')); body_:=trim(coalesce(p_payload->>'body',''));
   if length(title_)<4 or length(title_)>140 or length(body_)<10 or length(body_)>4000 then raise exception 'Please enter a 4–140 character title and a 10–4000 character summary'; end if;
   if coalesce(p_payload->>'category','') not in ('Game News','Esports News','Other / Fun Activities News','Tour News') then raise exception 'Choose a valid news category'; end if;
   if coalesce(p_payload->>'url','')<>'' and (p_payload->>'url') !~ '^https?://' then raise exception 'Link must begin with http:// or https://'; end if;
 elsif p_kind='transfer' then
   if length(trim(coalesce(p_payload->>'player','')))<2 or length(trim(coalesce(p_payload->>'to_team','')))<2 then raise exception 'Player and destination team are required'; end if;
   if coalesce(p_payload->>'image_url','')<>'' and (p_payload->>'image_url') !~ '^https?://' then raise exception 'Image URL must begin with http:// or https://'; end if;
 elsif p_kind in ('LFT','LFS') then
   if length(trim(coalesce(p_payload->>'name','')))<2 or length(trim(coalesce(p_payload->>'contact','')))<3 then raise exception 'Name and contact are required'; end if;
 end if;
 if (select count(*) from public.public_submissions where created_at>now()-interval '1 hour' and coalesce(submitter_email,'')=e)>=5 then raise exception 'Submission limit reached. Please try again later'; end if;
 insert into public.public_submissions(kind,payload,submitter_name,submitter_email) values(p_kind,p_payload,n,e) returning id into new_id;
 return new_id;
end $$;
revoke all on function public.submit_public_post(text,jsonb,text,text) from public;
grant execute on function public.submit_public_post(text,jsonb,text,text) to anon,authenticated;

create or replace function public.moderate_public_submission(p_id uuid,p_decision text)
returns text language plpgsql security definer set search_path=public as $$
declare s public_submissions%rowtype; p jsonb;
begin
 if my_role()<>'admin' then raise exception 'Administrator access required'; end if;
 if p_decision not in ('approve','reject') then raise exception 'Invalid decision'; end if;
 select * into s from public_submissions where id=p_id for update;
 if not found or s.status<>'pending' then raise exception 'Submission is no longer pending'; end if;
 p:=s.payload;
 if p_decision='approve' then
   if s.kind='news' then
     insert into news(title,category,body,url,author,owner) values(trim(p->>'title'),p->>'category',nullif(trim(p->>'body'),''),nullif(trim(p->>'url'),''),coalesce(nullif(s.submitter_name,''),'Community'),auth.uid());
   elsif s.kind='transfer' then
     insert into transfers(player,from_team,to_team,kind,date,note,image_url) values(trim(p->>'player'),nullif(trim(p->>'from_team'),''),nullif(trim(p->>'to_team'),''),coalesce(nullif(trim(p->>'move_type'),''),'Transfer'),coalesce(nullif(p->>'date','')::date,current_date),nullif(trim(p->>'note'),''),nullif(trim(p->>'image_url'),''));
   elsif s.kind in ('LFT','LFS') then
     insert into lf_posts(kind,name,role,country,contact,message,owner) values(s.kind,trim(p->>'name'),nullif(trim(p->>'role'),''),coalesce(nullif(p->>'country',''),'OT'),trim(p->>'contact'),nullif(trim(p->>'message'),''),null);
   end if;
 end if;
 update public_submissions set status=case when p_decision='approve' then 'approved' else 'rejected' end,reviewed_at=now(),reviewer=auth.uid() where id=p_id;
 return case when p_decision='approve' then 'Approved and published.' else 'Submission rejected.' end;
end $$;
revoke all on function public.moderate_public_submission(uuid,text) from public,anon;
grant execute on function public.moderate_public_submission(uuid,text) to authenticated;

-- Remove direct anonymous/public insert paths: all new posts must go through moderation.
drop policy if exists "public read" on public.lf_posts;
drop policy if exists "logged in post" on public.lf_posts;
drop policy if exists "approved board posts read" on lf_posts;
create policy "approved board posts read" on public.lf_posts for select using (true);
drop policy if exists "public read" on public.news;
drop policy if exists "published news read" on news;
create policy "published news read" on public.news for select using (true);
drop policy if exists "staff post" on public.news;
-- Organizers/admins retain their authorized direct publishing capability.
create policy "staff post" on public.news for insert to authenticated with check (my_role() in ('organizer','admin') and owner=auth.uid());

-- Private identity records: managers may submit identity data for players on their team;
-- only administrators may select/read, update, or remove those records.
create table if not exists public.player_identity (
  player_id uuid primary key references public.players(id) on delete cascade,
  identity_type text not null check (identity_type in ('National ID','Passport','Birth certificate')),
  identity_number text not null check (length(trim(identity_number)) between 4 and 80),
  document_path text not null,
  submitted_by uuid references auth.users,
  submitted_at timestamptz not null default now()
);
alter table public.player_identity enable row level security;
grant select,update,delete on public.player_identity to authenticated;
drop policy if exists "admin read identity" on public.player_identity;
drop policy if exists "team manager submit identity" on public.player_identity;
drop policy if exists "admin update identity" on public.player_identity;
create policy "admin read identity" on public.player_identity for select to authenticated using (my_role()='admin');
create policy "team manager submit identity" on public.player_identity for insert to authenticated with check (my_role()='admin' or (my_role()='manager' and exists(select 1 from public.players p where p.id=player_id and p.team=my_team())));
create policy "admin update identity" on public.player_identity for update to authenticated using (my_role()='admin') with check (my_role()='admin');
drop policy if exists "admin delete identity" on player_identity;
create policy "admin delete identity" on public.player_identity for delete to authenticated using (my_role()='admin');

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('private-identity','private-identity',false,10485760,array['application/pdf','image/png','image/jpeg']) on conflict(id) do update set public=false,file_size_limit=10485760,allowed_mime_types=array['application/pdf','image/png','image/jpeg'];
drop policy if exists "identity file upload" on storage.objects;
drop policy if exists "identity file admin read" on storage.objects;
drop policy if exists "identity file admin delete" on storage.objects;
create policy "identity file upload" on storage.objects for insert to authenticated with check (bucket_id='private-identity' and my_role() in ('admin','manager'));
create policy "identity file admin read" on storage.objects for select to authenticated using (bucket_id='private-identity' and my_role()='admin');
create policy "identity file admin delete" on storage.objects for delete to authenticated using (bucket_id='private-identity' and my_role()='admin');

-- Move match evidence to a non-public bucket. The website stores object paths, not public URLs.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('private-evidence','private-evidence',false,5242880,array['image/png','image/jpeg','image/webp','application/pdf']) on conflict(id) do update set public=false,file_size_limit=5242880;
-- Contract papers are private because they may contain signatures and financial terms.
update storage.buckets set public=false where id='contracts';
drop policy if exists "contracts read" on storage.objects;
drop policy if exists "contracts upload" on storage.objects;
drop policy if exists "contracts delete" on storage.objects;
drop policy if exists "contract papers admin read" on storage.objects;
create policy "contract papers admin read" on storage.objects for select to authenticated using (bucket_id='contracts' and my_role()='admin');
drop policy if exists "contract papers staff upload" on storage.objects;
create policy "contract papers staff upload" on storage.objects for insert to authenticated with check (bucket_id='contracts' and my_role() in ('admin','manager'));
drop policy if exists "contract papers admin delete" on storage.objects;
create policy "contract papers admin delete" on storage.objects for delete to authenticated using (bucket_id='contracts' and my_role()='admin');
drop policy if exists "evidence upload" on storage.objects;
drop policy if exists "evidence admin read" on storage.objects;
create policy "evidence upload" on storage.objects for insert to authenticated with check (bucket_id='private-evidence' and my_role() in ('admin','organizer','manager'));
create policy "evidence admin read" on storage.objects for select to authenticated using (bucket_id='private-evidence' and my_role() in ('admin','organizer'));
-- Stop the match report table from exposing reporter identity or private evidence paths to visitors.
drop policy if exists "public read" on public.match_reports;
drop policy if exists "staff read match reports" on match_reports;
create policy "staff read match reports" on public.match_reports for select to authenticated using (my_role() in ('admin','organizer') or (my_role()='manager' and team=my_team()));

-- Tournament-scoped temporary referee access. The raw code is only returned at creation;
-- database stores only its SHA-256 digest. Codes are single-active-per-event, revocable and expire.
alter table public.tournaments add column if not exists referee_expires_at timestamptz;
create table if not exists public.tournament_referee_codes(
 id uuid primary key default gen_random_uuid(), tournament_id uuid not null references public.tournaments(id) on delete cascade,
 code_hash text not null unique, created_by uuid not null references auth.users, created_at timestamptz not null default now(),
 expires_at timestamptz not null, revoked_at timestamptz
);
alter table public.tournament_referee_codes enable row level security;
revoke all on public.tournament_referee_codes from anon,authenticated;
drop policy if exists "admin manage referee codes" on tournament_referee_codes;
create policy "admin manage referee codes" on public.tournament_referee_codes for all to authenticated using (my_role()='admin') with check (my_role()='admin');
create unique index if not exists one_active_referee_code_per_tournament on public.tournament_referee_codes(tournament_id) where revoked_at is null;
create table if not exists public.tournament_referee_log(
 id uuid primary key default gen_random_uuid(), tournament_id uuid not null references public.tournaments(id) on delete cascade,
 action text not null check (action in ('check_in','delay','side_assignment','decision','note')),
 team text, details text not null, created_at timestamptz not null default now(), actor_label text not null default 'Tournament referee'
);
alter table public.tournament_referee_log enable row level security;
grant select on public.tournament_referee_log to anon,authenticated;
drop policy if exists "public read referee log" on tournament_referee_log;
create policy "public read referee log" on public.tournament_referee_log for select using (true);
drop policy if exists "admin read referee log" on tournament_referee_log;
create policy "admin read referee log" on public.tournament_referee_log for all to authenticated using (my_role()='admin') with check (my_role()='admin');

create or replace function public.create_tournament_referee_code(p_tid uuid,p_expires timestamptz default null)
returns text language plpgsql security definer set search_path=public,extensions as $$
declare t public.tournaments%rowtype; raw_code text; exp timestamptz;
begin
 if my_role()<>'admin' then raise exception 'Administrator access required'; end if;
 select * into t from public.tournaments where id=p_tid for update;
 if not found or t.status='completed' then raise exception 'Tournament not found or already completed'; end if;
 exp:=coalesce(p_expires,t.referee_expires_at,now()+interval '30 days');
 if exp<=now() then raise exception 'Expiry must be in the future'; end if;
 update public.tournament_referee_codes set revoked_at=now() where tournament_id=p_tid and revoked_at is null;
 raw_code:=upper(encode(extensions.gen_random_bytes(18),'hex'));
 insert into public.tournament_referee_codes(tournament_id,code_hash,created_by,expires_at) values(p_tid,encode(extensions.digest(raw_code,'sha256'),'hex'),auth.uid(),exp);
 update public.tournaments set referee_expires_at=exp where id=p_tid;
 return raw_code;
end $$;
revoke all on function public.create_tournament_referee_code(uuid,timestamptz) from public,anon;
grant execute on function public.create_tournament_referee_code(uuid,timestamptz) to authenticated;

create or replace function public.revoke_tournament_referee_code(p_tid uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
 if my_role()<>'admin' then raise exception 'Administrator access required'; end if;
 update public.tournament_referee_codes set revoked_at=now() where tournament_id=p_tid and revoked_at is null;
end $$;
revoke all on function public.revoke_tournament_referee_code(uuid) from public,anon;
grant execute on function public.revoke_tournament_referee_code(uuid) to authenticated;

create or replace function public.use_tournament_referee_code(p_tid uuid,p_code text,p_action text,p_team text,p_details text,p_actor text default null)
returns text language plpgsql security definer set search_path=public,extensions as $$
declare t public.tournaments%rowtype; c public.tournament_referee_codes%rowtype; d text;
begin
 select * into t from public.tournaments where id=p_tid;
 if not found or t.status='completed' then raise exception 'Tournament unavailable or completed'; end if;
 select * into c from public.tournament_referee_codes where tournament_id=p_tid and revoked_at is null and expires_at>now() and code_hash=encode(extensions.digest(upper(trim(coalesce(p_code,''))),'sha256'),'hex');
 if not found then raise exception 'Invalid, expired, or revoked tournament code'; end if;
 if p_action not in ('check_in','delay','side_assignment','decision','note') then raise exception 'Invalid referee action'; end if;
 d:=left(trim(coalesce(p_details,'')),1000);
 if length(d)<2 then raise exception 'Please add action details'; end if;
 if p_action='side_assignment' and (p_team is null or d !~* '^(blue|red)') then raise exception 'Choose a team and specify Blue or Red side'; end if;
 if p_action in ('delay','check_in','side_assignment') and p_team is null then raise exception 'Choose the affected team'; end if;
 if p_team is not null and not exists(select 1 from public.teams where name=p_team) then raise exception 'Select a valid tournament team'; end if;
 if p_action='side_assignment' and d !~* '^(blue|red)([[:space:]]|:|$)' then raise exception 'Start side assignment details with Blue or Red'; end if;
 if p_action in ('delay','decision','note') and length(d)<3 then raise exception 'Add a short note describing the action'; end if;
 insert into public.tournament_referee_log(tournament_id,action,team,details,actor_label) values(p_tid,p_action,nullif(trim(p_team),''),d,left(coalesce(nullif(trim(p_actor),''),'Tournament referee'),80));
 return 'Referee log updated.';
end $$;
revoke all on function public.use_tournament_referee_code(uuid,text,text,text,text,text) from public;
grant execute on function public.use_tournament_referee_code(uuid,text,text,text,text,text) to anon,authenticated;


-- Player card metadata requested in the sketches. Identity values remain in player_identity.
alter table public.players add column if not exists age smallint check (age between 1 and 100);
create table if not exists public.player_contract_terms (
 player_id uuid primary key references public.players(id) on delete cascade,
 contract_duration text, payment_terms text, release_clause text,
 updated_at timestamptz not null default now()
);
alter table public.player_contract_terms add column if not exists legacy_contract_link text;
-- Move previously-public paper URLs off the public player row. Supabase public-contract URLs
-- can still be converted to a short-lived signed link by the admin UI after this migration.
insert into public.player_contract_terms(player_id,legacy_contract_link)
select id,contract_url from public.players where contract_url like 'http%'
on conflict(player_id) do update set legacy_contract_link=excluded.legacy_contract_link;
update public.players set contract_url=null where contract_url like 'http%';
alter table public.player_contract_terms enable row level security;
drop policy if exists "team and admin read private contract terms" on public.player_contract_terms;
drop policy if exists "team and admin manage private contract terms" on public.player_contract_terms;
create policy "team and admin read private contract terms" on public.player_contract_terms for select to authenticated using (my_role()='admin' or (my_role()='manager' and exists(select 1 from public.players p where p.id=player_id and p.team=my_team())));
create policy "team and admin manage private contract terms" on public.player_contract_terms for all to authenticated using (my_role()='admin' or (my_role()='manager' and exists(select 1 from public.players p where p.id=player_id and p.team=my_team()))) with check (my_role()='admin' or (my_role()='manager' and exists(select 1 from public.players p where p.id=player_id and p.team=my_team())));
grant select,insert,update,delete on public.player_contract_terms to authenticated;

-- One atomic, role-checked player registration path ensures the private identity row is present.
create or replace function public.create_player_with_identity(
 p_name text,p_role text,p_team text,p_age smallint,p_contract_end date,
 p_contract_duration text,p_contract_payment text,p_release_clause text,p_contract_url text,
 p_identity_type text,p_identity_number text,p_document_path text
) returns uuid language plpgsql security definer set search_path=public as $$
declare new_player uuid;
begin
 if my_role() not in ('admin','manager') then raise exception 'Administrator or team manager access required'; end if;
 if my_role()='manager' and (p_team is null or p_team<>my_team()) then raise exception 'Managers may add players only to their assigned team'; end if;
 if p_age is null or p_age<1 or p_age>100 then raise exception 'Valid player age is required'; end if;
 if p_identity_type not in ('National ID','Passport','Birth certificate') or length(trim(coalesce(p_identity_number,'')))<4 or length(trim(coalesce(p_document_path,'')))<5 then raise exception 'Identity type, number and private document are required'; end if;
 if p_document_path !~ '^[A-Za-z0-9_.-]+$' then raise exception 'Invalid private document reference'; end if;
 if coalesce(p_contract_url,'') ~* '^https?://' then raise exception 'Upload contract papers to private storage instead of using a public link'; end if;
 insert into public.players(name,role,team,age,contract_end,contract_url)
 values(trim(p_name),p_role,nullif(trim(p_team),''),p_age,p_contract_end,nullif(trim(p_contract_url),'')) returning id into new_player;
 insert into public.player_contract_terms(player_id,contract_duration,payment_terms,release_clause) values(new_player,nullif(trim(p_contract_duration),''),nullif(trim(p_contract_payment),''),nullif(trim(p_release_clause),''));
 insert into public.player_identity(player_id,identity_type,identity_number,document_path,submitted_by)
 values(new_player,p_identity_type,trim(p_identity_number),p_document_path,auth.uid());
 return new_player;
end $$;
revoke all on function public.create_player_with_identity(text,text,text,smallint,date,text,text,text,text,text,text,text) from public,anon;
grant execute on function public.create_player_with_identity(text,text,text,smallint,date,text,text,text,text,text,text,text) to authenticated;
-- Disallow direct inserts that could bypass the mandatory identity workflow. The atomic RPC is the only insert path.
drop policy if exists "manager add" on public.players;
drop policy if exists "admin write" on public.players;
drop policy if exists "admin update players" on players;
create policy "admin update players" on public.players for update to authenticated using (my_role()='admin') with check (my_role()='admin');
drop policy if exists "admin delete players" on players;
create policy "admin delete players" on public.players for delete to authenticated using (my_role()='admin');

-- Limit the owner-maintained administrator roster to three accounts.
create or replace function public.enforce_admin_roster_limit() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.role='admin' then
   if tg_op='INSERT' then
     if (select count(*) from public.profiles where role='admin')>=3 then raise exception 'At most three administrator accounts are allowed'; end if;
   elsif old.role is distinct from 'admin' then
     if (select count(*) from public.profiles where role='admin')>=3 then raise exception 'At most three administrator accounts are allowed'; end if;
   end if;
 end if;
 return new;
end $$;
drop trigger if exists profiles_admin_limit on public.profiles;
create trigger profiles_admin_limit before insert or update of role on public.profiles for each row execute function public.enforce_admin_roster_limit();

create or replace function public.enforce_private_contract_reference() returns trigger language plpgsql as $$
begin
 if coalesce(new.contract_url,'') ~* '^https?://' then raise exception 'Contract papers must be uploaded to private storage'; end if;
 return new;
end $$;
drop trigger if exists players_private_contract_reference on public.players;
create trigger players_private_contract_reference before insert or update of contract_url on public.players for each row execute function public.enforce_private_contract_reference();
