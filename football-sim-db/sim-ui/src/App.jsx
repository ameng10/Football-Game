import { useEffect, useMemo, useState } from "react";
import { Outlet, Link, useLocation } from "react-router-dom";
const API = "http://localhost:3001/api";

// Two themes
const THEMES = {
  dark: {
    name: "dark",
    bg: "#0f172a",       // slate-900
    panel: "#111827",    // gray-900
    card: "#1f2937",     // gray-800
    text: "#e5e7eb",     // gray-200
    subtext: "#9ca3af",  // gray-400
    accent: "#22c55e",   // green-500
    accent2: "#60a5fa",  // blue-400
    warn: "#f59e0b",     // amber-500
    danger: "#ef4444",   // red-500
    chip: "#0ea5e9",     // sky-500
    tableHeader: "#111827",
    border: "#374151"
  },
  light: {
    name: "light",
    bg: "#f8fafc",       // slate-50
    panel: "#ffffff",
    card: "#ffffff",
    text: "#0f172a",
    subtext: "#475569",
    accent: "#16a34a",
    accent2: "#2563eb",
    warn: "#d97706",
    danger: "#dc2626",
    chip: "#0891b2",
    tableHeader: "#f1f5f9",
    border: "#e2e8f0"
  }
};

const btnStyle = {
  padding: "10px 14px",
  border: "0",
  borderRadius: 10,
  cursor: "pointer",
  fontWeight: 600,
  letterSpacing: 0.2
};

const toolbarBtn = (bg) => ({
  ...btnStyle,
  background: bg,
  color: "white",
  boxShadow: "0 4px 14px rgba(0,0,0,0.2)"
});

function Chip({ label, color }) {
  return (
    <span style={{
      background: color,
      color: "white",
      padding: "2px 8px",
      borderRadius: 999,
      fontSize: 12,
      fontWeight: 700,
      letterSpacing: 0.3
    }}>
      {label}
    </span>
  );
}

