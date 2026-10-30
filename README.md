# HoK Hub

A website for **Honor of Kings** esports: transfers and contracts, LFT / LFS board, news, match schedule with an automatic referee, official and mixed team rankings, tournaments with brackets, honor board, team and player pages. The custom HoK Hub crest lives in `hok-crest.png` and is used as the site mark and favicon.

Anyone can view the site without logging in. Admins, tournament organizers, team managers and players log in to add and edit data.

---

## What is in this folder

```
hok-hub/
  README.md                  this file
  index.html                 the whole website (one file)
  sql/
    schema.sql               database setup, FRESH install (run this one)
    upgrades/                only for people who ran an older version
      schema_update.sql      team manager accounts
      schema_update2.sql     transfers, contract uploads, team rename
      schema_update3.sql     logos and player photos
      schema_update4.sql     LFT/LFS, news, referee, schedule, honor board, prize pool
```

First time? Use only `index.html` and `sql/schema.sql`. Ignore the `upgrades` folder.

---

## Site layout

The site has **3 main sections** at the top, each with sub-sections underneath:

| Section | Sub-sections |
|---|---|
| **News** | Esports News, Game News, Tour News, BD & South Asia |
| **Transfer** | Looking for Players (LFS), Looking for Teams (LFT), Contracts, Transfer News |
| **Tournament** | Tournaments (brackets), Referee & Schedule (incl. "Report a match result"), Honor Board, Official Ranking, Mixed Ranking |

**Login** and **Manage** are buttons at the top right. After login, Manage opens the tools for your role (add teams and players, create tournaments, post news, approve people).
Match results are reported in **Tournament > Referee & Schedule**.

---

## What the site does

**Public pages (no login)**
- **Contracts:** every player with team, role, contract end date, time left, status (Free agent / Expiring soon / Under contract) and a link to the contract paper. Search and filter.
- **Transfer News:** newest transfers first.
- **LFT / LFS:** players looking for a team, teams looking for players.
- **News:** Esports News, Game News, Tour News, BD & South Asia.
- **Schedule:** upcoming and live matches with times in the visitor's own timezone, and recent results.
- **Official Ranking:** official events only, region SA.
- **Mixed Ranking:** official + unofficial events, country filter (Bangladesh, India, Pakistan, Other).
- **Honor Board:** every completed tournament: champion, runner-up, third, prize pool, organizer, and a "most titles" list.
- **Tournaments:** status, organizer, prize pool, winner, bracket with match times, final standings.
- **Team pages and player pages:** click any team or player name.
- **Season selector** at the top. Each season has its own rankings.

**Points (top 8 placement)**

| Place | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| Official | 25 | 20 | 16 | 12 | 10 | 8 | 6 | 4 |
| Unofficial | 10 | 8 | 6 | 5 | 4 | 3 | 2 | 1 |

Only tournaments marked **completed** give points. These numbers are placeholders. Set your real table before entering results (see "Changing things").

---

## Who can do what

| Role | Gets it by | Can do |
|---|---|---|
| Visitor | nothing | View everything |
| Player | signing up as a player (instant) | Post on the LFT / LFS board |
| Pending | signing up as organizer or manager | Nothing yet (waits for admin approval) |
| Organizer | admin approves | Create tournaments (prize pool, match times), enter bracket, scores, winner and standings for **their own** tournaments. Add teams. Post news. |
| Team manager | admin approves + assigns team | Add, edit, delete players of **their own team**, upload contract papers and photos, record transfers out of their team, report match results (automatic referee) |
| Admin | you (via SQL, once) | Everything: approve people, edit or rename teams, edit any player, delete anything |

---

## Setup (about 20 minutes, free)

### 1. Create the database (Supabase)
1. Go to supabase.com, sign up, click **New project**. Save the database password.
2. Wait until the project finishes setting up.

### 2. Run the database setup
1. In Supabase open **SQL Editor > New query**.
2. Open `sql/schema.sql`, copy everything, paste, click **Run**. You should see "Success".
   This creates tables, security rules, the automatic referee and the two file storage buckets.

