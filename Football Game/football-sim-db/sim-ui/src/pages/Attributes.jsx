import { useEffect, useState } from "react";
const API = "http://localhost:3001/api";
export default function Attributes(){
  const [saveId] = useState(localStorage.getItem("careerSaveId")||"");
  const [state,setState]=useState(null);
  const [attr,setAttr]=useState("speed");
  const [pts,setPts]=useState(5);
  const [msg,setMsg]=useState("");

  async function load(){
    if(!saveId) return;
    const r = await fetch(`${API}/career/${saveId}/state`);
    const d = await r.json();
    if(d.ok) setState(d.state);
  }
  useEffect(()=>{ load(); },[]);

  async function apply(){
    const r = await fetch(`${API}/career/${saveId}/train/apply`, {
      method:"POST", headers:{ "Content-Type":"application/json" },
      body: JSON.stringify({ attribute: attr, points: pts })
    });
    const d = await r.json();
    if(d.ok){ setMsg(`Upgraded ${attr}!`); load(); } else setMsg(d.error||"Failed");
  }

  if(!saveId) return <div>Create a career first on Home.</div>;
  return (
    <div style={{ display:"grid", gap:12 }}>
      <button onClick={load}>Refresh</button>
      {state && (
        <div style={{ display:"grid", gap:6 }}>
          <div>Training Points: <strong>{state.training_points}</strong></div>
          <pre style={{ whiteSpace:"pre-wrap", background:"#0001", padding:8, borderRadius:8 }}>
            {JSON.stringify(state.attrs, null, 2)}
          </pre>
          <div>
            <select value={attr} onChange={e=>setAttr(e.target.value)}>
              {["rating","speed","agility","awareness","stamina","throw_power","throw_acc","catching","tackle","strength","carry"].map(a=><option key={a}>{a}</option>)}
            </select>
            <input type="number" min={1} value={pts} onChange={e=>setPts(Number(e.target.value||1))}/>
            <button onClick={apply}>Apply</button>
          </div>
        </div>
      )}
      {msg && <div>{msg}</div>}
    </div>
  );
}
