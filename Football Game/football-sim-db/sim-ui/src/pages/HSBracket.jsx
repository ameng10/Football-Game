import { useEffect, useState } from "react";
const API = "http://localhost:3001/api";
export default function HSBracket(){
  const [saveId] = useState(localStorage.getItem("careerSaveId")||"");
  const [rows,setRows]=useState([]);
  async function build(){
    await fetch(`${API}/hs/${saveId}/build-bracket`,{method:"POST"});
    await load();
  }
  async function load(){
    const r = await fetch(`${API}/hs/${saveId}/bracket`); const d = await r.json();
    if(d.ok) setRows(d.bracket||[]);
  }
  useEffect(()=>{ load(); },[]);
  if(!saveId) return <div>Create a career first on Home.</div>;
  const byRound = rows.reduce((m,r)=>{ m[r.round]=m[r.round]||[]; m[r.round].push(r); return m; },{});
  return (
    <div>
      <div style={{ display:"flex", gap:8 }}>
        <button onClick={build}>Build from Standings</button>
        <button onClick={load}>Refresh</button>
      </div>
      <div style={{ display:"grid", gridTemplateColumns:`repeat(${Object.keys(byRound).length||1}, 1fr)`, gap:12, marginTop:12 }}>
        {Object.entries(byRound).map(([rnd, list])=>(
          <div key={rnd} style={{ border:"1px solid #ccc", borderRadius:8, padding:8 }}>
            <h3 style={{ marginTop:0 }}>Round {rnd}</h3>
            {list.map((m,i)=><div key={i} style={{ padding:6, borderBottom:"1px dashed #ddd" }}>
              {m.seed_home} {m.home_name} vs {m.seed_away} {m.away_name}
            </div>)}
          </div>
        ))}
      </div>
    </div>
  );
}
