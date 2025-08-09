"""
football_sim.py
A compact, runnable prototype of the football sim core:
- Player/Team models
- Micro play resolution with seeded randomness
- Game simulation (drives -> plays)
- Raw event logging and stat aggregation
- Simple season simulation and MVP award

This is intentionally compact and explanatory. Use as a scaffold.
"""
import random
import math
import statistics
from dataclasses import dataclass, field, asdict
from typing import List, Dict, Any, Optional
import uuid
import json
import datetime

SEED = 42

# ---------------------------
# Utilities
# ---------------------------
def seeded_rand(seed_offset=0):
    # Return a Random instance seeded deterministically for reproducibility
    return random.Random(SEED + seed_offset)

# ---------------------------
# Data Models
# ---------------------------
@dataclass
class Player:
    id: str
    name: str
    position: str  # "QB","RB","WR","TE","DL","LB","DB","K"
    age: int
    attributes: Dict[str,float]  # e.g., {"speed":75,"strength":70,"awareness":60}
    hidden_potential: float  # 0-1
    personality: Dict[str,float] = field(default_factory=dict)
    career_events: List[Dict[str,Any]] = field(default_factory=list)
    # Runtime state
    morale: float = 0.5
    fatigue: float = 0.0
    injuries: List[str] = field(default_factory=list)

    def __post_init__(self):
        # Derived quick lookup defaults
        for k in ["speed","strength","awareness","throw_power","catching","route_running","break_tackle"]:
            self.attributes.setdefault(k, 50.0)

@dataclass
class Team:
    id: str
    name: str
    city: str
    roster: List[Player]
    scheme_bias: Dict[str,float] = field(default_factory=lambda: {"pass":0.5,"run":0.5})
    coach_quality: float = 0.5
    resources: float = 1.0  # affects training, med staff, etc.
    season_stats: Dict[str,Any] = field(default_factory=lambda: {"wins":0,"losses":0,"points_for":0,"points_against":0})
    finances: Dict[str,float] = field(default_factory=lambda: {"cap":100.0})

# ---------------------------
# Raw Event / Provenance Log
# ---------------------------
class EventLog:
    def __init__(self):
        self.events: List[Dict[str,Any]] = []

    def log(self, ev:Dict[str,Any]):
        # Attach uuid and timestamp for traceability
        ev2 = dict(ev)
        ev2["event_id"] = str(uuid.uuid4())
        ev2["ts"] = datetime.datetime.utcnow().isoformat()
        self.events.append(ev2)
        return ev2["event_id"]

    def dump(self):
        return list(self.events)

