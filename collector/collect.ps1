<#
============================================================
  406 Dashboard collector
  Runs on the SERVER PC (Task Scheduler, every few minutes).
  Talks to the ARK server over RCON, extracts live data, and
  writes ..\data.json (which the static dashboard fetches).
============================================================
#>
param(
  [switch]$Offline,
  [switch]$NoPush,
  [string]$TestLog,   # parse a saved GetGameLog text file and print results (for tuning)
  [switch]$Rebuild    # re-parse accumulated state.seen[] with the current parser (fixes old data)
)
$ErrorActionPreference = "Stop"
$Root      = Split-Path -Parent $PSScriptRoot          # repo root
$DataFile  = Join-Path $Root "data.json"
$StateFile = Join-Path $PSScriptRoot "state.json"
$Unparsed  = Join-Path $PSScriptRoot "unparsed.log"

# ---------------- config ----------------
$cfgPath = Join-Path $PSScriptRoot "config.ps1"
if (Test-Path $cfgPath) { . $cfgPath }
elseif (-not $Offline -and -not $TestLog) {
  # No config yet - exit cleanly so a scheduled task never shows as "failed".
  Write-Host "collector\config.ps1 not found yet - nothing to do. (Copy config.example.ps1 to config.ps1 to start collecting.)"
  exit 0
}
if (-not $Config) { $Config = @{ ServerName="406 Server"; Map="Ragnarok"; Mode="PvE Co-op"; Push=$false } }

# ---------------- state (accumulated history) ----------------
function Load-State {
  if (Test-Path $StateFile) { return Get-Content $StateFile -Raw | ConvertFrom-Json }
  return [pscustomobject]@{ deaths=@(); tames=@(); events=@(); seen=@() }
}
function Save-State($s) { $s | ConvertTo-Json -Depth 8 | Set-Content $StateFile -Encoding utf8 }
function AsList($x) { $l = New-Object System.Collections.ArrayList; if ($x) { foreach ($i in $x) { [void]$l.Add($i) } }; return ,$l }

# ================= Source RCON =================
function Write-RconPacket($stream, [int]$id, [int]$type, [string]$body) {
  $bodyBytes = [Text.Encoding]::ASCII.GetBytes($body)
  $len = 4 + 4 + $bodyBytes.Length + 2
  $ms = New-Object IO.MemoryStream
  $bw = New-Object IO.BinaryWriter($ms)
  $bw.Write([int32]$len); $bw.Write([int32]$id); $bw.Write([int32]$type)
  $bw.Write($bodyBytes); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Flush()
  $arr = $ms.ToArray(); $stream.Write($arr, 0, $arr.Length); $stream.Flush()
}
function Read-Exact($stream, [int]$count) {
  $buf = New-Object byte[] $count; $off = 0
  while ($off -lt $count) {
    $r = $stream.Read($buf, $off, $count - $off)
    if ($r -le 0) { throw "RCON connection closed" }
    $off += $r
  }
  return $buf
}
function Read-RconPacket($stream) {
  $lenBytes = Read-Exact $stream 4
  $len = [BitConverter]::ToInt32($lenBytes, 0)
  $payload = Read-Exact $stream $len
  $id   = [BitConverter]::ToInt32($payload, 0)
  $type = [BitConverter]::ToInt32($payload, 4)
  $body = [Text.Encoding]::ASCII.GetString($payload, 8, $len - 8 - 2)
  return [pscustomobject]@{ id=$id; type=$type; body=$body }
}
function Invoke-Rcon([string]$rhost, [int]$port, [string]$pass, [string]$command) {
  $client = New-Object Net.Sockets.TcpClient
  try {
    $client.Connect($rhost, $port)
    $stream = $client.GetStream(); $stream.ReadTimeout = 4000
    Write-RconPacket $stream 1 3 $pass
    $ok = $false
    for ($i=0; $i -lt 3; $i++) {
      $p = Read-RconPacket $stream
      if ($p.type -eq 2) { if ($p.id -eq -1) { throw "RCON auth failed (bad password)" } $ok=$true; break }
    }
    if (-not $ok) { throw "RCON auth: no auth response" }
    Write-RconPacket $stream 2 2 $command
    Start-Sleep -Milliseconds 150
    $sb = New-Object Text.StringBuilder
    while ($true) {
      try { $p = Read-RconPacket $stream } catch { break }
      [void]$sb.Append($p.body)
      if (-not $stream.DataAvailable) { Start-Sleep -Milliseconds 120; if (-not $stream.DataAvailable) { break } }
    }
    return $sb.ToString()
  } finally { $client.Close() }
}

# ================= parsing =================
function Parse-Players([string]$text) {
  $names = @()
  foreach ($line in ($text -split "`n")) {
    $m = [regex]::Match($line.Trim(), '^\d+\.\s+(.+?),\s*[0-9a-fA-F]+\s*$')
    if ($m.Success) { $names += $m.Groups[1].Value.Trim() }
  }
  return ,$names
}

