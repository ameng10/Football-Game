export default function careerRoutes(app, q) {
  // Create HS career
  app.post("/api/career/hs/create", async (req, res) => {
    const { saveName, first, last, pos, stars } = req.body || {};
    try {
      const { rows } = await q(
        `SELECT sim.career_create_hs($1::text,$2::text,$3::text,$4::text,$5::int) AS save_id`,
        [saveName || "My HS Career", first || "Alex", last || "Player", pos || "QB", Number(stars ?? 3)]
      );
      res.json({ ok: true, saveId: rows[0].save_id });
    } catch (e) {
      res.status(500).json({ ok:false, error: e.message });
    }
  });

  // Read career summary + attributes
  app.get("/api/career/:saveId", async (req, res) => {
    const { saveId } = req.params;
    try {
      const { rows } = await q(`
        SELECT cp.save_id, cp.stage, cp.class_year, cp.star_rating, cp.training_points, cp.followers,
               pp.id AS player_profile_id, pp.position,
               pr.first_name, pr.last_name,
               pp.attributes
        FROM sim.career_player cp
        JOIN sim.player_profile pp ON pp.id = cp.player_profile_id
        JOIN sim.person pr ON pr.id = pp.person_id
        WHERE cp.save_id = $1::uuid`, [saveId]);
      res.json({ ok:true, career: rows[0] || null });
    } catch (e) { res.status(500).json({ ok:false, error:e.message }); }
  });

  // Apply training allocations
  app.post("/api/career/:saveId/training/apply", async (req, res) => {
    const { saveId } = req.params;
    const { allocations } = req.body || {}; // [{attribute,delta},...]
    try {
      const { rows:sid } = await q(
        `INSERT INTO sim.training_session (save_id, points_earned, source)
         VALUES ($1::uuid, 0, 'allocate') RETURNING id`, [saveId]);
      await q(`SELECT sim.training_apply($1::uuid,$2::uuid,$3::jsonb)`,
        [saveId, sid[0].id, JSON.stringify(allocations || [])]);
      res.json({ ok:true });
    } catch (e) { res.status(500).json({ ok:false, error:e.message }); }
  });

  // Minigame: record score -> points
  app.post("/api/career/:saveId/minigame", async (req, res) => {
    const { saveId } = req.params;
    const { mode, score, simulate } = req.body || {};
    try {
      const { rows } = await q(
        `SELECT sim.minigame_result($1::uuid,$2::text,$3::int,$4::bool) AS points`,
        [saveId, mode || 'clicker', Number(score||0), !!simulate]);
      res.json({ ok:true, points: rows[0].points });
    } catch (e) { res.status(500).json({ ok:false, error:e.message }); }
  });

  // Followers feed (optional)
  app.get("/api/career/:saveId/followers", async (req, res) => {
    const { saveId } = req.params;
    const { rows } = await q(
      `SELECT followers FROM sim.career_player WHERE save_id=$1::uuid`, [saveId]);
    const { rows:feed } = await q(
      `SELECT delta, reason, created_at FROM sim.career_social_feed WHERE save_id=$1::uuid ORDER BY created_at DESC LIMIT 20`, [saveId]);
    res.json({ ok:true, followers: rows[0]?.followers ?? 0, feed });
  });
}