# ---------------------------
# Core Simulation: play resolution
# ---------------------------
class PlayResolver:
    def __init__(self, rng: random.Random):
        self.rng = rng

    def resolve_play(self, play_call:Dict[str,Any], offense:Team, defense:Team)->Dict[str,Any]:
        """
        Simplified micro-resolution:
        play_call: {"type":"pass"/"run","primary":Player}
        returns raw event dict capturing outcome and involved players.
        """
        off_player:Player = play_call["primary"]
        play_type = play_call["type"]
        base_yards = 0
        ev = {
            "play_type": play_type,
            "offense_team": offense.id,
            "defense_team": defense.id,
            "primary_player_id": off_player.id,
            "involved_ids": [p.id for p in [off_player]],
            "result": {}
        }

        # fatigue and morale modifiers
        off_effect = (off_player.attributes.get("awareness",50)/50.0) * (1 - off_player.fatigue)
        team_coach = offense.coach_quality
        def_effect = (defense.coach_quality if hasattr(defense,'coach_quality') else 0.5)

        if play_type == "pass":
            # compute completion chance
            qb = next((p for p in offense.roster if p.position=="QB"), None)
            target = off_player
            if qb is None or target is None:
                # failed safe
                ev["result"] = {"complete": False, "yards": 0, "td": False, "interception": False, "notes":"no qb/target"}
                return ev

            qb_acc = qb.attributes.get("awareness",50) * 0.6 + qb.attributes.get("throw_power",50) * 0.4
            target_skill = target.attributes.get("route_running",50)*0.6 + target.attributes.get("catching",50)*0.4
            coverage = statistics.mean([p.attributes.get("awareness",50) for p in defense.roster if p.position in ("DB","LB")]) if defense.roster else 50
            # pressure factor from pass rush (DL)
            rush = statistics.mean([p.attributes.get("strength",50) for p in defense.roster if p.position in ("DL",)])
            pressure_prob = self._logistic((rush - qb.attributes.get("awareness",50))/20.0)
            pressure = self.rng.random() < pressure_prob

            # base prob
            prob = 0.35 + (qb_acc-50)/200 + (target_skill-50)/300 - (coverage-50)/200
            if pressure:
                prob -= 0.10
            # clamp
            prob = max(0.03, min(0.95, prob))
            complete = self.rng.random() < prob

            # yards model
            depth = play_call.get("depth", 6 + int((target.attributes.get("speed",50)-50)/5)) # simple depth heuristic
            yac = 0
            if complete:
                yac = max(0, int((target.attributes.get("break_tackle",50)/50.0) * (self.rng.random()*6)))
                # yard gain is depth +/- variation + yac
                yard_variation = int((target_skill-50)/10) + self.rng.randint(-3,6)
                yards = max(0, depth + yard_variation + yac)
                td = yards >= 40 and self.rng.random() < 0.05 + (target.attributes.get("speed",50)-50)/200.0
                interception = False
            else:
                yards = 0
                td = False
                # chance interception on badly thrown passes
                interception = (self.rng.random() < 0.03) or (self.rng.random() < 0.01 and prob < 0.1)

            # injuries chance from collisions on receptions or tackles
            injury = None
            if complete and self.rng.random() < 0.005:
                injury = self._sample_injury()

            ev["result"] = {"complete": complete, "yards": yards, "td": bool(td), "interception": bool(interception), "pressure": pressure, "yac": yac, "injury": injury}
            return ev

        elif play_type == "run":
            runner = off_player
            run_skill = runner.attributes.get("break_tackle",50)*0.6 + runner.attributes.get("speed",50)*0.4
            line_strength = statistics.mean([p.attributes.get("strength",50) for p in offense.roster if p.position in ("OL",)]) if offense.roster else 50
            def_front = statistics.mean([p.attributes.get("strength",50) for p in defense.roster if p.position in ("DL","LB")]) if defense.roster else 50
            base = max(0, int((run_skill - def_front)/10) + int(line_strength/50) + self.rng.randint(-2,8))
            yards = max(0, base + self.rng.randint(-3,8))
            td = yards >= 60 and self.rng.random() < 0.03
            broken_tackles = int((runner.attributes.get("break_tackle",50)-40)/15) if yards>3 else 0
            injury = None
            if self.rng.random() < 0.004:
                injury = self._sample_injury()
            ev["result"] = {"yards": yards, "td": bool(td), "broken_tackles": broken_tackles, "injury": injury}
            return ev

        else:
            ev["result"] = {"complete": False, "yards":0, "notes":"unknown play"}
            return ev

    def _logistic(self, x):
        return 1.0 / (1.0 + math.exp(-x))

    def _sample_injury(self):
        # simple injury sampling
        injuries = ["hamstring","concussion","sprain","torn_acl"]
        weights = [0.6, 0.2, 0.18, 0.02]
        return self.rng.choices(injuries, weights)[0]