function CareerPanel({ theme }) {
  const [saveId, setSaveId] = useState(localStorage.getItem("careerSaveId") || "");
  const [state, setState] = useState(null);
  const [offers, setOffers] = useState([]);
  const [first, setFirst] = useState("Alex");
  const [last, setLast] = useState("Player");
  const [pos, setPos] = useState("QB");
  const [stars, setStars] = useState(3);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState("");

  async function refresh() {
    if (!saveId) return;
    const r = await fetch(`${API}/career/${saveId}/state`);
    const data = await r.json();
    if (data.ok) {
      setState(data.state);
      setOffers(data.offers || []);
    }
  }

  useEffect(() => { refresh(); }, [saveId]);

  async function createSave() {
    setBusy(true);
    setMsg("");
    try {
      const r = await fetch(`${API}/career/create`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ saveName: "My Career", first, last, pos, stars })
      });
      const data = await r.json();
      if (data.ok) {
        localStorage.setItem("careerSaveId", data.saveId);
        setSaveId(data.saveId);
        setMsg("Career created.");
        await refresh();
      } else {
        setMsg(data.error || "Failed");
      }
    } finally { setBusy(false); }
  }

  async function genOffers() {
    setBusy(true);
    setMsg("");
    try {
      const r = await fetch(`${API}/career/${saveId}/offers`, { method: "POST" });
      const data = await r.json();
      if (data.ok) setMsg(`Generated ${data.offers} offer(s).`);
      await refresh();
    } finally { setBusy(false); }
  }

  async function commit(teamId) {
    setBusy(true);
    setMsg("");
    try {
      await fetch(`${API}/career/${saveId}/commit`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ teamId })
      });
      setMsg("Committed.");
      await refresh();
    } finally { setBusy(false); }
  }

  async function advance() {
    setBusy(true);
    setMsg("");
    try {
      await fetch(`${API}/career/${saveId}/advance`, { method: "POST" });
      setMsg("Advanced a week.");
      await refresh();
    } finally { setBusy(false); }
  }

  const inputStyle = {
    background: theme.card,
    color: theme.text,
    border: `1px solid ${theme.border}`,
    borderRadius: 8,
    padding: "8px 10px"
  };

  return (
    <div style={{ display: "grid", gap: 12 }}>
      {!saveId && (
        <div style={{ display: "grid", gap: 8, gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))" }}>
          <input style={inputStyle} value={first} onChange={e=>setFirst(e.target.value)} placeholder="First name" />
          <input style={inputStyle} value={last} onChange={e=>setLast(e.target.value)} placeholder="Last name" />
          <select style={inputStyle} value={pos} onChange={e=>setPos(e.target.value)}>
            <option>QB</option><option>RB</option><option>WR</option><option>TE</option><option>DB</option><option>LB</option>
          </select>
          <input style={inputStyle} type="number" min={0} max={5} value={stars} onChange={e=>setStars(Number(e.target.value||0))} />
          <button style={toolbarBtn(theme.accent)} onClick={createSave} disabled={busy}>Create Career</button>
        </div>
      )}

      {saveId && (
        <>
          <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
            <span style={{ color: theme.subtext }}>Save:</span>
            <code style={{ background: theme.panel, padding: "4px 8px", borderRadius: 8, border: `1px solid ${theme.border}` }}>{saveId.slice(0,8)}…</code>
            <button style={toolbarBtn(theme.accent2)} onClick={refresh} disabled={busy}>Refresh</button>
            <button style={toolbarBtn(theme.accent)} onClick={genOffers} disabled={busy}>Gen College Offers</button>
            <button style={toolbarBtn(theme.warn)} onClick={advance} disabled={busy}>Advance Week</button>
            <button style={toolbarBtn(theme.danger)} onClick={() => { localStorage.removeItem("careerSaveId"); setSaveId(""); setState(null); setOffers([]); }}>Delete Save (local)</button>
          </div>

          {msg && <div style={{ color: theme.subtext }}>{msg}</div>}

          <div style={{
            display: "grid",
            gridTemplateColumns: "1fr 1fr",
            gap: 12
          }}>
            <div style={{ background: theme.panel, borderRadius: 12, padding: 12, border: `1px solid ${theme.border}` }}>
              <h3 style={{ marginTop: 0 }}>State</h3>
              {state ? (
                <div style={{ color: theme.subtext }}>
                  <div><strong>{state.first_name} {state.last_name}</strong> — {state.position} ({state.star_rating}★) · Stage: {state.stage}</div>
                  <div>Phase: {state.calendar?.phase} · Week: {state.calendar?.week}</div>
                </div>
              ) : <div>No state yet.</div>}
            </div>
            <div style={{ background: theme.panel, borderRadius: 12, padding: 12, border: `1px solid ${theme.border}` }}>
              <h3 style={{ marginTop: 0 }}>Offers</h3>
              {offers && offers.length ? (
                <div style={{ display: "grid", gap: 8 }}>
                  {offers.map(o => (
                    <div key={o.team_id} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", background: theme.card, padding: 10, borderRadius: 8 }}>
                      <span>{o.team_name}</span>
                      <button style={toolbarBtn(theme.accent)} onClick={() => commit(o.team_id)}>Commit</button>
                    </div>
                  ))}
                </div>
              ) : <div style={{ color: theme.subtext }}>No offers yet.</div>}
            </div>
          </div>
        </>
      )}
    </div>
  );
}


