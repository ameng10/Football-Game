import { useEffect, useState } from "react";
const API = "http://localhost:3001/api";

export default function CareerHome(){
  const [saveId, setSaveId] = useState(localStorage.getItem("careerSaveId") || "");
  const [state, setState] = useState(null);
  const [first, setFirst] = useState("Alex");
  const [last, setLast] = useState("Player");
  const [pos, setPos] = useState("QB");
  const [stars, setStars] = useState(3);
  const [msg,setMsg] = useState("");

  async function load(){
    if(!saveId) return;
    const r = await fetch(`${API}/career/${saveId}/state`);
    const d = await r.json();
    if(d.ok) setState(d.state);
  }
  useEffect(()=>{ load(); },[saveId]);

  async function createSave(){
    const r = await fetch(`${API}/career/create`, {
      method:"POST", headers:{ "Content-Type":"application/json" },
      body: JSON.stringify({ saveName:"My HS Career", first, last, pos, stars })
    });
    const d = await r.json();
    if(d.ok){ localStorage.setItem("careerSaveId", d.saveId); setSaveId(d.saveId); setMsg("Created!"); }
    else setMsg(d.error||"Failed");
  }

  async function customize(){
    const r = await fetch(`${API}/career/${saveId}/customize`, {
      method:"POST", headers:{ "Content-Type":"application/json" },
      body: JSON.stringify({ pos, stars })
    });
    const d = await r.json(); if(d.ok){ setMsg("Updated!"); load(); } else setMsg(d.error||"Failed");
  }

  async function scheduleHS(){
    const r = await fetch(`${API}/career/${saveId}/schedule-hs`, { method:"POST" });
    const d = await r.json(); if(d.ok){ setMsg("Season scheduled"); } else setMsg(d.error||"Failed");
  }

  async function simWeek(){
    const r = await fetch(`${API}/career/${saveId}/sim-week`, { method:"POST" });
    const d = await r.json(); if(d.ok){ setMsg("Week played"); load(); } else setMsg(d.error||"Failed");
  }

  return (
    <div style={{ display:"grid", gap:12 }}>
      {!saveId && (
        <div style={{ display:"grid", gap:8, gridTemplateColumns:"repeat(auto-fit,minmax(180px,1fr))" }}>
          <input value={first} onChange={e=>setFirst(e.target.value)} placeholder="First name"/>
          <input value={last} onChange={e=>setLast(e.target.value)} placeholder="Last name"/>
          <select value={pos} onChange={e=>setPos(e.target.value)}>
            <option>QB</option><option>RB</option><option>WR</option><option>TE</option><option>LB</option><option>DB</option><option>DL</option>
          </select>
          <input type="number" min={0} max={5} value={stars} onChange={e=>setStars(Number(e.target.value||0))}/>
          <button onClick={createSave}>Create Career</button>
        </div>
      )}

      {saveId && (
        <>
          <div style={{ display:"flex", gap:8, flexWrap:"wrap" }}>
            <strong>Save:</strong> <code>{saveId.slice(0,8)}…</code>
            <button onClick={load}>Refresh</button>
            <button onClick={scheduleHS}>Schedule HS Season</button>
            <button onClick={simWeek}>Simulate Current Week</button>
          </div>

          {state && (
            <div style={{ display:"grid", gap:6 }}>
              <div><strong>{state.first_name} {state.last_name}</strong> · {state.position_goal} · {state.star_rating}★ · Grade {state.grade_level}</div>
              <div>Training Points: <strong>{state.training_points}</strong> · Followers: <strong>{state.followers}</strong></div>
              <div>Phase: {state.calendar?.phase} · Week: {state.calendar?.week}</div>
              <div>
                <em>Customize:</em>&nbsp;
                <select value={pos} onChange={e=>setPos(e.target.value)}><option>QB</option><option>RB</option><option>WR</option><option>TE</option><option>LB</option><option>DB</option><option>DL</option></select>
                <input type="number" min={0} max={5} value={stars} onChange={e=>setStars(Number(e.target.value||0))}/>
                <button onClick={customize}>Apply</button>
              </div>
            </div>
          )}
        </>
      )}

      {msg && <div>{msg}</div>}
    </div>
  );
}