# ---------------------------
# Game & Season Simulation
# ---------------------------
class GameSimulator:
    def __init__(self, rng: random.Random):
        self.rng = rng
        self.resolver = PlayResolver(rng)
        self.log = EventLog()

    def simulate_game(self, home:Team, away:Team)->Dict[str,Any]:
        """
        Simplified: 4 quarters, each team gets set number of drives (~8), drives produce points
        """
        game_id = str(uuid.uuid4())
        game_record = {"game_id":game_id, "home":home.id, "away":away.id, "plays":[], "score":{"home":0,"away":0}}
        # seed-specific rng for this game determinism
        for quarter in range(1,5):
            drives_per_quarter = 2
            for d in range(drives_per_quarter):
                # choose offense
                offense = home if ((d + quarter) % 2 == 0) else away
                defense = away if offense is home else home
                # simple drive: choose a sequence of plays
                plays_in_drive = self.rng.randint(3,8)
                drive_yards = 0
                drive_score = 0
                for pnum in range(plays_in_drive):
                    # choose play type biased by offense scheme
                    roll = self.rng.random()
                    play_type = "run" if roll < offense.scheme_bias.get("run",0.5) else "pass"
                    # pick primary player depending on play type
                    if play_type == "run":
                        candidates = [pl for pl in offense.roster if pl.position=="RB"]
                        if not candidates:
                            candidates = [pl for pl in offense.roster if pl.position in ("FB","WR")]
                    else:
                        candidates = [pl for pl in offense.roster if pl.position in ("WR","TE")]
                        if not candidates:
                            candidates = [pl for pl in offense.roster if pl.position=="RB"]
                    if not candidates:
                        # no appropriate player: skip
                        continue
                    primary = self.rng.choice(candidates)
                    play_call = {"type":play_type, "primary":primary, "depth":6}
                    ev = self.resolver.resolve_play(play_call, offense, defense)
                    ev["game_id"] = game_id
                    ev["quarter"] = quarter
                    ev["drive_index"] = d
                    ev["offense_is_home"] = (offense is home)
                    self.log.log(ev)
                    game_record["plays"].append(ev)
                    # update drive stat summary
                    outcome = ev["result"]
                    if play_type=="pass":
                        if outcome.get("complete"):
                            drive_yards += int(outcome.get("yards",0))
                        if outcome.get("td"):
                            # 6 points
                            drive_score += 6
                    else:
                        drive_yards += int(outcome.get("yards",0))
                        if outcome.get("td"):
                            drive_score += 6
                    # injury apply
                    if outcome.get("injury"):
                        primary.injuries.append({"injury":outcome.get("injury"), "when":datetime.datetime.utcnow().isoformat()})
                        primary.career_events.append({"type":"injury","injury":outcome.get("injury"), "game_id":game_id})
                # end drive - possible field goal or touchdown
                # simple scoring chance
                if drive_score>0:
                    # assign to offense
                    if offense is home:
                        game_record["score"]["home"] += drive_score
                        home.season_stats["points_for"] += drive_score
                        away.season_stats["points_against"] += drive_score
                    else:
                        game_record["score"]["away"] += drive_score
                        away.season_stats["points_for"] += drive_score
                        home.season_stats["points_against"] += drive_score
                else:
                    # maybe settle for a FG with low chance but based on yards
                    if drive_yards > 30 and self.rng.random() < 0.12:
                        fg = 3
                        if offense is home:
                            game_record["score"]["home"] += fg
                            home.season_stats["points_for"] += fg
                            away.season_stats["points_against"] += fg
                        else:
                            game_record["score"]["away"] += fg
                            away.season_stats["points_for"] += fg
                            home.season_stats["points_against"] += fg

        # finalize winner
        if game_record["score"]["home"] > game_record["score"]["away"]:
            home.season_stats["wins"] += 1
            away.season_stats["losses"] += 1
        elif game_record["score"]["away"] > game_record["score"]["home"]:
            away.season_stats["wins"] += 1
            home.season_stats["losses"] += 1
        else:
            # tie -> half win each in this simple model
            home.season_stats["wins"] += 0
            away.season_stats["wins"] += 0
        return game_record

