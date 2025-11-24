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
import os
import time
import itertools
import re

# Base seed: default None -> time-based for variability. Set SIM_SEED to pin runs.
SEED = None

# ---------------------------
# Utilities
# ---------------------------
def seeded_rand(seed_offset=0):
    """
    Return a Random instance. If SIM_SEED env var is set, use it for reproducibility.
    Otherwise, use a time-based seed so runs vary even with the same starting player.
    """
    base_seed = SEED
    env_seed = os.environ.get("SIM_SEED")
    if env_seed is not None:
        try:
            base_seed = int(env_seed)
        except ValueError:
            base_seed = None
    if base_seed is None:
        base_seed = int(time.time_ns() % 1_000_000_000)
    return random.Random(base_seed + seed_offset)

def team_rating(team:"Team")->float:
    """Simple overall derived from key attributes across roster."""
    if not team.roster:
        return 50.0
    vals=[]
    for p in team.roster:
        vals.append(p.attributes.get("awareness",50))
        vals.append(p.attributes.get("speed",50))
        vals.append(p.attributes.get("strength",50))
    return statistics.mean(vals)

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

@dataclass
class FbsSchool:
    id: str
    name: str
    prestige: float  # 0-1, used for offer weighting
    scheme_bias: Dict[str,float]
    location: str

@dataclass
class NflFranchise:
    id: str
    name: str
    city: str
    prestige: float  # 0-1

@dataclass
class CareerState:
    player: Player
    stage: str  # "HS","COLLEGE","NFL"
    calendar: Dict[str,int]
    star_rating: float
    hs_stats: List[Dict[str,Any]] = field(default_factory=list)
    college_stats: List[Dict[str,Any]] = field(default_factory=list)
    college_offers: List[Dict[str,Any]] = field(default_factory=list)
    college_team: Optional[FbsSchool] = None
    draft_projection: Optional[str] = None
    nfl_team: Optional[str] = None
    awards: List[Dict[str,Any]] = field(default_factory=list)
    retired: bool = False
    retired_year: Optional[int] = None
    history: List[str] = field(default_factory=list)

# ---------------------------
# Career Mode Engine (HS -> College -> NFL)
# ---------------------------
def build_fbs_catalog()->List[FbsSchool]:
    # Full FBS list (133 teams) with rough prestige tiers derived from ordering
    fbs_names = [
        "Air Force","Akron","Alabama","Appalachian State","Arizona","Arizona State","Arkansas",
        "Arkansas State","Army","Auburn","Ball State","Baylor","Boise State","Boston College",
        "Bowling Green","Buffalo","BYU","California","Central Michigan","Charlotte","Cincinnati",
        "Clemson","Coastal Carolina","Colorado","Colorado State","Duke","East Carolina","Eastern Michigan",
        "Florida","Florida Atlantic","Florida International","Florida State","Fresno State","Georgia",
        "Georgia Southern","Georgia State","Georgia Tech","Hawaii","Houston","Illinois","Indiana",
        "Iowa","Iowa State","James Madison","Kansas","Kansas State","Kent State","Kentucky",
        "Liberty","Louisiana","Louisiana Tech","Louisville","LSU","Marshall","Maryland","Memphis",
        "Miami (FL)","Miami (OH)","Michigan","Michigan State","Middle Tennessee","Minnesota",
        "Mississippi State","Missouri","Navy","NC State","Nebraska","Nevada","New Mexico",
        "New Mexico State","North Carolina","North Texas","Northern Illinois","Northwestern",
        "Notre Dame","Ohio","Ohio State","Oklahoma","Oklahoma State","Old Dominion","Ole Miss",
        "Oregon","Oregon State","Penn State","Pittsburgh","Purdue","Rice","Rutgers","San Diego State",
        "San Jose State","SMU","South Alabama","South Carolina","South Florida","Southern Miss",
        "Stanford","Syracuse","TCU","Temple","Tennessee","Texas","Texas A&M","Texas State",
        "Texas Tech","Toledo","Troy","Tulane","Tulsa","UAB","UCF","UCLA","UConn","UMass",
        "UNLV","USC","Utah","Utah State","UTEP","UTSA","Vanderbilt","Virginia","Virginia Tech",
        "Wake Forest","Washington","Washington State","West Virginia","Western Kentucky",
        "Western Michigan","Wisconsin","Wyoming","App State","Sam Houston","Jacksonville State",
        "Kennesaw State","James Madison (FBS)","Coastal Carolina (FBS)"
    ]
    # de-dup and ensure length
    seen = set()
    unique_names = []
    for n in fbs_names:
        if n.lower() in seen:
            continue
        seen.add(n.lower())
        unique_names.append(n)
    total = len(unique_names)
    catalog = []
    for idx, name in enumerate(unique_names):
        prestige = max(0.35, 0.95 - (idx/(total*1.1)))
        scheme = {"pass":0.45 + ((idx%5)*0.05), "run":0.55 - ((idx%5)*0.05)}
        slug = re.sub(r'[^A-Za-z ]','', name).strip()
        words = slug.split()
        if not words:
            abbr = f"FBS{idx:03d}"
        else:
            abbr = "".join(w[0] for w in words).upper()[:4]
            if len(abbr)<2:
                abbr = (words[0][:4]).upper()
        catalog.append(FbsSchool(id=abbr, name=name, location=name, prestige=prestige, scheme_bias=scheme))
    return catalog