function Strip-Rich([string]$s) {
  $s = [regex]::Replace($s, '<RichColor[^>]*>', '')
  $s = $s -replace '</>', ''
  return $s.Trim()
}

# Returns @{ deaths=@(...); tames=@(...) } parsed from a GetGameLog dump.
function Parse-GameLog([string]$text, $state) {
  $result = @{ deaths=@(); tames=@() }
  foreach ($raw in ($text -split "`n")) {
    $line = Strip-Rich $raw
    if (-not $line) { continue }
    
    # 1. Strip the server timestamp prefix aggressively
    $line = [regex]::Replace($line, '^[\d\._\s\-]+:\s*', '').Trim()
    
    $key = ($line -replace '\s+', ' ').Trim()
    if ($state.seen -contains $key) { continue }         # dedupe against history
    $matched = $false

    # A tamed creature's death carries TWO paren groups "(Species) (Tribe)" before
    # "was killed" (e.g. "Dodo - Lvl 93 (Dodo) (Tiggles) was killed..."). Skip those -
    # the Wall of Shame is for people dying, not their dinos.
    if ($line -match '\([^)]*\)\s+\([^)]*\)\s+was killed') { $matched = $true }

    # DEATH by a killer:  "<Player> - Lvl N (Tribe) was killed by <killer> - Lvl M ()!"
    if (-not $matched -and $line -match '^(.+?)\s+-\s+Lvl\s+\d+\s*\([^)]*\)\s+was killed by\s+(.+?)!') {
      $who    = $Matches[1].Trim()
      $killer = [regex]::Replace($Matches[2].Trim(), '\s*-\s+Lvl\s+\d+\s*\([^)]*\)\s*$', '').Trim()
      if ($who -notmatch "'") {
        $result.deaths += @{ id=[guid]::NewGuid().ToString('n').Substring(0,10); who=$who; cause="Slain in the wild"; killer=$killer; ts=(Get-Date).ToString('o') }
      }
      $matched = $true
    }

    # ENVIRONMENTAL DEATH (fall/drown/etc):  "<Player> - Lvl N (Tribe) was killed!"
    if (-not $matched -and $line -match '^(.+?)\s+-\s+Lvl\s+\d+\s*\([^)]*\)\s+was killed!') {
      $who = $Matches[1].Trim()
      if ($who -notmatch "'") {
        $result.deaths += @{ id=[guid]::NewGuid().ToString('n').Substring(0,10); who=$who; cause="Died mysteriously"; killer=""; ts=(Get-Date).ToString('o') }
      }
      $matched = $true
    }

    # TAME:  "<Player> of Tribe <T> Tamed a <Species> - Lvl N (Class)!"
    if (-not $matched -and $line -match '[Tt]amed a[n]?\s+(.+?)!') {
      $rawTame = $Matches[1].Trim()
      $tamer   = ($line -replace '\s+[Tt]amed a[n]?\s.*$', '').Trim()
      $tamer   = [regex]::Replace($tamer, '\s+of\s+Tribe\s+.*$', '').Trim()    # "Soop of Tribe Tiggles" -> "Soop"
      $tamer   = [regex]::Replace($tamer, '\s*-\s+Lvl.*$', '').Trim()
      $lvl     = [regex]::Match($rawTame, '-\s+Lvl\s+(\d+)')
      $level   = if ($lvl.Success) { $lvl.Groups[1].Value } else { "" }
      $species = [regex]::Replace($rawTame, '\s*-\s+Lvl\s+\d+.*$', '').Trim()   # drop "- Lvl N (Class)"
      $species = [regex]::Replace($species, '\s*\([^)]*\)\s*$', '').Trim()      # drop trailing "(Class)"
      # Skip tribe-level / baby-birth events (no individual tamer) and vehicles.
      if ($tamer -and $tamer -notmatch '^(Tribe|Your Tribe)\b' -and $species -notmatch '^(Wooden\s+)?(Raft|Motorboat)$') {
        $result.tames += @{ id=[guid]::NewGuid().ToString('n').Substring(0,10); tamer=$tamer; species=$species; name=""; level=$level; ts=(Get-Date).ToString('o') }
      }
      $matched = $true
    }

    if ($matched) { 
      $state.seen += $key 
    } elseif ($line -match "killed|Tamed|tamed") { 
      # Clear old instances so it doesn't just stack duplicates in unparsed.log
      Add-Content $Unparsed ("[{0}] {1}" -f (Get-Date -Format s), $line) 
    }
  }
  return $result
}

