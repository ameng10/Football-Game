import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import { q } from "./db.mjs";



dotenv.config();
const app = express();
app.use(cors());           // allow the Vite dev server
app.use(express.json());

app.get("/api/health", (_req, res) => res.json({ ok: true }));

// ---- Basic reads from compat views ----

// Teams with league name
app.get("/api/teams", async (_req, res) => {
  const sql = `
    SELECT t.team_id, t.name, t.city, t.mascot, l.name AS league_name, l.level
    FROM teams t
    LEFT JOIN leagues l ON l.league_id = t.league_id
    ORDER BY l.level, t.name;
  `;
  const { rows } = await q(sql);
  res.json(rows);
});

// Players (first 200)
app.get("/api/players", async (_req, res) => {
  const sql = `
    SELECT p.player_id, p.team_id, p.first_name, p.last_name, p.pos_code, p.rating
    FROM players p
    ORDER BY p.rating DESC
    LIMIT 200;
  `;
  const { rows } = await q(sql);
  res.json(rows);
});

// Games with team names
app.get("/api/games", async (_req, res) => {
  const sql = `
    SELECT
      g.game_id,
      g.season_id,
      g.week,
      g.game_date,
      g.played,
      g.home_score,
      g.away_score,
      g.home_team_id,
      g.away_team_id,
      th.name AS home_team_name,
      ta.name AS away_team_name
    FROM games g
    LEFT JOIN teams th ON th.team_id = g.home_team_id
    LEFT JOIN teams ta ON ta.team_id = g.away_team_id
    ORDER BY g.game_date DESC NULLS LAST, g.week NULLS LAST;
  `;
  const { rows } = await q(sql);
  res.json(rows);
});



// ---- Simulate a game ----
// IMPORTANT: our compat layer created UUID game_id
// Adjust the function name/args below to your actual simulation function.
// If you used my earlier examples, replace simulate_game($1::uuid) as needed.
app.post("/api/games/:id/simulate", async (req, res) => {
  const gameId = req.params.id;
  try {
    // Call your DB function to simulate (must exist in your DB):
    // If your function lives under sim schema and takes UUID:
    //   SELECT sim.simulate_game($1::uuid);
    // If you named it differently, update the query below.
    await q(`SELECT sim.simulate_game($1::uuid);`, [gameId]);

    const { rows } = await q(
      `SELECT * FROM games WHERE game_id = $1::uuid;`,
      [gameId]
    );
    res.json({ ok: true, game: rows[0] || null });
  } catch (err) {
    console.error(err);
    res.status(500).json({ ok: false, error: err.message });
  }
});

// Reset a season for debugging: wipes stats, resets games to scheduled
app.post("/api/debug/reset", async (req, res) => {
  const leagueName = (req.body?.leagueName || "National Football League");
  const year = Number(req.body?.year || 2025);
  try {
    await q(`SELECT sim.debug_reset_by_name($1::text, $2::int);`, [leagueName, year]);
    res.json({ ok: true, message: `Reset ${leagueName} ${year}` });
  } catch (e) {
    console.error(e);
    res.status(500).json({ ok: false, error: e.message });
  }
});

// ----- CAREER MODE -----

// ===== CAREER CORE =====
app.post("/api/career/create", async (req, res) => {
  const { saveName, first, last, pos, stars } = req.body || {};
  try {
    const { rows } = await q(
      `SELECT sim.career_create($1::text,$2::text,$3::text,$4::text,$5::int) AS id`,
      [saveName || "My HS Career", first || "Alex", last || "Player", pos || "QB", Number(stars ?? 3)]
    );
    res.json({ ok: true, saveId: rows[0].id });
  } catch (e) { res.status(500).json({ ok:false, error: e.message }); }
});

app.post("/api/career/:saveId/customize", async (req, res) => {
  const { saveId } = req.params;
  const { pos, stars } = req.body || {};
  try {
    await q(`SELECT sim.career_customize($1::uuid,$2::text,$3::int)`, [saveId, pos, Number(stars ?? 3)]);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ ok:false, error: e.message }); }
});