### 3. Connect the website
1. In Supabase go to **Project Settings > API**. Copy the **Project URL** and the **publishable key** from the project Connect/API settings.
2. Open `index.html` in a text editor (Notepad is fine). Near the top of the `<script>` find:
   ```js
   const SB_URL="PASTE_YOUR_SUPABASE_URL",SB_KEY="PASTE_YOUR_SUPABASE_PUBLISHABLE_KEY";
   ```
   Paste your two values between the quotes. Save.
3. Never put a secret or `service_role` key in this browser file. A publishable key is meant to be public; database grants and row-level security must protect every table and bucket. The legacy anon key also works, but Supabase says it is being deprecated by the end of 2026.

### 4. Email settings (Supabase)
- **Authentication > Providers > Email:** keep sign-ups **enabled** (people sign themselves up). Leave "Confirm email" on, or turn it off while testing.
- After you deploy, set **Authentication > URL Configuration > Site URL** to your website address.

### 5. Put the website online
1. Go to **app.netlify.com/drop** (or Cloudflare Pages) and drag `index.html` in. You get a live link.
2. Later: Site settings > Domain management to connect your own domain.

### 6. Make yourself admin
1. Open your live site, **Login > New here? Sign up**. Choose "I organize tournaments" and sign up. Confirm the email.
2. In Supabase **SQL Editor** run (use your email):
   ```sql
   update profiles set role='admin' where email='you@example.com';
   ```
3. Log out and in again. You now see the **Manage** button at the top right.

---

## Running a season

1. **Teams first.** Manage > Add team (name + country). Team names must match exactly everywhere.
2. **Players.** A manager/admin adds name, role, age, team, contract end, duration, payment and release-clause details. Existing roster entries need identity backfilled from Manage or the manager’s roster panel. A player/guardian authorization checkbox, ID type/number and document are required. Identity files and contract papers are stored in private buckets; only admins can read them. Collect identity documents only with valid consent, restrict access, and set a retention/deletion policy that meets local law.
3. **Invite people.** Organizers and managers sign up, you approve them in **Manage > People** (set role, and the team for managers).
4. **Create a tournament** (organizer): name, official/unofficial, country, season, start date, details, prize pool.
5. **Set the bracket** in the tournament card: pick the 8 teams for the quarterfinals, enter a start time for each match, Save. Semifinal and final teams appear as results come in.
6. **Matches are played.** Managers report results (see below). The bracket updates itself.
7. **Finish.** When the final is confirmed the tournament completes automatically and points are added. (Organizers can still enter scores and standings by hand.)
8. **Transfers.** Manage > Record a transfer. The player moves and the move shows in Transfer News.
9. **New season.** Pick the season at the top. Old seasons stay saved.

---

## Automatic referee

