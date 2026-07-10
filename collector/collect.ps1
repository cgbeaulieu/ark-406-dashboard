<#
============================================================
  406 Dashboard collector
  Runs on the SERVER PC (Task Scheduler, every few minutes).
  Talks to the ARK server over RCON, extracts live data, and
  writes ..\data.json (which the static dashboard fetches).

  Usage:
    .\collect.ps1              # normal run: RCON -> data.json (+ push if enabled)
    .\collect.ps1 -Offline     # no server needed: writes sample data.json to test the site
    .\collect.ps1 -NoPush      # collect but don't git push

  NOTE: the tribe-log parsing (deaths/tames) is best-effort against
  ARK's known log format. It writes anything it can't parse to
  collector\unparsed.log so we can fine-tune regexes after the first
  live run. Online players / server status are rock-solid.
============================================================
#>
param(
  [switch]$Offline,
  [switch]$NoPush
)
$ErrorActionPreference = "Stop"
$Root      = Split-Path -Parent $PSScriptRoot          # repo root
$DataFile  = Join-Path $Root "data.json"
$StateFile = Join-Path $PSScriptRoot "state.json"
$Unparsed  = Join-Path $PSScriptRoot "unparsed.log"

# ---------------- config ----------------
$cfgPath = Join-Path $PSScriptRoot "config.ps1"
if (Test-Path $cfgPath) { . $cfgPath }
elseif (-not $Offline)  { throw "Missing collector\config.ps1 - copy config.example.ps1 to config.ps1 and fill it in." }
if (-not $Config) { $Config = @{ ServerName="406 Server"; Map="Ragnarok"; Mode="PvE Co-op"; Push=$false } }

# ---------------- state (accumulated history) ----------------
function Load-State {
  if (Test-Path $StateFile) { return Get-Content $StateFile -Raw | ConvertFrom-Json }
  return [pscustomobject]@{ deaths=@(); tames=@(); events=@(); seen=@() }
}
function Save-State($s) { $s | ConvertTo-Json -Depth 8 | Set-Content $StateFile -Encoding utf8 }
# ConvertFrom-Json gives fixed-size arrays; wrap so we can append.
function AsList($x) { $l = New-Object System.Collections.ArrayList; if ($x) { foreach ($i in $x) { [void]$l.Add($i) } }; return ,$l }

# ================= Source RCON (from scratch, no dependencies) =================
function Write-RconPacket($stream, [int]$id, [int]$type, [string]$body) {
  $bodyBytes = [Text.Encoding]::ASCII.GetBytes($body)
  $len = 4 + 4 + $bodyBytes.Length + 2
  $ms = New-Object IO.MemoryStream
  $bw = New-Object IO.BinaryWriter($ms)        # BinaryWriter is little-endian on Windows
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
    Write-RconPacket $stream 1 3 $pass                 # SERVERDATA_AUTH
    # Auth reply is a type-2 packet; id = -1 means bad password (may be preceded by a junk type-0).
    $ok = $false
    for ($i=0; $i -lt 3; $i++) {
      $p = Read-RconPacket $stream
      if ($p.type -eq 2) { if ($p.id -eq -1) { throw "RCON auth failed (bad password)" } $ok=$true; break }
    }
    if (-not $ok) { throw "RCON auth: no auth response" }
    Write-RconPacket $stream 2 2 $command              # SERVERDATA_EXECCOMMAND
    Start-Sleep -Milliseconds 150
    # Read one or more response packets until the stream goes quiet.
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
  # "ListPlayers" -> lines like "0. SomeName, 0002abc..." or "No Players Connected"
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
    $key = ($line -replace '\s+', ' ').Trim()
    if ($state.seen -contains $key) { continue }         # dedupe against history
    $matched = $false

    # DEATH:  "Name was killed by <killer>!"   (skip quoted victims = tamed dinos)
    $m = [regex]::Match($line, "([A-Za-z0-9_][\w '\-]*?) was killed by (.+?)[!.]")
    if ($m.Success -and $m.Groups[1].Value -notmatch "'") {
      $result.deaths += @{ id=[guid]::NewGuid().ToString('n').Substring(0,10); who=$m.Groups[1].Value.Trim();
        cause="Slain in the wild"; killer=(Strip-Rich $m.Groups[2].Value).Trim(); ts=(Get-Date).ToString('o') }
      $matched = $true
    }
    if (-not $matched) {
      $m = [regex]::Match($line, "([A-Za-z0-9_][\w '\-]*?) was killed[!.]")
      if ($m.Success -and $m.Groups[1].Value -notmatch "'") {
        $result.deaths += @{ id=[guid]::NewGuid().ToString('n').Substring(0,10); who=$m.Groups[1].Value.Trim();
          cause="Died mysteriously"; killer=""; ts=(Get-Date).ToString('o') }
        $matched = $true
      }
    }
    # TAME:  "Name Tamed a <Species> - Lvl NN (Species)!"
    if (-not $matched) {
      $m = [regex]::Match($line, "([A-Za-z0-9_][\w '\-]*?) [Tt]amed a[n]? (.+?)( - Lvl (\d+))?[ !\(]")
      if ($m.Success) {
        $result.tames += @{ id=[guid]::NewGuid().ToString('n').Substring(0,10); tamer=$m.Groups[1].Value.Trim();
          species=(Strip-Rich $m.Groups[2].Value).Trim(); name=""; level=$m.Groups[4].Value; ts=(Get-Date).ToString('o') }
        $matched = $true
      }
    }

    if ($matched) { $state.seen += $key }
    elseif ($line -match "killed|Tamed|tamed") { Add-Content $Unparsed ("[{0}] {1}" -f (Get-Date -Format s), $line) }
  }
  return $result
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