# ================= test-parse mode (offline regex tuning) =================
if ($TestLog) {
  if (-not (Test-Path $TestLog)) { throw "TestLog file not found: $TestLog" }
  $sample = Get-Content $TestLog -Raw
  $st = [pscustomobject]@{ seen = @() }
  $r = Parse-GameLog $sample $st
  Write-Host "DEATHS ($($r.deaths.Count)):"
  $r.deaths | ForEach-Object { Write-Host ("  {0,-14} <- {1}" -f $_.who, $_.killer) }
  Write-Host "TAMES ($($r.tames.Count)):"
  $r.tames | ForEach-Object { Write-Host ("  {0,-14} tamed {1} (Lvl {2})" -f $_.tamer, $_.species, $_.level) }
  exit 0
}

# ================= rebuild mode (re-parse history with the current parser) =================
if ($Rebuild) {
  $old = Load-State
  $lines = @($old.seen)
  # Also re-try anything previously logged as unparseable (strip the "[timestamp] " prefix).
  if (Test-Path $Unparsed) {
    Get-Content $Unparsed | ForEach-Object { $lines += ($_ -replace '^\[[^\]]*\]\s*', '') }
    Remove-Item $Unparsed   # Parse-GameLog re-logs any that STILL don't parse
  }
  $st = [pscustomobject]@{ seen = @() }
  $r = Parse-GameLog (($lines) -join "`n") $st
  Save-State ([pscustomobject]@{ deaths=@($r.deaths); tames=@($r.tames); events=@($old.events); seen=@($st.seen) })
  Write-Host ("Rebuilt from {0} remembered lines -> {1} deaths, {2} tames." -f $lines.Count, $r.deaths.Count, $r.tames.Count)
  Write-Host "Run the collector once more (or wait for the schedule) to refresh data.json."
  exit 0
}

# ================= collect =================
$state = Load-State
$deaths = AsList $state.deaths
$tames  = AsList $state.tames
$events = AsList $state.events
$seen   = AsList $state.seen
$online = @()
$serverUp = $false

if ($Offline) {
  Write-Host "OFFLINE mode - writing sample data.json"
  $now = Get-Date
  $online = @("Grillmaster","Chugz")
  $serverUp = $true
  if ($deaths.Count -eq 0) {
    [void]$deaths.Add(@{ id="s1"; who="Chugz"; cause="Slain in the wild"; killer="a Level 34 Raptor"; ts=$now.AddHours(-5).ToString('o') })
    [void]$deaths.Add(@{ id="s2"; who="Big Rig"; cause="Fell from a stupid height"; killer="Gravity"; ts=$now.AddHours(-2).ToString('o') })
    [void]$tames.Add(@{ id="s3"; tamer="Grillmaster"; species="Wyvern"; name=""; level="190"; ts=$now.AddHours(-4).ToString('o') })
    [void]$events.Add(@{ id="s4"; title="Server went live"; note="First base raised at the green obelisk."; ts=$now.AddDays(-1).ToString('o') })
  }
} else {
  $seenObj = [pscustomobject]@{ seen = @($seen) }   # give Parse-GameLog a .seen it can test
  try {
    $players = Invoke-Rcon $Config.RconHost $Config.RconPort $Config.RconPassword "ListPlayers"
    $online = Parse-Players $players
    $serverUp = $true
    $log = Invoke-Rcon $Config.RconHost $Config.RconPort $Config.RconPassword "GetGameLog"
    $parsed = Parse-GameLog $log $seenObj
    foreach ($d in $parsed.deaths) { [void]$deaths.Add($d) }
    foreach ($t in $parsed.tames)  { [void]$tames.Add($t) }
    $seen = AsList $seenObj.seen
  } catch {
    Write-Host "Server not reachable over RCON ($($_.Exception.Message)). Marking offline."
    $serverUp = $false
  }
}

# ---------------- persist state + build data.json ----------------
Save-State ([pscustomobject]@{ deaths=@($deaths); tames=@($tames); events=@($events); seen=@($seen) })

$data = [ordered]@{
  updated = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  server  = [ordered]@{ name=$Config.ServerName; map=$Config.Map; mode=$Config.Mode; online=$serverUp }
  online  = @($online)
  deaths  = @($deaths)
  tames   = @($tames)
  events  = @($events)
}
$data | ConvertTo-Json -Depth 8 | Set-Content $DataFile -Encoding utf8
Write-Host ("Wrote {0}  (online: {1}, deaths: {2}, tames: {3})" -f $DataFile, $online.Count, $deaths.Count, $tames.Count)

# ---------------- publish ----------------
$doPush = ($Config.Push -eq $true) -and (-not $NoPush)
if ($doPush) {
  Push-Location $Root
  try {
    git add data.json | Out-Null
    git commit -m ("data {0}" -f (Get-Date -Format s)) --quiet
    git push --quiet
    Write-Host "Pushed to GitHub."
  } catch { Write-Host "git push skipped/failed: $($_.Exception.Message)" }
  finally { Pop-Location }
}