app.get("/api/career/:saveId/state", async (req, res) => {
  const { saveId } = req.params;
  try {
    const { rows } = await q(`
      SELECT cs.*, cp.star_rating, cp.position_goal, cp.grade_level, cp.training_points, cp.followers,
             pp.attributes AS attrs, p.first_name, p.last_name
      FROM sim.career_state cs
      JOIN sim.career_player cp ON cp.save_id = cs.save_id
      JOIN sim.player_profile pp ON pp.id = cp.player_profile_id
      JOIN sim.person p ON p.id = pp.person_id
      WHERE cs.save_id = $1::uuid
    `,[saveId]);
    res.json({ ok: true, state: rows[0] || null });
  } catch (e) { res.status(500).json({ ok:false, error: e.message }); }
});

// ===== HS SETUP & WEEK SIM =====
app.post("/api/career/:saveId/schedule-hs", async (req,res)=>{
  const { saveId } = req.params;
  try {
    await q(`SELECT sim.career_schedule_hs_season($1::uuid)`, [saveId]);
    res.json({ ok: true });
  } catch (e){ res.status(500).json({ ok:false, error:e.message }); }
});

app.post("/api/career/:saveId/sim-week", async (req,res)=>{
  const { saveId } = req.params;
  try {
    await q(`SELECT sim.career_simulate_hs_week($1::uuid)`, [saveId]);
    res.json({ ok: true });
  } catch (e){ res.status(500).json({ ok:false, error:e.message }); }
});

app.get("/api/hs/:saveId/standings", async (req,res)=>{
  const { saveId } = req.params;
  try {
    const { rows: st } = await q(`
      SELECT s.season_id FROM sim.career_state s WHERE s.save_id=$1::uuid
    `,[saveId]);
    if (!st.length) return res.json({ ok:true, standings: []});
    const sid = st[0].season_id;
    const { rows } = await q(`
      SELECT t.name, hs.wins, hs.losses, hs.points_for, hs.points_against
      FROM sim.hs_standing hs
      JOIN sim.team t ON t.id = hs.team_id
      WHERE hs.season_id = $1::uuid
      ORDER BY hs.wins DESC, (hs.points_for - hs.points_against) DESC
    `,[sid]);
    res.json({ ok:true, standings: rows });
  } catch (e){ res.status(500).json({ ok:false, error:e.message }); }
});

app.post("/api/hs/:saveId/build-bracket", async (req,res)=>{
  try {
    await q(`SELECT sim.career_build_hs_bracket($1::uuid)`, [req.params.saveId]);
    res.json({ ok:true });
  } catch (e){ res.status(500).json({ ok:false, error:e.message }); }
});

app.get("/api/hs/:saveId/bracket", async (req,res)=>{
  const { saveId }=req.params;
  try {
    const { rows: st } = await q(`SELECT season_id FROM sim.career_state WHERE save_id=$1::uuid`, [saveId]);
    if (!st.length) return res.json({ ok:true, bracket: []});
    const sid = st[0].season_id;
    const { rows } = await q(`
      SELECT round, seed_home, seed_away,
             (SELECT name FROM sim.team WHERE id=home_team_id) AS home_name,
             (SELECT name FROM sim.team WHERE id=away_team_id) AS away_name,
             winner_team_id
      FROM sim.hs_bracket WHERE season_id=$1::uuid
      ORDER BY round, seed_home
    `,[sid]);
    res.json({ ok:true, bracket: rows });
  } catch (e){ res.status(500).json({ ok:false, error:e.message }); }
});

// ===== RANKINGS =====
app.post("/api/hs/:saveId/compute-rankings", async (req,res)=>{
  try {
    await q(`SELECT sim.career_compute_rankings($1::uuid)`, [req.params.saveId]);
    res.json({ ok:true });
  } catch (e){ res.status(500).json({ ok:false, error:e.message }); }
});

