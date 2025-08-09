import { useEffect, useState } from "react";
const API = "http://localhost:3001/api";
export default function HSStandings(){
  const [saveId] = useState(localStorage.getItem("careerSaveId")||"");
  const [rows,setRows]=useState([]);
  async function load(){
    const r = await fetch(`${API}/hs/${saveId}/standings`);
    const d = await r.json();
    if(d.ok) setRows(d.standings||[]);
  }
  useEffect(()=>{ load(); },[]);
  if(!saveId) return <div>Create a career first on Home.</div>;
  return (
    <div>
      <div style={{ display:"flex", gap:8, marginBottom:8 }}>
        <button onClick={load}>Refresh</button>
      </div>
      <table><thead><tr><th>Team</th><th>W</th><th>L</th><th>PF</th><th>PA</th></tr></thead>
        <tbody>
          {rows.map((r,i)=><tr key={i}><td>{r.name}</td><td>{r.wins}</td><td>{r.losses}</td><td>{r.points_for}</td><td>{r.points_against}</td></tr>)}
        </tbody>
      </table>
    </div>
  );
}
