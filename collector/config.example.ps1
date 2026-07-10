# ============================================================
#  406 Dashboard collector - configuration
#  Copy this file to  config.ps1  and fill in your values.
#  config.ps1 is gitignored and NEVER committed (it holds your
#  RCON password), so your secrets stay on this machine only.
# ============================================================
$Config = @{
  # --- RCON (matches GameUserSettings.ini) ---
  RconHost     = "127.0.0.1"          # collector runs on the same PC as the server
  RconPort     = 27020
  RconPassword = "PUT_YOUR_ServerAdminPassword_HERE"   # copy from GameUserSettings.ini; real value goes in config.ps1 only

  # --- Shown on the dashboard ---
  ServerName   = "406 Server"
  Map          = "Ragnarok"
  Mode         = "PvE Co-op"

  # --- Publish (leave Push = $false until git is wired up; see README) ---
  Push         = $false
}