app.get("/api/hs/:saveId/rankings", async (req,res)=>{
  const { saveId }=req.params;
  try {
    const { rows: st } = await q(`SELECT season_id FROM sim.career_state WHERE save_id=$1::uuid`, [saveId]);
    if (!st.length) return res.json({ ok:true, rankings: []});
    const sid = st[0].season_id;
    const { rows } = await q(`
      SELECT pr.rank_overall, pr.score,
             per.first_name, per.last_name,
             pp.position
      FROM sim.player_ranking pr
      JOIN sim.player_profile pp ON pp.id = pr.player_profile_id
      JOIN sim.person per ON per.id = pp.person_id
      WHERE pr.season_id = $1::uuid
      ORDER BY pr.rank_overall ASC NULLS LAST
      LIMIT 100
    `,[sid]);
    res.json({ ok:true, rankings: rows });
  } catch (e){ res.status(500).json({ ok:false, error:e.message }); }
});

// ===== TRAINING =====
app.post("/api/career/:saveId/minigame", async (req,res)=>{
  const { saveId }=req.params;
  const { mode, score=0, simulate=false } = req.body||{};
  try {
    const { rows } = await q(
      `SELECT sim.career_award_training($1::uuid,$2::text,$3::int,$4::boolean) AS pts`,
      [saveId, mode||'generic', Number(score||0), !!simulate]
    );
    res.json({ ok:true, points: rows[0].pts });
  } catch (e){ res.status(500).json({ ok:false, error:e.message }); }
});

app.post("/api/career/:saveId/train/apply", async (req,res)=>{
  const { saveId }=req.params;
  const { attribute, points } = req.body||{};
  try {
    const { rows } = await q(
      `SELECT sim.career_apply_training($1::uuid,$2::text,$3::int) AS result`,
      [saveId, attribute, Number(points||0)]
    );
    res.json({ ok:true, result: rows[0].result });
  } catch (e){ res.status(500).json({ ok:false, error:e.message }); }
});

// ===== ROSTERS & DEPTH CHART =====
app.get("/api/hs/:saveId/roster", async (req,res)=>{
  const { saveId }=req.params;
  try {
    const { rows: st } = await q(`SELECT season_id, team_id FROM sim.career_state WHERE save_id=$1::uuid`, [saveId]);
    if (!st.length) return res.json({ ok:true, roster: []});
    const { season_id: sid, team_id: tid } = st[0];
    const { rows } = await q(`
      SELECT pp.id as player_id, per.first_name, per.last_name, pp.position,
             (pp.attributes->>'rating')::INT AS rating
      FROM sim.player_profile pp
      JOIN sim.person per ON per.id = pp.person_id
      WHERE pp.current_team_id=$1::uuid
      ORDER BY rating DESC NULLS LAST
    `,[tid]);
    res.json({ ok:true, roster: rows });
  } catch (e){ res.status(500).json({ ok:false, error:e.message }); }
});

app.get("/api/hs/:saveId/depth", async (req,res)=>{
  const { saveId }=req.params;
  try {
    const { rows: st } = await q(`SELECT season_id, team_id FROM sim.career_state WHERE save_id=$1::uuid`, [saveId]);
    if (!st.length) return res.json({ ok:true, depth: []});
    const { season_id: sid, team_id: tid } = st[0];
    const { rows } = await q(`
      SELECT position, slot_order,
             per.first_name||' '||per.last_name AS name,
             d.player_profile_id
      FROM sim.depth_chart d
      LEFT JOIN sim.player_profile pp ON pp.id=d.player_profile_id
      LEFT JOIN sim.person per ON per.id=pp.person_id
      WHERE d.season_id=$1::uuid AND d.team_id=$2::uuid
      ORDER BY position, slot_order
    `,[sid, tid]);
    res.json({ ok:true, depth: rows });
  } catch (e){ res.status(500).json({ ok:false, error:e.message }); }
});