# ---------------------------
# Stat Aggregator & Award Engine
# ---------------------------
class StatAggregator:
    def __init__(self, events:List[Dict[str,Any]]):
        self.events = events

    def aggregate(self)->Dict[str,Dict[str,float]]:
        """
        Produce basic aggregated stats per player id.
        Returns {player_id: {stat: value}}
        """
        agg:Dict[str,Dict[str,float]] = {}
        for ev in self.events:
            res = ev.get("result",{})
            pid = ev.get("primary_player_id")
            if pid is None:
                continue
            if pid not in agg:
                agg[pid] = {"games_played":0,"pass_completions":0,"pass_attempts":0,"pass_yards":0,"pass_tds":0,
                            "rush_attempts":0,"rush_yards":0,"rush_tds":0,"broken_tackles":0,"targets":0,"yac":0}
            # simple heuristics
            if ev.get("play_type")=="pass":
                agg[pid]["pass_attempts"] += 1
                if res.get("complete"):
                    agg[pid]["pass_completions"] += 1
                    agg[pid]["pass_yards"] += res.get("yards",0)
                    agg[pid]["pass_tds"] += 1 if res.get("td") else 0
                    agg[pid]["yac"] += res.get("yac",0)
                else:
                    # possible interception
                    if res.get("interception"):
                        pass
                agg[pid]["targets"] += 1
            elif ev.get("play_type")=="run":
                agg[pid]["rush_attempts"] += 1
                agg[pid]["rush_yards"] += res.get("yards",0)
                agg[pid]["rush_tds"] += 1 if res.get("td") else 0
                agg[pid]["broken_tackles"] += res.get("broken_tackles",0)
            # games_played is rough; one event -> a snap -> counts as presence
            agg[pid]["games_played"] = agg[pid].get("games_played",0) + 0.01
        # normalize games_played to more reasonable value by dividing by average snaps per simulated game
        for pid,stats in agg.items():
            stats["games_played"] = round(stats["games_played"] / 6.0, 2)  # approx scaling
        return agg

class AwardEngine:
    def __init__(self, player_lookup:Dict[str,Player], agg_stats:Dict[str,Dict[str,float]]):
        self.player_lookup = player_lookup
        self.agg_stats = agg_stats

    def compute_mvp(self, top_n=3)->List[Dict[str,Any]]:
        """
        Simple MVP ranking by impact_score = rush_yards*0.7 + pass_yards*1.1 + rush_tds*20 + pass_tds*25 + yac*0.3
        Return top_n candidates with justification snippets.
        """
        candidates = []
        for pid, stats in self.agg_stats.items():
            p = self.player_lookup.get(pid)
            if p is None:
                continue
            impact = stats.get("rush_yards",0)*0.7 + stats.get("pass_yards",0)*1.1 + stats.get("rush_tds",0)*20 + stats.get("pass_tds",0)*25 + stats.get("yac",0)*0.3
            # narrative boost from morale / injuries
            narrative_boost = (p.morale - 0.5)*10 - (len(p.injuries)*5)
            score = impact + narrative_boost
            candidates.append({"player":p, "stats":stats, "impact":impact, "score":score})
        candidates.sort(key=lambda x: x["score"], reverse=True)
        # create justification
        results = []
        for c in candidates[:top_n]:
            p=c["player"]
            s=c["stats"]
            reasons=[]
            if s.get("pass_yards",0)>200:
                reasons.append(f"{s.get('pass_yards',0)} passing yards")
            if s.get("rush_yards",0)>200:
                reasons.append(f"{s.get('rush_yards',0)} rushing yards")
            if s.get("pass_tds",0)+s.get("rush_tds",0)>2:
                reasons.append(f"{s.get('pass_tds',0)+s.get('rush_tds',0)} total TDs")
            if len(p.injuries)>0:
                reasons.append(f"played through {len(p.injuries)} injury events")
            justification = "; ".join(reasons) if reasons else "consistently high impact plays"
            results.append({"player_id":p.id,"player_name":p.name,"score":round(c["score"],2),"impact":round(c["impact"],2),"justification":justification})
        return results

