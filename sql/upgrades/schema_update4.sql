-- Run AFTER schema_update3.sql (existing install). Fresh install: schema.sql already contains this.
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