app.post("/api/hs/:saveId/depth", async (req,res)=>{
  const { saveId }=req.params;
  const { position, slot_order, playerId } = req.body||{};
  try {
    const { rows: st } = await q(`SELECT season_id, team_id FROM sim.career_state WHERE save_id=$1::uuid`, [saveId]);
    if (!st.length) return res.status(400).json({ ok:false, error:'no state' });
    const { season_id: sid, team_id: tid } = st[0];
    await q(`
      INSERT INTO sim.depth_chart (season_id, team_id, position, slot_order, player_profile_id)
      VALUES ($1::uuid,$2::uuid,$3::text,$4::int,$5::uuid)
      ON CONFLICT (season_id, team_id, position, slot_order)
      DO UPDATE SET player_profile_id=EXCLUDED.player_profile_id
    `,[sid, tid, position, Number(slot_order), playerId]);
    res.json({ ok:true });
  } catch (e){ res.status(500).json({ ok:false, error:e.message }); }
});

// Practice -> grade & reps (mock simple)
app.post("/api/hs/:saveId/practice", async (req,res)=>{
  const { saveId }=req.params;
  const { grade=80 } = req.body||{};
  try {
    const { rows: st } = await q(`SELECT season_id, team_id FROM sim.career_state WHERE save_id=$1::uuid`, [saveId]);
    if (!st.length) return res.status(400).json({ ok:false, error:'no state' });
    const { season_id: sid, team_id: tid } = st[0];
    const reps = Math.max(0, Math.round(grade/10 - 3)); // 80 -> 5 reps
    await q(`INSERT INTO sim.practice_session (save_id, season_id, team_id, grade, reps_earned)
             VALUES ($1::uuid,$2::uuid,$3::uuid,$4::numeric,$5::int)`,
      [saveId, sid, tid, Number(grade), reps]);
    res.json({ ok:true, reps });
  } catch (e){ res.status(500).json({ ok:false, error:e.message }); }
});

// Recruiting (reuse your earlier offer/commit endpoints if present)
app.post("/api/career/:saveId/offers", async (req,res)=>{
  try {
    const { rows } = await q(`SELECT sim.career_generate_offers($1::uuid) AS count`, [req.params.saveId]);
    res.json({ ok:true, offers: rows[0].count });
  } catch (e){ res.status(500).json({ ok:false, error:e.message }); }
});

app.get("/api/career/:saveId/offers", async (req,res)=>{
  const { saveId }=req.params;
  try {
    const { rows } = await q(`
      SELECT ro.college_team_id AS team_id, t.name AS team_name, ro.committed
      FROM sim.recruiting_offer ro
      JOIN sim.career_player cp ON cp.player_profile_id = ro.player_profile_id
      JOIN sim.team t ON t.id = ro.college_team_id
      WHERE cp.save_id = $1::uuid
    `,[saveId]);
    res.json({ ok:true, offers: rows });
  } catch (e){ res.status(500).json({ ok:false, error:e.message }); }
});

app.post("/api/career/:saveId/commit", async (req,res)=>{
  const { saveId }=req.params;
  const { teamId } = req.body||{};
  try {
    await q(`SELECT sim.career_commit_college($1::uuid,$2::uuid)`, [saveId, teamId]);
    res.json({ ok:true });
  } catch (e){ res.status(500).json({ ok:false, error:e.message }); }
});

// Get Instagram feed for the career player
app.get("/api/career/:saveId/instagram", async (req, res) => {
  const { saveId } = req.params;
  try {
    // Get the player_profile_id for this save
    const { rows:profileRows } = await q(
      `SELECT player_profile_id FROM sim.career_player WHERE save_id = $1::uuid`, [saveId]);
    if (!profileRows.length) return res.status(404).json({ ok: false, error: "Career not found" });

    // Get the player_id from player_profile (assuming player_profile.id = players.id)
    const playerProfileId = profileRows[0].player_profile_id;

    // Query the instagram_feed table for this player
    const { rows:posts } = await q(
      `SELECT post_url, caption, posted_at, likes, comments
       FROM instagram_feed
       WHERE player_id = $1
       ORDER BY posted_at DESC
       LIMIT 10`, [playerProfileId]);
    res.json({ ok: true, posts });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});




const port = Number(process.env.PORT || 3001);
app.listen(port, () => {
  console.log(`API listening on http://localhost:${port}`);
});
