import { useEffect, useRef, useState } from "react";
const API = "http://localhost:3001/api";

export default function Training(){
  const [saveId] = useState(localStorage.getItem("careerSaveId")||"");
  const [mode,setMode]=useState("generic");
  const [score,setScore]=useState(0);
  const [running,setRunning]=useState(false);
  const targetRef = useRef(null);
  const timerRef = useRef(null);
  const [msg,setMsg]=useState("");

  function start(){
    setScore(0); setRunning(true);
    let t=10;
    timerRef.current = setInterval(()=>{
      t--;
      if(t<=0){ stop(); }
      // move target each second
      moveTarget();
    },1000);
    moveTarget();
  }
  function stop(){ setRunning(false); clearInterval(timerRef.current); }

  function moveTarget(){
    const el = targetRef.current;
    if(!el) return;
    const x = Math.random()*80;
    const y = Math.random()*200;
    el.style.transform = `translate(${x}vw, ${y}px)`;
  }

  async function submit(simulate=false){
    const r = await fetch(`${API}/career/${saveId}/minigame`, {
      method:"POST", headers:{ "Content-Type":"application/json" },
      body: JSON.stringify({ mode, score, simulate })
    });
    const d = await r.json();
    if(d.ok) setMsg(`+${d.points} training points earned`);
    else setMsg(d.error||"Failed");
  }

  if(!saveId) return <div>Create a career first on Home.</div>;

  return (
    <div style={{ display:"grid", gap:12 }}>
      <div>
        <select value={mode} onChange={e=>setMode(e.target.value)}>
          <option value="generic">Generic</option>
          <option value="qb_accuracy">QB Accuracy</option>
          <option value="rb_agility">RB Agility</option>
          <option value="wr_hands">WR Hands</option>
        </select>
      </div>

      <div style={{ position:"relative", height:260, border:"1px dashed #888", borderRadius:8, overflow:"hidden" }}>
        <button
          ref={targetRef}
          onClick={()=>running && setScore(s=>s+1)}
          style={{ position:"absolute", transform:"translate(10vw, 100px)", padding:"8px 12px", borderRadius:999, cursor:"pointer" }}
        >🎯 Hit me</button>
      </div>

      <div style={{ display:"flex", gap:8, alignItems:"center" }}>
        <div>Score: <strong>{score}</strong></div>
        {!running ? <button onClick={start}>Start (10s)</button> : <button onClick={stop}>Stop</button>}
        <button onClick={()=>submit(false)} disabled={running}>Submit Score</button>
        <button onClick={()=>submit(true)} disabled={running}>Simulate (base points)</button>
      </div>

      {msg && <div>{msg}</div>}
    </div>
  );
}