class CareerEngine:
    def __init__(self, rng: random.Random):
        self.rng = rng
        self.fbs_catalog = build_fbs_catalog()

    def _base_attr_for_stars(self, stars:float)->float:
        # Map 0-5 stars to an overall-ish target (zengm-style normalization)
        return 42 + stars*9 + self.rng.uniform(-2,2)

    def create_prospect(self, first:str, last:str, pos:str="QB", stars:int=3)->CareerState:
        base = self._base_attr_for_stars(stars)
        potential = min(1.0, max(0.1, 0.35 + stars*0.12 + self.rng.uniform(-0.05,0.08)))
        attrs = {
            "speed": base + self.rng.randint(-5,6),
            "strength": base + self.rng.randint(-5,6),
            "awareness": base + self.rng.randint(-4,8),
            "throw_power": base + self.rng.randint(-2,10) if pos=="QB" else base + self.rng.randint(-6,4),
            "catching": base + self.rng.randint(-6,6),
            "route_running": base + self.rng.randint(-6,6),
            "break_tackle": base + self.rng.randint(-6,6)
        }
        p = Player(
            id=str(uuid.uuid4()),
            name=f"{first} {last}",
            position=pos,
            age=17,
            attributes=attrs,
            hidden_potential=potential,
            personality={"work_ethic": self.rng.random(), "composure": self.rng.random()}
        )
        return CareerState(
            player=p,
            stage="HS",
            calendar={"phase":"HS", "year":1, "week":1},
            star_rating=float(stars),
            history=[f"Created {stars}-star {pos} prospect {p.name} (pot {potential:.2f})"]
        )

    def simulate_high_school_year(self, state:CareerState, year:int)->Dict[str,Any]:
        p = state.player
        volatility = max(0.15, (6 - state.star_rating)/6)  # more volatility for low stars
        overall_before = round(self._overall(p),1)
        touches = 80 + int(self.rng.random()*40)
        per_touch = (p.attributes.get("speed",50)+p.attributes.get("awareness",50))/18
        swing = self.rng.uniform(0.55 - volatility*0.25, 1.2 + volatility*0.45)
        production = max(250, int(per_touch*touches*swing))
        tds = int(max(2, production/120 * self.rng.uniform(0.8,1.2)))
        awards = []
        if production > 1400 and self.rng.random()<0.5:
            awards.append("All-State")
        if production > 1800 and self.rng.random()<0.35:
            awards.append("HS National POY")
        hs_line = {"year": year, "production_yards": production, "tds": tds, "awards": awards, "overall_before": overall_before}
        state.hs_stats.append(hs_line)
        state.history.append(f"HS year {year}: {production} yds, {tds} TDs (Ovr {overall_before})")
        for a in awards:
            state.awards.append({"level":"HS","year":year,"name":a})
            state.history.append(f"HS award: {a}")

        # Rating movement from performance and hidden potential
        perf_delta = (production/1000 - 1) * (0.4 + volatility*0.3)
        potential_delta = (p.hidden_potential-0.5)*0.6
        state.star_rating = max(1.0, min(5.0, state.star_rating + perf_delta + potential_delta + self.rng.uniform(-0.25*volatility,0.3)))
        growth = 1 + p.hidden_potential*2.5 + volatility*0.8
        for k in ["speed","awareness","throw_power","route_running","break_tackle","strength"]:
            p.attributes[k] += self.rng.uniform(0.4, growth)
        # Adjust hidden potential slightly based on production to mimic scouting updates
        pot_delta = (production/1200.0 - 1) * (0.05 + volatility*0.05) + self.rng.uniform(-0.03*volatility,0.03*volatility)
        p.hidden_potential = max(0.1, min(1.0, p.hidden_potential + pot_delta))
        p.age += 1
        state.calendar = {"phase":"HS", "year":year, "week":15}
        # record post progression
        hs_line["overall_after"] = round(self._overall(p),1)
        state.history.append(f"HS year {year} progression: {overall_before} -> {hs_line['overall_after']}")
        return hs_line

    def _offer_count_for_rating(self, stars:float)->int:
        # Bigger separation: 1-star (1-5), 2-star (3-10), 3-star (8-20), 4-star (15-35), 5-star (40-70)
        if stars <= 1.5:
            base, spread = 1, 4
        elif stars <= 2.5:
            base, spread = 3, 7
        elif stars <= 3.5:
            base, spread = 8, 12
        elif stars <= 4.5:
            base, spread = 15, 20
        else:
            base, spread = 80, 50
        return max(1, base + self.rng.randint(0, spread))

    def generate_college_offers(self, state:CareerState)->List[Dict[str,Any]]:
        if state.stage != "HS":
            return state.college_offers
        # factor in latest HS production for interest level
        recent = state.hs_stats[-1] if state.hs_stats else {"production_yards": 0, "tds": 0}
        perf_score = (recent.get("production_yards",0)/1200.0) + (recent.get("tds",0)/12.0)
        perf_score = max(0.2, min(2.5, perf_score))
        offers = []
        num = self._offer_count_for_rating(state.star_rating)
        weights = []
        for s in self.fbs_catalog:
            # high prestige schools prefer high stars; HS stats give a bump; inject randomness to mimic scouting variance
            desirability = s.prestige * (0.35 + state.star_rating/6) * (0.65 + 0.35*perf_score)
            desirability *= (0.75 + self.rng.random()*0.6)
            if state.star_rating < 3:
                desirability *= (1.25 - s.prestige*0.55)
            if state.star_rating >= 4.5:
                desirability *= 1.35
            weights.append(max(0.01, desirability))
        k = min(max(3, num + self.rng.randint(0,6)), len(self.fbs_catalog))
        choices = self.rng.choices(self.fbs_catalog, weights=weights, k=k)
        seen = set()
        for c in choices:
            if c.id in seen:
                continue
            seen.add(c.id)
            offers.append({"id": c.id, "team_name": c.name, "prestige": c.prestige, "location": c.location, "random_grade": round(self.rng.uniform(0.5,1.0),2)})
        state.college_offers = offers
        state.history.append(f"Generated {len(offers)} college offers (max prestige {max([o['prestige'] for o in offers]) if offers else 0:.2f}).")
        return offers

    def commit_to_college(self, state:CareerState, team_id:str):
        team = next((o for o in state.college_offers if o["id"]==team_id), None)
        if not team:
            raise ValueError("Offer not found")
        state.college_team = next((s for s in self.fbs_catalog if s.id==team_id), None)
        state.stage = "COLLEGE"
        state.calendar = {"phase":"COLLEGE", "year":1, "week":1}
        state.history.append(f"Committed to {team['team_name']}.")

    def simulate_college_year(self, state:CareerState, year:int)->Dict[str,Any]:
        if state.stage not in ("COLLEGE","NFL"):
            # auto-commit to best offer if not already
            if not state.college_offers:
                self.generate_college_offers(state)
            if state.college_offers and not state.college_team:
                best = max(state.college_offers, key=lambda o: o["prestige"])
                self.commit_to_college(state, best["id"])
        if state.stage == "NFL":
            return {}
        p = state.player
        scheme = state.college_team.scheme_bias if state.college_team else {"pass":0.5,"run":0.5}
        volatility = max(0.1, (6 - state.star_rating)/8)
        usage = 95 + int(self.rng.random()*55 * (1 + volatility*0.4))
        efficiency = (p.attributes.get("awareness",50)+p.attributes.get("speed",50))/16
        production = int(max(400, efficiency*usage*self.rng.uniform(0.65 - 0.15*volatility,1.15 + 0.2*volatility)))
        tds = int(max(3, production/140 * self.rng.uniform(0.85,1.25)))
        rating_before = self._overall(p)
        college_line = {"year":year, "rating":round(rating_before,1), "production_yards":production, "tds":tds}
        state.college_stats.append(college_line)
        state.history.append(f"College year {year}: rating {rating_before:.1f}, {production} yds, {tds} TDs")
        # possible awards
        if production > 1600 and self.rng.random()<0.35:
            state.awards.append({"level":"College","year":year,"name":"All-American"})
            state.history.append(f"College award: All-American (Y{year})")
        if production > 2000 and tds > 12 and self.rng.random()<0.2:
            state.awards.append({"level":"College","year":year,"name":"Heisman"})
            state.history.append(f"College award: Heisman (Y{year})")
        if production > 2200 and tds > 18 and self.rng.random()<0.15:
            state.awards.append({"level":"College","year":year,"name":"Maxwell"})
            state.history.append(f"College award: Maxwell (Y{year})")

        # development
        dev = 1.5 + p.hidden_potential*3 + volatility*0.9
        for k in ["speed","awareness","throw_power","route_running","break_tackle","strength"]:
            p.attributes[k] += self.rng.uniform(0.6, dev)
        # potential and overall nudged by performance
        pot_delta = (production/1400.0 - 1) * (0.06 + 0.03*volatility) + self.rng.uniform(-0.03*volatility,0.03*volatility)
        p.hidden_potential = max(0.1, min(1.0, p.hidden_potential + pot_delta))
        p.age += 1
        state.star_rating = min(5.0, state.star_rating + self.rng.uniform(0.0,0.2))
        state.calendar = {"phase":"COLLEGE", "year":year, "week":14}
        # record post progression
        college_line["rating_after"] = round(self._overall(p),1)
        state.history.append(f"College year {year} progression: {rating_before:.1f} -> {college_line['rating_after']:.1f}")

        # early draft declaration for high performers
        if rating_before > 84 and year >= 2 and self.rng.random() < 0.4:
            self.promote_to_nfl(state)
        elif year >= 3:
            self.promote_to_nfl(state)
        return college_line

    def _overall(self, player:Player)->float:
        keys = ["speed","strength","awareness","throw_power","route_running","break_tackle"]
        return statistics.mean([player.attributes.get(k,50) for k in keys])

    def promote_to_nfl(self, state:CareerState):
        rating = self._overall(state.player)
        draft_tier = "UDFA"
        if rating > 88:
            draft_tier = "Round 1"
        elif rating > 84:
            draft_tier = "Rounds 2-3"
        elif rating > 80:
            draft_tier = "Rounds 4-5"
        elif rating > 76:
            draft_tier = "Rounds 6-7"
        state.draft_projection = draft_tier
        possible = [f.city for f in build_nfl_franchises()]
        state.nfl_team = self.rng.choice(possible)
        state.stage = "NFL"
        state.calendar = {"phase":"NFL", "year": state.calendar.get("year",4)+1, "week":1}
        state.history.append(f"Draft outcome: {draft_tier}, landed with {state.nfl_team}.")

    def simulate_nfl_seasons(self, state:CareerState, seasons:int=3)->List[Dict[str,Any]]:
        """Lightweight NFL stat generator driven by player overall."""
        stats=[]
        base_rating = self._overall(state.player)
        declines = 0
        for yr in range(1, seasons+1):
            dev = 0.4 + state.player.hidden_potential*0.8
            base_rating += self.rng.uniform(-0.8, dev)
            usage = 450 + int(self.rng.random()*120)
            efficiency = 6.0 + (base_rating-70)/12 + self.rng.uniform(-0.6,0.8)
            pass_yards = max(1800, int(usage*efficiency))
            pass_tds = max(8, int(pass_yards/180 + self.rng.randint(-2,5)))
            ints = max(3, int(pass_tds/2.5 * (1.1 - state.player.attributes.get("awareness",50)/120)) + self.rng.randint(-2,3))
            rush_yards = max(50, int((state.player.attributes.get("speed",50)-40) * self.rng.uniform(4,10)))
            prev = stats[-1] if stats else None
            if prev and pass_yards < prev["pass_yards"] and pass_tds < prev["pass_tds"] and base_rating < prev["overall"]:
                declines += 1
            else:
                declines = 0
            statline = {
                "year": yr,
                "overall": round(base_rating,1),
                "pass_yards": pass_yards,
                "pass_tds": pass_tds,
                "ints": ints,
                "rush_yards": rush_yards
            }
            stats.append(statline)
            state.history.append(f"NFL year {yr}: Ovr {statline['overall']}, {pass_yards} pass yds, {pass_tds} TD, {ints} INT")
            if pass_yards > 4500 and pass_tds >= 25 and self.rng.random()<0.4:
                state.awards.append({"level":"NFL","year":yr,"name":"MVP"})
                state.history.append(f"NFL award: MVP (Y{yr})")
            if pass_yards > 3500 and self.rng.random()<0.5:
                state.awards.append({"level":"NFL","year":yr,"name":"Pro Bowl"})
                state.history.append(f"NFL award: Pro Bowl (Y{yr})")
            if (pass_yards > 4800 and pass_tds > 30 and self.rng.random()<0.25) or ((any(a for a in state.awards if a["level"]=="NFL" and a["year"]==yr and a["name"]=="MVP")) and self.rng.random()<0.5):
                state.awards.append({"level":"NFL","year":yr,"name":"All-Pro"})
                state.history.append(f"NFL award: All-Pro (Y{yr})")
            if pass_yards > 4000 and pass_tds > 20 and self.rng.random()<0.2:
                state.awards.append({"level":"NFL","year":yr,"name":"Super Bowl"})
                state.history.append(f"NFL award: Super Bowl Champion (Y{yr})")
            if yr >= 12 and declines >= 2 and self.rng.random() < 0.6:
                state.retired = True
                state.retired_year = yr
                state.history.append(f"Retired after year {yr} due to decline.")
                break
        return stats