export default function App() {
  // THEME
  const [themeName, setThemeName] = useState(() => localStorage.getItem("theme") || "dark");
  const theme = useMemo(() => THEMES[themeName] || THEMES.dark, [themeName]);
  useEffect(() => { localStorage.setItem("theme", themeName); }, [themeName]);

  const [games, setGames] = useState([]);
  const [teams, setTeams] = useState([]);
  const [players, setPlayers] = useState([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [leagueName, setLeagueName] = useState("National Football League");
  const [seasonYear, setSeasonYear] = useState(2025);

  const cardStyle = {
    background: theme.card,
    color: theme.text,
    borderRadius: 14,
    padding: 16,
    boxShadow: "0 10px 24px rgba(0,0,0,0.10)",
    border: `1px solid ${theme.border}`
  };
  const tableStyle = { width: "100%", borderCollapse: "separate", borderSpacing: 0 };
  const thtd = { padding: "10px 12px", borderBottom: `1px solid ${theme.border}` };

  async function loadAll() {
    setError("");
    try {
      const [g, t, p] = await Promise.all([
        fetch(`${API}/games`).then(r => r.json()),
        fetch(`${API}/teams`).then(r => r.json()),
        fetch(`${API}/players`).then(r => r.json())
      ]);
      setGames(g);
      setTeams(t);
      setPlayers(p);
    } catch (e) {
      setError(e.message || "Failed to load");
    }
  }
  useEffect(() => { loadAll(); }, []);

  async function simulate(gameId) {
    setBusy(true);
    setError("");
    try {
      await fetch(`${API}/games/${gameId}/simulate`, { method: "POST" });
      await loadAll();
    } catch (e) {
      setError(e.message || "Simulation failed");
    } finally {
      setBusy(false);
    }
  }

  async function simulateAllVisible() {
    setBusy(true);
    setError("");
    try {
      const ids = games.filter(g => !g.played).map(g => g.game_id);
      for (const id of ids) {
        await fetch(`${API}/games/${id}/simulate`, { method: "POST" });
      }
      await loadAll();
    } catch (e) {
      setError(e.message || "Bulk simulation failed");
    } finally {
      setBusy(false);
    }
  }

  async function resetSeason() {
    if (!window.confirm(`Reset ${leagueName} ${seasonYear}? This clears game results and stats for that season.`)) return;
    setBusy(true);
    setError("");
    try {
      await fetch(`${API}/debug/reset`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ leagueName, year: seasonYear })
      });
      await loadAll();
    } catch (e) {
      setError(e.message || "Reset failed");
    } finally {
      setBusy(false);
    }
  }
  const location = useLocation();
  return (

    <div style={{ background: theme.bg, minHeight: "100vh", color: theme.text }}>
      {/* Header */}
      <header style={{
        position: "sticky",
        top: 0,
        zIndex: 10,
        background: theme.panel,
        padding: "16px 20px",
        display: "flex",
        alignItems: "center",
        gap: 12,
        borderBottom: `1px solid ${theme.border}`
      }}>
        <h1 style={{ margin: 0, fontSize: 22, fontWeight: 800 }}>
          🏈 Football Sim <span style={{ color: theme.subtext, fontWeight: 600 }}>(Dev)</span>
        </h1>

        <div style={{ flex: 1 }} />
        <div style={{ background: theme.bg, minHeight: "100vh", color: theme.text }}>
      {/* header with theme toggle (same as before) */}

      {/* Nav */}
      <nav style={{ maxWidth: 1200, margin: "0 auto", padding: "8px 18px", display: "flex", gap: 10, flexWrap: "wrap" }}>
        {[
          ["Home","/"],
          ["Attributes","/attributes"],
          ["Training","/training"],
          ["HS Standings","/hs/standings"],
          ["HS Bracket","/hs/bracket"],
          ["HS Rankings","/hs/rankings"],
          ["Roster & Depth","/hs/roster"],
          ["Recruiting","/recruiting"]
        ].map(([label, path]) => (
          <Link key={path} to={path} style={{
            textDecoration: "none",
            background: location.pathname===path ? theme.accent2 : theme.panel,
            color: location.pathname===path ? "white" : theme.text,
            padding: "8px 12px",
            borderRadius: 8,
            border: `1px solid ${theme.border}`
          }}>{label}</Link>
        ))}
      </nav>

      {/* Page content */}
      <main style={{ maxWidth: 1200, margin: "12px auto", padding: "0 18px" }}>
        <Outlet />
      </main>
    </div>

        {/* Theme toggle */}
        <button
          onClick={() => setThemeName(themeName === "dark" ? "light" : "dark")}
          style={toolbarBtn(theme.accent2)}
          title="Toggle light/dark"
        >
          {themeName === "dark" ? "Switch to Light" : "Switch to Dark"}
        </button>

        <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
          <input
            value={leagueName}
            onChange={e => setLeagueName(e.target.value)}
            style={{ background: theme.card, color: theme.text, border: `1px solid ${theme.border}`, borderRadius: 8, padding: "8px 10px", width: 260 }}
            title="League Name"
            placeholder="League Name"
          />
          <input
            value={seasonYear}
            onChange={e => setSeasonYear(Number(e.target.value || 0))}
            style={{ background: theme.card, color: theme.text, border: `1px solid ${theme.border}`, borderRadius: 8, padding: "8px 10px", width: 90, textAlign: "center" }}
            title="Season Year"
            placeholder="Year"
            type="number"
          />

          <button onClick={loadAll} style={toolbarBtn(theme.accent2)} disabled={busy}>Refresh</button>
          <button onClick={simulateAllVisible} style={toolbarBtn(theme.accent)} disabled={busy}>Simulate All Visible</button>
          <button onClick={resetSeason} style={toolbarBtn(theme.danger)} disabled={busy}>Reset Season</button>
        </div>
      </header>

      {/* Body */}
      <main style={{ maxWidth: 1200, margin: "18px auto", padding: "0 18px", display: "grid", gap: 18 }}>
        {error && (
          <div style={{ ...cardStyle, border: `1px solid ${theme.danger}` }}>
            <strong style={{ color: theme.danger }}>Error:</strong> {error}
          </div>
        )}

        {/* Games */}
        <section style={cardStyle}>
          <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 10 }}>
            <h2 style={{ margin: 0 }}>Games</h2>
            <span style={{ color: theme.subtext }}>{games.length} total</span>
          </div>

          <div style={{ overflowX: "auto" }}>
            <table style={tableStyle}>
              <thead>
                <tr style={{ background: theme.tableHeader }}>
                  <th style={thtd}>Date</th>
                  <th style={thtd}>Week</th>
                  <th style={thtd}>Home</th>
                  <th style={thtd}>Away</th>
                  <th style={thtd}>Status</th>
                  <th style={thtd}>Score</th>
                  <th style={thtd}></th>
                </tr>
              </thead>
              <tbody>
                {games.map(g => {
                  const statusChip = g.played
                    ? <Chip label="Final" color={theme.accent} />
                    : <Chip label="Scheduled" color={theme.accent2} />;
                  return (
                    <tr key={g.game_id} style={{ borderBottom: `1px solid ${theme.border}` }}>
                      <td style={thtd}>{g.game_date ?? "-"}</td>
                      <td style={thtd} align="center">{g.week ?? "-"}</td>
                      <td style={thtd}><strong>{g.home_team_name ?? g.home_team_id?.slice(0, 8)}</strong></td>
                      <td style={thtd}><strong>{g.away_team_name ?? g.away_team_id?.slice(0, 8)}</strong></td>
                      <td style={thtd}>{statusChip}</td>
                      <td style={thtd}><span style={{ fontSize: 18, fontWeight: 800 }}>{g.home_score} — {g.away_score}</span></td>
                      <td style={thtd}>
                        <button
                          onClick={() => simulate(g.game_id)}
                          style={toolbarBtn(g.played ? theme.warn : theme.accent)}
                          disabled={busy || g.played}
                          title={g.played ? "Already Final" : "Simulate this game"}
                        >
                          {g.played ? "Final" : (busy ? "Sim…" : "Simulate")}
                        </button>
                      </td>
                    </tr>
                  );
                })}
                {games.length === 0 && <tr><td style={thtd} colSpan={7}>No games yet</td></tr>}
              </tbody>
            </table>
          </div>
        </section>

        {/* Teams */}
        <section style={cardStyle}>
          <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 10 }}>
            <h2 style={{ margin: 0 }}>Teams</h2>
            <span style={{ color: theme.subtext }}>{teams.length} total</span>
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(250px, 1fr))", gap: 12 }}>
            {teams.map(t => (
              <div key={t.team_id} style={{ background: theme.panel, borderRadius: 12, padding: 12, border: `1px solid ${theme.border}` }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                  <strong style={{ fontSize: 16 }}>{t.name}</strong>
                  <Chip label={t.level} color={theme.chip}/>
                </div>
                <div style={{ color: theme.subtext, marginTop: 6 }}>
                  {t.city || "-"} · {t.mascot || "-"} <br />
                  <small>{t.league_name}</small>
                </div>
              </div>
            ))}
          </div>
        </section>

        {/* Players */}
        <section style={cardStyle}>
          <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 10 }}>
            <h2 style={{ margin: 0 }}>Players (Top 200)</h2>
            <span style={{ color: theme.subtext }}>{players.length} loaded</span>
          </div>
          <div style={{ overflowX: "auto" }}>
            <table style={tableStyle}>
              <thead>
                <tr style={{ background: theme.tableHeader }}>
                  <th style={thtd}>Name</th>
                  <th style={thtd}>Pos</th>
                  <th style={thtd}>Rating</th>
                </tr>
              </thead>
              <tbody>
                {players.map(p => (
                  <tr key={p.player_id} style={{ borderBottom: `1px solid ${theme.border}` }}>
                    <td style={thtd}>{p.first_name} {p.last_name}</td>
                    <td style={thtd}><Chip label={p.pos_code} color={theme.chip} /></td>
                    <td style={thtd}><strong>{p.rating}</strong></td>
                  </tr>
                ))}
                {players.length === 0 && <tr><td style={thtd} colSpan={3}>No players</td></tr>}
              </tbody>
            </table>
          </div>
        </section>
      </main>
      {/* Career Mode Dev Panel */}
<section style={cardStyle}>
  <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 10 }}>
    <h2 style={{ margin: 0 }}>Career Mode (Dev)</h2>
  </div>
  <CareerPanel theme={theme} />
</section>


      <footer style={{ textAlign: "center", color: theme.subtext, padding: 18 }}>
        <small>Tip: Use “Simulate All Visible” while testing, and “Reset Season” to start over.</small>
      </footer>
    </div>
  );

}
