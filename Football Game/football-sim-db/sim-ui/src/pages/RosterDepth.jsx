import { useEffect, useState } from "react";
const API = "http://localhost:3001/api";
export default function RosterDepth(){
  const [saveId] = useState(localStorage.getItem("careerSaveId")||"");
  const [roster,setRoster]=useState([]);
  const [depth,setDepth]=useState([]);
  const [position,setPosition]=useState("QB");
  const [slot,setSlot]=useState(1);
  const [player,setPlayer]=useState("");
  const [grade,setGrade]=useState(80);
  const [msg,setMsg]=useState("");

  async function load(){
    const r1 = await fetch(`${API}/hs/${saveId}/roster`); const d1=await r1.json(); if(d1.ok) setRoster(d1.roster||[]);
    const r2 = await fetch(`${API}/hs/${saveId}/depth`);   const d2=await r2.json(); if(d2.ok) setDepth(d2.depth||[]);
  }
  useEffect(()=>{ load(); },[]);

  async function setDepthSlot(){
    const r = await fetch(`${API}/hs/${saveId}/depth`,{
      method:"POST", headers:{ "Content-Type":"application/json" },
      body: JSON.stringify({ position, slot_order: Number(slot), playerId: player })
    });
    const d = await r.json(); if(d.ok){ setMsg("Updated depth"); load(); } else setMsg(d.error||"Failed");
  }

  async function doPractice(){
    const r = await fetch(`${API}/hs/${saveId}/practice`,{
      method:"POST", headers:{ "Content-Type":"application/json" },
      body: JSON.stringify({ grade: Number(grade) })
    });
    const d = await r.json(); if(d.ok){ setMsg(`Earned ${d.reps} reps`); } else setMsg(d.error||"Failed");
  }

  if(!saveId) return <div>Create a career first on Home.</div>;

  return (
    <div style={{ display:"grid", gap:12 }}>
      <div style={{ display:"grid", gridTemplateColumns:"1fr 1fr", gap:12 }}>
        <div>
          <h3>Roster</h3>
          <table><thead><tr><th>Name</th><th>Pos</th><th>Rating</th></tr></thead>
          <tbody>
            {roster.map(r=><tr key={r.player_id}>
              <td>{r.first_name} {r.last_name}</td><td>{r.position}</td><td>{r.rating}</td>
            </tr>)}
          </tbody></table>
        </div>
        <div>
          <h3>Depth Chart</h3>
          <table><thead><tr><th>Pos</th><th>Order</th><th>Player</th></tr></thead>
          <tbody>
            {depth.map((d,i)=><tr key={i}><td>{d.position}</td><td>{d.slot_order}</td><td>{d.name||"-"}</td></tr>)}
          </tbody></table>

          <div style={{ marginTop:8 }}>
            <select value={position} onChange={e=>setPosition(e.target.value)}>
              {["QB","RB","WR","TE","LB","DB","DL","OL","K","P"].map(p=><option key={p}>{p}</option>)}
            </select>
            <input type="number" min={1} value={slot} onChange={e=>setSlot(e.target.value)}/>
            <select value={player} onChange={e=>setPlayer(e.target.value)}>
              <option value="">(choose player)</option>
              {roster.map(r=><option key={r.player_id} value={r.player_id}>{r.first_name} {r.last_name} ({r.position})</option>)}
            </select>
            <button onClick={setDepthSlot}>Set Slot</button>
          </div>

          <div style={{ marginTop:12 }}>
            <h4>Practice</h4>
            <input type="number" value={grade} onChange={e=>setGrade(e.target.value)} min={0} max={100}/>
            <button onClick={doPractice}>Submit Grade</button>
          </div>
        </div>
      </div>
      {msg && <div>{msg}</div>}
    </div>
  );
}