# ---------------------------
# NFL Helpers
# ---------------------------
def build_nfl_franchises()->List[NflFranchise]:
    names = [
        ("BUF","Bills","Buffalo"),("MIA","Dolphins","Miami"),("NE","Patriots","New England"),("NYJ","Jets","New York"),
        ("BAL","Ravens","Baltimore"),("CIN","Bengals","Cincinnati"),("CLE","Browns","Cleveland"),("PIT","Steelers","Pittsburgh"),
        ("HOU","Texans","Houston"),("IND","Colts","Indianapolis"),("JAX","Jaguars","Jacksonville"),("TEN","Titans","Tennessee"),
        ("DEN","Broncos","Denver"),("KC","Chiefs","Kansas City"),("LV","Raiders","Las Vegas"),("LAC","Chargers","Los Angeles"),
        ("DAL","Cowboys","Dallas"),("NYG","Giants","New York"),("PHI","Eagles","Philadelphia"),("WAS","Commanders","Washington"),
        ("CHI","Bears","Chicago"),("DET","Lions","Detroit"),("GB","Packers","Green Bay"),("MIN","Vikings","Minnesota"),
        ("ATL","Falcons","Atlanta"),("CAR","Panthers","Carolina"),("NO","Saints","New Orleans"),("TB","Buccaneers","Tampa Bay"),
        ("ARI","Cardinals","Arizona"),("LA","Rams","Los Angeles"),("SF","49ers","San Francisco"),("SEA","Seahawks","Seattle")
    ]
    franchises=[]
    for idx,(abbr,name,city) in enumerate(names):
        prestige = max(0.4, 0.85 - idx*0.01)
        franchises.append(NflFranchise(id=abbr, name=name, city=city, prestige=prestige))
    return franchises


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

    def _mean(self, values, default=50):
        return statistics.mean(values) if values else default

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
        off_rating = team_rating(offense)
        def_rating = team_rating(defense)
        rating_diff = (off_rating - def_rating) / 50.0

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
            coverage = self._mean([p.attributes.get("awareness",50) for p in defense.roster if p.position in ("DB","LB")], default=50)
            # pressure factor from pass rush (DL)
            rush = self._mean([p.attributes.get("strength",50) for p in defense.roster if p.position in ("DL",)], default=50)
            pressure_prob = self._logistic((rush - qb.attributes.get("awareness",50))/20.0)
            pressure = self.rng.random() < pressure_prob

            # base prob
            prob = 0.40 + (qb_acc-50)/220 + (target_skill-50)/320 - (coverage-50)/210 + rating_diff*0.1
            if pressure:
                prob -= 0.10
            # clamp
            prob = max(0.03, min(0.95, prob))
            complete = self.rng.random() < prob

            # yards model
            depth = play_call.get("depth", 8 + int((target.attributes.get("speed",50)-50)/6)) # simple depth heuristic
            yac = 0
            if complete:
                yac = max(0, int((target.attributes.get("break_tackle",50)/55.0) * (self.rng.random()*8)))
                # yard gain is depth +/- variation + yac
                yard_variation = int((target_skill-50)/10) + self.rng.randint(-2,14)
                yards = max(0, depth + yard_variation + yac)
                td = yards >= 35 and self.rng.random() < 0.06 + (target.attributes.get("speed",50)-50)/220.0
                interception = False
            else:
                yards = 0
                td = False
                # chance interception on badly thrown passes
                int_volatility = 0.02 + (coverage-50)/400 + self.rng.uniform(0,0.07)
                qb_awareness = qb.attributes.get("awareness",50)
                int_volatility += max(0, (55 - qb_awareness)/200)
                interception = (self.rng.random() < int_volatility) or (self.rng.random() < 0.03 and prob < 0.15)

            # injuries chance from collisions on receptions or tackles
            injury = None
            if complete and self.rng.random() < 0.005:
                injury = self._sample_injury()

            ev["result"] = {"complete": complete, "yards": yards, "td": bool(td), "interception": bool(interception), "pressure": pressure, "yac": yac, "injury": injury}
            return ev

        elif play_type == "run":
            runner = off_player
            run_skill = runner.attributes.get("break_tackle",50)*0.6 + runner.attributes.get("speed",50)*0.4
            line_strength = self._mean([p.attributes.get("strength",50) for p in offense.roster if p.position in ("OL",)], default=50)
            def_front = self._mean([p.attributes.get("strength",50) for p in defense.roster if p.position in ("DL","LB")], default=50)
            base = max(0, int((run_skill - def_front)/10) + int(line_strength/50) + self.rng.randint(-1,10) + int(rating_diff*5))
            yards = max(0, base + self.rng.randint(0,10))
            td = yards >= 60 and self.rng.random() < 0.08 + max(0, rating_diff*0.07)
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
        game_record = {
            "game_id":game_id,
            "home_id":home.id,
            "home_name":home.name,
            "away_id":away.id,
            "away_name":away.name,
            "plays":[],
            "score":{"home":0,"away":0}
        }
        # seed-specific rng for this game determinism
        for quarter in range(1,5):
            drives_per_quarter = 3
            for d in range(drives_per_quarter):
                # choose offense
                offense = home if ((d + quarter) % 2 == 0) else away
                defense = away if offense is home else home
                rating_diff = (team_rating(offense) - team_rating(defense)) / 50.0
                # simple drive: choose a sequence of plays
                plays_in_drive = self.rng.randint(4,10)
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
                            # touchdown worth 7
                            drive_score += 7
                    else:
                        drive_yards += int(outcome.get("yards",0))
                        if outcome.get("td"):
                            drive_score += 7
                    # injury apply
                    if outcome.get("injury"):
                        primary.injuries.append({"injury":outcome.get("injury"), "when":datetime.datetime.utcnow().isoformat()})
                        primary.career_events.append({"type":"injury","injury":outcome.get("injury"), "game_id":game_id})
                # end drive - possible field goal or touchdown
                # simple scoring chance
                # redzone conversion if enough yards accumulated but no td/fg yet
                if drive_score==0 and drive_yards >= 65 and self.rng.random() < 0.55 + rating_diff*0.05:
                    drive_score = 7
                elif drive_score==0 and drive_yards >= 45 and self.rng.random() < 0.30 + rating_diff*0.04:
                    drive_score = 3

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
                    # maybe settle for a FG with reasonable chance but based on yards
                    if drive_yards > 35 and self.rng.random() < 0.7:
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
    franchises = build_nfl_franchises()
    teams = [build_sample_team(f.name, f.city, seed_offset=i+1) for i,f in enumerate(franchises)]

    all_game_events=[]
    games=[]
    # divisions of 4 teams each
    divisions = [teams[i:i+4] for i in range(0, len(teams), 4)]
    week = 1
    for div in divisions:
        idxs = list(range(len(div)))
        for h in idxs:
            for a in idxs:
                if h == a:
                    continue
                home = div[h]
                away = div[a]
                gr = gs.simulate_game(home, away)
                gr["week"] = week
                gr["division_game"] = True
                games.append(gr)
                all_game_events.extend(gs.log.dump())
                gs.log = EventLog()
                week += 1

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
    for div_idx, div in enumerate(divisions):
        print(f"Division {div_idx+1}:")
        for t in div:
            print(f"  {t.city} {t.name} - W:{t.season_stats['wins']} L:{t.season_stats['losses']} PF:{t.season_stats['points_for']} PA:{t.season_stats['points_against']} Coach:{t.coach_quality:.2f}")

    print("\nTop Candidates (MVP):")
    for m in mvps:
        print(f"{m['player_name']} - Score: {m['score']} Impact:{m['impact']} Justification: {m['justification']}")
    print("\nTotal plays logged:", len(all_game_events))
    return {"teams":teams, "games":games, "events":all_game_events, "agg":agg, "mvps":mvps}

