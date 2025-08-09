import { useEffect, useState } from "react";
const API = "http://localhost:3001/api";
export default function HSRankings(){
  const [saveId] = useState(localStorage.getItem("careerSaveId")||"");
  const [rows,setRows]=useState([]);
  async function compute(){ await fetch(`${API}/hs/${saveId}/compute-rankings`,{method:"POST"}); await load(); }
  async function load(){ const r = await fetch(`${API}/hs/${saveId}/rankings`); const d=await r.json(); if(d.ok) setRows(d.rankings||[]); }
  useEffect(()=>{ load(); },[]);
  if(!saveId) return <div>Create a career first on Home.</div>;
  return (
    <div>
      <div style={{ display:"flex", gap:8 }}>
        <button onClick={compute}>Compute</button>
        <button onClick={load}>Refresh</button>
      </div>
      <table><thead><tr><th>#</th><th>Name</th><th>Pos</th><th>Score</th></tr></thead>
      <tbody>
        {rows.map((r,i)=><tr key={i}><td>{r.rank_overall||"-"}</td><td>{r.first_name} {r.last_name}</td><td>{r.position}</td><td>{Number(r.score).toFixed(1)}</td></tr>)}
      </tbody></table>
    </div>
  );
}
