# The Saga of 406 — live dashboard

A self-updating web dashboard for the **406 Server** (ARK: Survival Ascended, Ragnarok).
It shows who's online, a **Wall of Shame** (deaths), a tame **Menagerie**, and a **Chronicle**
of deeds — all pulled automatically from the server. No one ever types anything in.

## How it works (three pieces)
1. **Collector** (`collector/collect.ps1`) runs on the **server PC** every few minutes via Task
   Scheduler. It talks to the ARK server over **RCON**, extracts live data, and writes `data.json`.
2. **Publish** — the collector `git push`es the updated `data.json` to this repo.
3. **Dashboard** (`index.html`) is served by **GitHub Pages**. It fetches `data.json` and renders it,
   auto-refreshing every ~90 seconds. It's read-only.

```
Browser ── fetch ──► GitHub Pages (index.html + data.json)
                              ▲
                              │ git push (every few min)
   ARK server ◄── RCON ── collect.ps1  (on the server PC)
```

---

## One-time setup

### 0. Prerequisites on the server PC
- **Git for Windows** installed (`git --version` should work).
- The ARK server launched with `-servergamelog -ServerRCONOutputTribeLogs` (already added to
  `start_server.bat` / `run_406_server.bat` in `C:\ArkServer`) and **RCON enabled** on 27020
  (already set in `GameUserSettings.ini`).

### 1. The repo already exists
`https://github.com/cgbeaulieu/ark-406-dashboard.git` (private).

### 2. Push this folder up
On the server PC, in `C:\ArkDashboard` (the local git repo is already initialized and committed):
```powershell
git branch -M main
git remote add origin https://github.com/cgbeaulieu/ark-406-dashboard.git
git push -u origin main
```

### 3. Give the collector permission to push (token stays on this PC only)
- GitHub → Settings → Developer settings → **Fine-grained personal access token**.
- Repository access: **Only select repositories** → `ark-406-dashboard`.
- Permissions: **Contents → Read and write**. Generate; copy the token.
- Store it in the local remote URL (this lives only in `.git/config`, never committed):
```powershell
git remote set-url origin https://cgbeaulieu:PASTE_TOKEN_HERE@github.com/cgbeaulieu/ark-406-dashboard.git
```

### 4. Turn on GitHub Pages
- Repo → Settings → **Pages** → Source: **Deploy from a branch** → Branch: **main** / **/(root)** → Save.
- After a minute your site is live at `https://cgbeaulieu.github.io/ark-406-dashboard/`.
- It's **unlisted** — only people you send the link to will find it (the page also sets `noindex`).

### 5. Configure the collector
```powershell
Copy-Item collector\config.example.ps1 collector\config.ps1
notepad collector\config.ps1     # set RconPassword; set  Push = $true
```

### 6. Test it once (server should be running)
```powershell
powershell -ExecutionPolicy Bypass -File collector\collect.ps1 -NoPush   # writes data.json locally
powershell -ExecutionPolicy Bypass -File collector\collect.ps1           # writes + pushes
```
Open your Pages URL — you should see live data. (Tip: `-Offline` writes sample data with no server.)

### 7. Schedule it every 10 minutes
```powershell
schtasks /Create /TN "406 Dashboard Collector" /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\ArkDashboard\collector\collect.ps1" /SC MINUTE /MO 10 /F
```
> GitHub Pages has a soft limit of ~10 builds/hour, so 10-minute spacing keeps you safely under it.

---

## Files
| Path | What it is |
|------|-----------|
| `index.html` | The dashboard (served by Pages). |
| `data.json` | Live data, overwritten by the collector each run. |
| `collector/collect.ps1` | The collector (RCON → parse → data.json → push). |
| `collector/config.example.ps1` | Template; copy to `config.ps1` (gitignored, holds your RCON password). |
| `collector/state.json` | Accumulated history + dedupe (gitignored, auto-created). |
| `collector/unparsed.log` | Tribe-log lines the parser didn't recognize — used to refine regexes. |

## Known caveat — needs one live run to finalize
Online players and server status are rock-solid. The **death/tame parsing** reads ARK's tribe log,
whose exact wording I couldn't test against a live server yet. On the first real run, check
`collector/unparsed.log`: any death/tame lines that landed there mean a regex in `collect.ps1`
(`Parse-GameLog`) needs a small tweak to match your server's exact phrasing. Send me a few sample
lines and I'll finalize it.