def run_career_demo()->CareerState:
    """
    Quick HS -> College -> NFL path to show the CareerEngine loop.
    """
    rng = seeded_rand(101)
    eng = CareerEngine(rng)
    state = eng.create_prospect("Alex", "Game", pos="QB", stars=2)
    for y in range(4):
        eng.simulate_high_school_year(state, year=y+1)
    eng.generate_college_offers(state)
    if state.college_offers:
        # pick the best prestige offer to mimic blue-blood pull
        top = max(state.college_offers, key=lambda o: o["prestige"])
        eng.commit_to_college(state, top["id"])
    for y in range(4):
        eng.simulate_college_year(state, year=y+1)
        if state.stage == "NFL":
            break
    if state.stage != "NFL":
        eng.promote_to_nfl(state)
    # simulate some NFL seasons for the career summary
    state.nfl_stats = eng.simulate_nfl_seasons(state, seasons=20)

    print("\n=== Career Demo ===")
    print(f"{state.player.name} ({state.player.position}) final stars: {state.star_rating:.2f}")
    print(f"College: {state.college_team.name if state.college_team else 'None'} · Draft: {state.draft_projection} -> {state.nfl_team}")
    if state.retired:
        print(f"Retired after NFL year {state.retired_year}.")
    print("Career beats:")
    for h in state.history:
        print(" -", h)
    # quick totals summary
    total_hs_yds = sum(s.get("production_yards",0) for s in state.hs_stats)
    total_cfb_yds = sum(s.get("production_yards",0) for s in state.college_stats)
    total_nfl_pass = sum(s.get("pass_yards",0) for s in getattr(state, "nfl_stats", []))
    print(f"Career totals: HS {total_hs_yds} yds · College {total_cfb_yds} yds · NFL {total_nfl_pass} pass yds · Awards {len(state.awards)}")
    return state

