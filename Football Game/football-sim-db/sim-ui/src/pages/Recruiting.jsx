import { useEffect, useState } from "react";
const API = "http://localhost:3001/api";
export default function Recruiting(){
  const [saveId] = useState(localStorage.getItem("careerSaveId")||"");
  const [offers,setOffers]=useState([]);
  const [msg,setMsg]=useState("");

  async function load(){
    const r = await fetch(`${API}/career/${saveId}/offers`);
    const d = await r.json();
    if(d.ok) setOffers(d.offers||[]);
  }
  useEffect(()=>{ load(); },[]);

  async function gen(){
    const r = await fetch(`${API}/career/${saveId}/offers`,{ method:"POST" });
    const d = await r.json();
    if(d.ok){ setMsg(`Generated ${d.offers} offers`); load(); } else setMsg(d.error||"Failed");
  }
  async function commit(teamId){
    const r = await fetch(`${API}/career/${saveId}/commit`,{
      method:"POST", headers:{ "Content-Type":"application/json" },
      body: JSON.stringify({ teamId })
    });
    const d = await r.json(); if(d.ok){ setMsg("Committed!"); load(); } else setMsg(d.error||"Failed");
  }

  if(!saveId) return <div>Create a career first on Home.</div>;
  return (
    <div>
      <div style={{ display:"flex", gap:8, marginBottom:8 }}>
        <button onClick={gen}>Generate Offers</button>
        <button onClick={load}>Refresh</button>
      </div>
      <div style={{ display:"grid", gap:8 }}>
        {offers.length===0 && <div>No offers yet.</div>}
        {offers.map(o=>(
          <div key={o.team_id} style={{ display:"flex", justifyContent:"space-between", border:"1px solid #ddd", borderRadius:8, padding:8 }}>
            <div>{o.team_name}</div>
            <button onClick={()=>commit(o.team_id)} disabled={o.committed}>Commit</button>
          </div>
        ))}
      </div>
      {msg && <div style={{ marginTop:8 }}>{msg}</div>}
    </div>
  );
}
