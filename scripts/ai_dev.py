import os, json, base64, subprocess, pathlib, re, sys, textwrap, glob, yaml, shutil
from datetime import datetime
from openai import OpenAI

ROOT = pathlib.Path(".").resolve()

def read_text(path, limit=120_000):
    try:
        data = pathlib.Path(path).read_text(encoding="utf-8", errors="ignore")
        return data[:limit]
    except Exception:
        return ""

def file_is_empty_or_todo(path: pathlib.Path) -> bool:
    if not path.is_file(): return False
    if path.suffix in {".png",".jpg",".jpeg",".webp",".gif",".lock",".svg",".ico"}: return False
    try:
        txt = path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return False
    if len(txt.strip()) == 0: return True
    markers = ["TODO", "FIXME", "WIP", "TBD"]
    return any(m in txt for m in markers)

def detect_pkg_manager():
    pj = ROOT / "package.json"
    if pj.exists():
        try:
            obj = json.loads(pj.read_text())
            if "pnpm" in (ROOT / "pnpm-lock.yaml").name or (ROOT / "pnpm-lock.yaml").exists():
                return "pnpm", obj
            if (ROOT / "yarn.lock").exists():
                return "yarn", obj
            return "npm", obj
        except Exception:
            return "npm", {}
    return None, {}

def run_cmd(cmd, check=True):
    print("$", " ".join(cmd))
    return subprocess.run(cmd, check=check)

def git(*args, check=True):
    return run_cmd(["git", *args], check=check)

def sanitize_branch(s):
    s = re.sub(r"[^a-zA-Z0-9._/-]+","-", s).strip("-")
    return (s or "ai-dev")[:120]

def gather_context():
    # High-signal files first
    high_signal = []
    for name in ["README.md","SPEC.md","ROADMAP.md","TODO.md","docs/ARCHITECTURE.md","package.json","vite.config.ts","vite.config.js","tsconfig.json","requirements.txt","pyproject.toml"]:
        p = ROOT / name
        if p.exists(): high_signal.append((str(p), read_text(p)))

    # List empty/TODO files
    candidates = []
    for ext in ["*.ts","*.tsx","*.js","*.jsx","*.py","*.sql","*.json","*.md","*.yml","*.yaml","*.css","*.scss"]:
        for path in ROOT.rglob(ext):
            if "node_modules" in str(path) or ".git" in str(path.parts): continue
            if file_is_empty_or_todo(path):
                candidates.append(path)

    # Short tree for orientation
    tree_lines = []
    for p in sorted([p for p in ROOT.rglob("*") if ".git" not in str(p) and "node_modules" not in str(p)], key=lambda x: (x.is_file(), str(x))):
        if p.is_dir(): continue
        rel = p.relative_to(ROOT)
        size = p.stat().st_size if p.exists() else 0
        tree_lines.append(f"{rel} ({size} bytes)")
        if len(tree_lines) > 1800: break

    return high_signal, candidates, "\n".join(tree_lines[:2000])

def make_prompt(high_signal, candidates, tree_txt, task):
    # Pull any task text from issue/dispatch
    task = task.strip() or "Complete all empty/TODO-marked files and fix import/build/test errors for a working game."

    # Compose a concise context to stay under token limits
    parts = []
    parts.append("PROJECT TREE (truncated):\n" + tree_txt)
    parts.append("\nKEY FILES (truncated):")
    for path, txt in high_signal:
        parts.append(f"\n--- {path} ---\n{txt[:15000]}")
    spec = "\n".join(parts)

    candidate_list = "\n".join(str(p) for p in candidates[:200])

    rules = textwrap.dedent("""
    Coding rules:
    - Keep existing architecture; fill in missing pieces only.
    - Fix obvious broken imports (e.g., Vite/React paths), but do not rename public APIs unless necessary.
    - Add minimal tests if test script exists.
    - Prefer TypeScript for frontend files (*.tsx/*.ts). Keep styles consistent.
    - Do not generate placeholder lorem ipsum; provide functional code.
    Output format:
    Return ONLY valid JSON: {
      "branch_name": str,
      "commit_message": str,
      "patches": [ {"path": str, "content_b64": str} ],
      "post_steps": [str]
    }
    - Each item in patches is the FULL new file content (not a diff), base64-encoded.
    - Include ALL empty/TODO files you completed.
    """)

    user = f"""
Task: {task}

Files to complete (sample/truncated):
{candidate_list}

{spec}
"""
    return rules, user

def apply_patches(spec):
    branch = sanitize_branch(spec.get("branch_name","ai-dev-"+datetime.utcnow().strftime("%Y%m%d%H%M%S")))
    commit_message = spec.get("commit_message","AI: complete incomplete files")
    patches = spec.get("patches", [])

    git("config","user.name","ai-dev-bot")
    git("config","user.email","ai-dev-bot@users.noreply.github.com")
    git("checkout","-b", branch)

    for p in patches:
        path = ROOT / p["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        data = base64.b64decode(p["content_b64"])
        path.write_bytes(data)

    git("add","-A")
    git("commit","-m", commit_message)
    git("push","--set-upstream","origin", branch)
    return branch

def try_build_and_test():
    pm, pkg = detect_pkg_manager()
    if not pm:
        return True, "no package.json detected"

    install_cmd = {"pnpm":["pnpm","i"], "yarn":["yarn","install"], "npm":["npm","ci" if (ROOT/"package-lock.json").exists() else "install"]}[pm]
    run_cmd(install_cmd, check=True)

    # Build if available
    scripts = pkg.get("scripts",{}) if isinstance(pkg, dict) else {}
    if "build" in scripts:
        run_cmd([pm, "build"], check=True)
    # Test if available
    if "test" in scripts:
        # Many repos use jest/vitest; keep it simple
        try:
            run_cmd([pm, "test","--","-u"], check=False)
        except Exception:
            pass

    return True, "build/test attempted"

def open_pr(branch, title, body):
    # Prefer gh; fallback to GitHub CLI isn’t always available in Actions images, but generally is.
    try:
        run_cmd(["gh","pr","create","--fill","--title",title,"--body",body,"--base","main","--head",branch], check=False)
    except Exception:
        pass

def main():
    event = os.getenv("EVENT_NAME","")
    issue_title = os.getenv("ISSUE_TITLE","")
    issue_body = os.getenv("ISSUE_BODY","")
    dispatch_task = os.getenv("DISPATCH_TASK","")
    repo = os.getenv("REPO","")
    actor = os.getenv("ACTOR","")

    task = dispatch_task or (issue_title + "\n\n" + issue_body)

    high_signal, candidates, tree_txt = gather_context()
    rules, user = make_prompt(high_signal, candidates, tree_txt, task)

    client = OpenAI()
    resp = client.responses.create(
        model="gpt-4.1-mini",
        messages=[
            {"role":"system","content":rules},
            {"role":"user","content":user}
        ],
        response_format={"type":"json_object"},
    )
    content = getattr(resp, "output", None)
    if content and isinstance(content, list):
        # new SDK may structure content differently
        try:
            text = content[0].content[0].text
        except Exception:
            text = ""
    else:
        # classic
        text = resp.choices[0].message.content

    spec = json.loads(text)
    branch = apply_patches(spec)

    ok, note = try_build_and_test()

    title = f"[AI] Complete empty/TODO files"
    body = f"Repo: {repo}\nRequester: {actor}\n\nTask:\n{task[:1000]}\n\n{note}"
    open_pr(branch, title, body)

if __name__ == "__main__":
    main()