def simulate_nfl_season_with_playoffs(num_weeks:int=17):
    """
    Build all NFL teams, simulate a 17-week season (random pairings each week),
    compute standings, then run a simple 8-team playoff bracket to a Super Bowl champion.
    """
    rng = seeded_rand(202)
    gs = GameSimulator(rng)
    franchises = build_nfl_franchises()
    teams = [build_sample_team(fr.name, fr.city, seed_offset=300+idx) for idx,fr in enumerate(franchises)]
    games=[]
    all_events=[]

    # Regular season schedule: weekly shuffle/pair
    for week in range(1, num_weeks+1):
        rng.shuffle(teams)
        for i in range(0, len(teams), 2):
            if i+1 >= len(teams):
                continue
            home = teams[i]
            away = teams[i+1]
            gr = gs.simulate_game(home, away)
            gr["week"] = week
            games.append(gr)
        all_events.extend(gs.log.dump())
        gs.log = EventLog()

    # standings already in season_stats
    standings = sorted(teams, key=lambda t: (t.season_stats["wins"], t.season_stats["points_for"]-t.season_stats["points_against"]), reverse=True)

    # Playoffs: top 8 overall seeds single-elimination
    seeds = standings[:8]
    bracket = []
    current_round = seeds
    round_num = 1
    while len(current_round) > 1:
        next_round = []
        for i in range(0, len(current_round), 2):
            if i+1 >= len(current_round):
                continue
            home = current_round[i]
            away = current_round[i+1]
            gr = gs.simulate_game(home, away)
            gr["round"] = round_num
            bracket.append({
                "round": round_num,
                "home": home.name,
                "away": away.name,
                "score": gr["score"],
                "winner": home.name if gr["score"]["home"] >= gr["score"]["away"] else away.name
            })
            winner = home if gr["score"]["home"] >= gr["score"]["away"] else away
            next_round.append(winner)
            all_events.extend(gs.log.dump())
            gs.log = EventLog()
        current_round = next_round
        round_num += 1
    champion = current_round[0].name if current_round else None

    # Aggregate stats and league MVP (regular season events)
    aggregator = StatAggregator(all_events)
    agg = aggregator.aggregate()
    plook = {p.id:p for t in teams for p in t.roster}
    award = AwardEngine(plook, agg)
    mvps = award.compute_mvp(top_n=3)

    print(f"\nNFL season simulated: {len(games)} games, champion: {champion}")
    return {
        "teams": teams,
        "games": games,
        "standings": standings,
        "playoffs": bracket,
        "champion": champion,
        "mvps": mvps,
        "events": all_events
    }