# ---------------------------
# Example: Build small league, simulate season
# ---------------------------
def build_sample_team(team_name:str, city:str, seed_offset:int=0)->Team:
    rng = seeded_rand(seed_offset)
    roster=[]
    # create QB
    qb = Player(id=str(uuid.uuid4()), name=f"{team_name} QB", position="QB", age=24,
                attributes={"awareness":rng.randint(55,85),"throw_power":rng.randint(60,95),"speed":rng.randint(40,70)}, hidden_potential=rng.random())
    roster.append(qb)
    # RBs
    for i in range(2):
        r = Player(id=str(uuid.uuid4()), name=f"{team_name} RB{i+1}", position="RB", age=20+rng.randint(0,6),
                   attributes={"speed":rng.randint(60,95),"break_tackle":rng.randint(45,85),"awareness":rng.randint(40,70)}, hidden_potential=rng.random())
        roster.append(r)
    # WRs
    for i in range(3):
        w = Player(id=str(uuid.uuid4()), name=f"{team_name} WR{i+1}", position="WR", age=19+rng.randint(0,8),
                   attributes={"speed":rng.randint(60,99),"route_running":rng.randint(50,90),"catching":rng.randint(45,90)}, hidden_potential=rng.random())
        roster.append(w)
    # OL placeholder
    for i in range(5):
        o = Player(id=str(uuid.uuid4()), name=f"{team_name} OL{i+1}", position="OL", age=25+rng.randint(0,6),
                   attributes={"strength":rng.randint(50,90),"awareness":rng.randint(40,70)}, hidden_potential=rng.random())
        roster.append(o)
    # DL/LB/DB
    for i in range(6):
        pos = rng.choice(["DL","LB","DB"])
        d = Player(id=str(uuid.uuid4()), name=f"{team_name} {pos}{i+1}", position=pos, age=22+rng.randint(0,6),
                   attributes={"strength":rng.randint(50,95),"awareness":rng.randint(40,80)}, hidden_potential=rng.random())
        roster.append(d)
    team = Team(id=str(uuid.uuid4()), name=team_name, city=city, roster=roster,
                scheme_bias={"run":0.45,"pass":0.55} if rng.random()>0.5 else {"run":0.6,"pass":0.4},
                coach_quality=0.45 + rng.random()*0.4,
                resources=0.8 + rng.random()*0.6)
    return team

def simulate_league(season_len:int=8):
    rng = seeded_rand(0)
    gs = GameSimulator(rng)
    teamA = build_sample_team("Falcons", "Springfield", seed_offset=1)
    teamB = build_sample_team("Sharks", "Rivertown", seed_offset=2)
    teams = [teamA, teamB]

    all_game_events=[]
    games=[]
    for gidx in range(season_len):
        # alternate home/away
        home = teams[gidx % 2]
        away = teams[(gidx+1) % 2]
        gr = gs.simulate_game(home, away)
        games.append(gr)
        all_game_events.extend(gs.log.dump())
        # clear log between games to avoid duplication in this simple demo
        gs.log = EventLog()

    # aggregate stats
    aggregator = StatAggregator(all_game_events)
    agg = aggregator.aggregate()
    # build player lookup
    plook = {p.id:p for t in teams for p in t.roster}
    # award engine
    award = AwardEngine(plook, agg)
    mvps = award.compute_mvp(top_n=5)

    # print summary
    print("=== Season Summary ===")
    for t in teams:
        print(f"{t.city} {t.name} - W:{t.season_stats['wins']} L:{t.season_stats['losses']} PF:{t.season_stats['points_for']} PA:{t.season_stats['points_against']} Coach:{t.coach_quality:.2f}")

    print("\nTop Candidates (MVP):")
    for m in mvps:
        print(f"{m['player_name']} - Score: {m['score']} Impact:{m['impact']} Justification: {m['justification']}")
    print("\nSample raw events count:", len(all_game_events))
    # dump small provenance sample
    sample_ev = all_game_events[:6]
    print("\nSample raw event (first 3):")
    print(json.dumps(sample_ev[:3], indent=2))
    return {"teams":teams, "games":games, "events":all_game_events, "agg":agg, "mvps":mvps}

# ---------------------------
# Run when executed
# ---------------------------
if __name__ == "__main__":
    out = simulate_league(season_len=16)
    # optionally save outputs for further inspection
    with open("sim_output.json","w") as f:
        json.dump({
            "mvps": out["mvps"],
            "teams": [{ "id":t.id, "name":t.name, "city":t.city, "season_stats": t.season_stats} for t in out["teams"]],
            "event_count": len(out["events"])
        }, f, indent=2)
    print("\nSim output written to sim_output.json")