1. The organizer enters a **start time** for every bracket match.
2. The **Schedule** tab shows upcoming matches (time in each visitor's timezone).
3. After a match, the **manager of each of the two teams** goes to Tournament > Referee & Schedule > "Report a match result", picks the match, enters their score and the opponent's score, optionally a screenshot.
4. **Both reports agree:** result confirmed automatically, winner moves to the next round.
5. **Reports differ:** the match is flagged on the Schedule tab with both scores and screenshots. The organizer decides by entering the score in the tournament card. Evidence is private; admins and organizers get short-lived links to review it.
6. **Final confirmed:** top 8, champion and "completed" status are set automatically. Prize pool and champion appear on the Honor Board.

Rules: only managers of the two teams can report. Scores cannot be equal. A confirmed match cannot be re-reported (the organizer fixes it manually). Brackets are 8-team single elimination.

## Community posts, News and Tournament Ops
- Anyone may submit a news story, transfer update, LFT or LFS post from **News > Submit a post**. Admins review the queue in **Manage** before publication. Email is required for follow-up; the database applies a per-email submission limit. Approved LFT/LFS contact details are public. Do not submit identity details in community posts.
- **Esports News** is the global competitive lane; **Game News** covers game updates; **Other / Fun Activities** is for community activities; **Tour News** covers Bangladesh and South Asia. Admins/organizers may also publish directly. YouTube links embed in-feed; link sources and write your own summary.
- The referee desk supports tournament-specific temporary codes, team check-in, match delays, Blue/Red side assignments, referee decisions and a timestamped activity log. Admins create/rotate/revoke codes; codes expire at the chosen time and are invalidated when the event is completed. Managers continue to submit scores; disagreements remain pending for an organizer decision.
- Identity numbers and document images are held separately from the public player roster. Only admins can view the identity vault; team managers can submit for their roster. Contract payment/release terms are private to admins and the player’s own team manager. Contract papers and match evidence are in private storage, with short-lived signed review links for permitted staff. Avoid collecting more data than required, obtain player/guardian consent (especially for minors), and define deletion/retention procedures before launch.

---

## Changing things

**Points:** in `index.html` find
```js
const PTS={official:[25,20,16,12,10,8,6,4],unofficial:[10,8,6,5,4,3,2,1]}
```
Change the numbers BEFORE entering results, because it changes every ranking, past ones too.

**Seasons:** find `SEASONS=[2026,2027,2028,2029]` and the number `2027` in the `$("se").innerHTML=opts(...)` line.
**Roles:** find `ROLES=["Clash Lane","Jungle","Mid Lane","Farm Lane","Roaming"]`.
**News categories:** find `CAT=["Esports News","Game News","Other / Fun Activities News","Tour News"]` (global esports, game updates, community activities, and BD + South Asia tours).

After any change, deploy the **entire `HOK BD` folder** (or its ZIP contents) to your host. Do not upload only `index.html`: the hero needs `arena-highlight.mp4` and `arena-poster.jpg` beside it, and the header needs `hok-crest.png`.

---

## Upgrading from an older version

If you already ran an earlier SQL file, do NOT run `schema.sql` again (it deletes data). Run only the missing ones from `sql/upgrades/`, in order:
1. `schema_update.sql` (if you do not have team managers yet)
2. `schema_update2.sql` (if you do not have Transfer News yet)
3. `schema_update3.sql` (if you do not have logos and photos yet)
4. `schema_update4.sql` (if you do not have LFT/LFS, News, Schedule/referee and Honor Board yet)
5. `schema_update5.sql` (visitor moderation, private identity and contract records, referee codes, private evidence, player age and secure registration)

Then replace the site files by deploying the entire `HOK BD` folder. Keep `index.html`, `arena-highlight.mp4`, `arena-poster.jpg` and `hok-crest.png` together. Do not re-run `schema.sql` on an existing database.

---

### Existing match screenshots
New dispute evidence uses the private `private-evidence` bucket. Historical match screenshots uploaded into the old public `media` bucket are not moved automatically because `media` also contains public team logos and player photos. Review the old match-report proof URLs in Supabase and migrate/delete those specific screenshot objects from `media` before launch if you need to revoke every historic public URL.

### Existing contract files
`schema_update5.sql` switches the existing `contracts` bucket from public to private. Previously uploaded files remain in Storage but public URLs stop working. Admins can still open old Supabase public-object URLs through the private-paper button (the app resolves them to a short-lived signed URL). Re-upload any external contract links as files if private review is needed. Back up the Supabase project before applying this migration.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Site not connected yet" banner | The URL and key are not pasted into `index.html` |
| Can log in but no Manage button | Your role is still pending. Use the SQL in step 6 |
| Manager cannot add players | Admin must set role to manager AND set their team (Manage > People) |
| Manager's roster is empty | The team name on their account does not exactly match the team name |
| Referee says "Only the managers of the two teams can report" | The account needs role manager with the exact team name, and both teams must be in the bracket |
| Match not on the Schedule tab | Both teams must be set and the match needs a start time |
| Upload fails | File too big (papers 5 MB PDF/PNG/JPG, images 2 MB PNG/JPG/WebP) or the SQL setup was not run |
| Confirmation email link does not work | Set the Site URL in Supabase (step 4) |
| Rename a team | Manage > Edit teams > rename > Save. It updates players, brackets, standings, transfers |

---

## Limits to know about
- Contract papers and images are **public** (anyone with the link can open them).
- Brackets are 8-team single elimination only.
- Only admins can upload team logos.
- Contract papers are not deleted from storage when a player is deleted.
- Not tested against a live project during development. If anything errors, check the browser console and the Supabase logs.

## Ideas for later
Group stage and double-elimination brackets, shareable ranking images, Bangla and Hindi language options, email alerts for expiring contracts, richer season archive.