# ---------------------------
# Run when executed
# ---------------------------
if __name__ == "__main__":
    out = simulate_league(season_len=17)
    career_state = run_career_demo()
    nfl_full = simulate_nfl_season_with_playoffs(num_weeks=17)
    # print NFL season summary
    print("\n=== NFL Season (Full) ===")
    print(f"Champion: {nfl_full['champion']}")
    print("Top 5 Standings:")
    for t in nfl_full["standings"][:5]:
        print(f" - {t.city} {t.name}: {t.season_stats['wins']}-{t.season_stats['losses']} PF:{t.season_stats['points_for']} PA:{t.season_stats['points_against']}")
    print("Playoffs (round by round):")
    for game in nfl_full["playoffs"]:
        print(f"  Round {game['round']}: {game['home']} {game['score']['home']} vs {game['away']} {game['score']['away']} -> {game['winner']}")
    print("Regular-season MVPs:")
    for m in nfl_full["mvps"]:
        print(f" - {m['player_name']} Score:{m['score']} Impact:{m['impact']} Justification:{m['justification']}")
    # career totals summary
    total_hs_yds = sum(s.get("production_yards",0) for s in career_state.hs_stats)
    total_hs_tds = sum(s.get("tds",0) for s in career_state.hs_stats)
    total_cfb_yds = sum(s.get("production_yards",0) for s in career_state.college_stats)
    total_cfb_tds = sum(s.get("tds",0) for s in career_state.college_stats)
    total_nfl_pass = sum(s.get("pass_yards",0) for s in getattr(career_state, "nfl_stats", []))
    total_nfl_tds = sum(s.get("pass_tds",0) for s in getattr(career_state, "nfl_stats", []))
    total_nfl_ints = sum(s.get("ints",0) for s in getattr(career_state, "nfl_stats", []))
    awards_count = len(career_state.awards)
    awards_by_level = {"HS": [], "College": [], "NFL": []}
    awards_breakdown = {
        "super_bowl": 0,
        "mvp": 0,
        "pro_bowl": 0,
        "all_pro": 0,
        "heisman": 0,
        "all_american": 0,
        "maxwell": 0
    }
    for a in career_state.awards:
        lvl = a.get("level","").title()
        if lvl.upper() == "HS":
            awards_by_level["HS"].append(a)
        elif lvl.upper() == "COLLEGE":
            awards_by_level["College"].append(a)
        else:
            awards_by_level["NFL"].append(a)
        name = a.get("name","").lower()
        if "super bowl" in name:
            awards_breakdown["super_bowl"] += 1
        if "mvp" in name:
            awards_breakdown["mvp"] += 1
        if "pro bowl" in name:
            awards_breakdown["pro_bowl"] += 1
        if "all-pro" in name or "all pro" in name:
            awards_breakdown["all_pro"] += 1
        if "heisman" in name:
            awards_breakdown["heisman"] += 1
        if "all-american" in name:
            awards_breakdown["all_american"] += 1
        if "maxwell" in name:
            awards_breakdown["maxwell"] += 1
    # append breakdown to history for visibility and print
    breakdown_line = (
        f"Awards summary — SB:{awards_breakdown['super_bowl']} MVP:{awards_breakdown['mvp']} "
        f"ProBowls:{awards_breakdown['pro_bowl']} All-Pro:{awards_breakdown['all_pro']} "
        f"Heisman:{awards_breakdown['heisman']} All-American:{awards_breakdown['all_american']} Maxwell:{awards_breakdown['maxwell']}"
    )
    career_state.history.append(breakdown_line)
    print(" - " + breakdown_line)

    # optionally save outputs for further inspection
    with open("sim_output.json","w") as f:
        json.dump({
            "mvps": out["mvps"],
            "teams": [{ "id":t.id, "name":t.name, "city":t.city, "season_stats": t.season_stats} for t in out["teams"]],
            "event_count": len(out["events"]),
            "career_summary": {
                "player": career_state.player.name,
                "position": career_state.player.position,
                "stars": career_state.star_rating,
                "college": career_state.college_team.name if career_state.college_team else None,
                "draft_projection": career_state.draft_projection,
                "nfl_team": career_state.nfl_team,
                "hs_stats": career_state.hs_stats,
                "college_stats": getattr(career_state, "college_stats", []),
                "offers": career_state.college_offers,
                "nfl_stats": getattr(career_state, "nfl_stats", []),
                "awards": awards_by_level,
                "retired": career_state.retired,
                "retired_year": career_state.retired_year,
                "totals": {
                    "hs_yards": total_hs_yds,
                    "hs_tds": total_hs_tds,
                    "college_yards": total_cfb_yds,
                    "college_tds": total_cfb_tds,
                    "nfl_pass_yards": total_nfl_pass,
                    "nfl_pass_tds": total_nfl_tds,
                    "nfl_ints": total_nfl_ints,
                    "awards_count": awards_count,
                    "awards_breakdown": awards_breakdown
                },
                "history": career_state.history
            },
            "nfl_season": {
                "champion": nfl_full["champion"],
                "mvps": nfl_full["mvps"],
                "playoffs": nfl_full["playoffs"],
                "standings": [
                    {"team": t.name, "city": t.city, "wins": t.season_stats["wins"], "losses": t.season_stats["losses"], "pf": t.season_stats["points_for"], "pa": t.season_stats["points_against"]}
                    for t in nfl_full["standings"]
                ],
                "games": [{"week": g.get("week","?"), "home": g["home_name"], "away": g["away_name"], "score": g["score"]} for g in nfl_full["games"]]
            }
        }, f, indent=2)
    print("\nSim output written to sim_output.json")
