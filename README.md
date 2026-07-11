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

> ⚠️ **Always give the task the _absolute_ path to `collect.ps1`** (as above), or set its **"Start in"**
> to `C:\ArkDashboard`. Task Scheduler runs actions from `C:\Windows\System32` by default, so a
> **relative** path like `-File collector\collect.ps1` with no "Start in" silently fails **every**
> run — the task shows `Last Result: 0xFFFD0000` and nothing updates. See Troubleshooting below.

---

## Files
| Path | What it is |
|------|-----------|
| `index.html` | The dashboard (served by Pages). |
| `data.json` | Live data, overwritten by the collector each run. |
| `collector/collect.ps1` | The collector (RCON → parse → data.json → push). |
| `collector/config.example.ps1` | Template; copy to `config.ps1` (gitignored, holds your RCON password). |
| `collector/install-collector-task.ps1` | One-click: registers the every-10-min scheduled task. |
| `collector/state.json` | Accumulated history + dedupe (gitignored, auto-created). |
| `collector/unparsed.log` | Any tribe-log lines the parser didn't recognize (gitignored). Should stay empty. |

## Parsing (tuned against the live server)
`Parse-GameLog` in `collect.ps1` is tuned to the real ASA tribe-log format, e.g.:
- `Soop - Lvl 16 (Tiggles) was killed by a Dimorphodon - Lvl 50 ()!` → death: **Soop** ← *a Dimorphodon*
- `Soop of Tribe Tiggles Tamed a Pteranodon - Lvl 84 (Pteranodon)!` → tame: **Soop** — Pteranodon (Lvl 84)

It correctly ignores tamed-dino deaths (two paren groups = the dino, not a person), strips `of Tribe X`
from tamers, and skips rafts / tribe-level baby births.

**Maintenance helpers:**
- `collect.ps1 -TestLog <file>` — parse a saved GetGameLog dump and print the deaths/tames it finds (no server needed). Great for tuning new formats.
- `collect.ps1 -Rebuild` — re-parse the remembered history in `state.json` (and retry `unparsed.log`) with the current parser, fixing any older mis-parsed entries in place.

If a new kind of line ever shows up in `unparsed.log`, paste it in and the regexes get a quick tweak.

---

## Troubleshooting

### Dashboard isn't refreshing — the scheduled task "runs but does nothing"
Symptom: the site's "synced Xm ago" keeps growing; new deaths/tames never appear. The task looks
like it's firing on schedule, but check its **Last Result**:

```powershell
Get-ScheduledTaskInfo -TaskName "Ark Server Dashboard json Push" | Select LastRunTime, LastTaskResult
```

- **`LastTaskResult` is `0`** → the collector ran fine; there was just nothing new (or no players on).
- **`LastTaskResult` is `0xFFFD0000` (-196608)** → the task can't find `collect.ps1`. This happens when
  the task's action uses a **relative** script path and has no **"Start in"** directory, so it launches
  from `C:\Windows\System32`. Fix the action to use the absolute path (no admin password needed — this
  edits the action in place and leaves the run-as identity alone, so it works even if you only know
  your PIN):

  ```powershell
  # Run in an ELEVATED PowerShell (Run as administrator)
  $action = New-ScheduledTaskAction -Execute "powershell" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\ArkDashboard\collector\collect.ps1" `
    -WorkingDirectory "C:\ArkDashboard"
  Set-ScheduledTask -TaskName "Ark Server Dashboard json Push" -Action $action
  ```

  > Use `Set-ScheduledTask` (PowerShell), **not** `schtasks /Change` — the latter tries to re-store the
  > account's run-as password and prompts for it, which fails if you sign in with a Windows Hello PIN.

  Then confirm it works end to end:

  ```powershell
  Start-ScheduledTask -TaskName "Ark Server Dashboard json Push"; Start-Sleep 20
  (Get-ScheduledTaskInfo -TaskName "Ark Server Dashboard json Push").LastTaskResult   # want 0
  git -C C:\ArkDashboard log -1 --oneline                                             # want a fresh "data ..." commit
  ```

> **Note on the task name:** the bundled `install-collector-task.ps1` registers the task as
> **`406 Dashboard Collector`**. If your box already has a hand-made task under a different name
> (this server's is **`Ark Server Dashboard json Push`**), just fix that one — don't run the installer
> too, or you'll end up with two tasks fighting over the same push.

### Dashboard shows "Signal Lost" / "Server Online" but nobody listed
- **Signal Lost** = the collector couldn't reach RCON. Confirm the server is up and port `27020` is
  listening (`Get-NetTCPConnection -LocalPort 27020 -State Listen`), and that `RconPassword` in
  `config.ps1` matches `GameUserSettings.ini`.
- **Server Online + "nobody jacked in"** is *not* an error — it just means RCON replied
  `No Players Connected`. Names appear as soon as someone logs into the world.
