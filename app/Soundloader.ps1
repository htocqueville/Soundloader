# Soundloader — Windows app (WinForms GUI)
# Launched by the "Soundloader" shortcut created by setup.ps1.
# Reads runtime configuration from %USERPROFILE%\.soundloader\windows.json.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = "Stop"

# ── Config ────────────────────────────────────────────────────────────────────

$ConfigFile = Join-Path $env:USERPROFILE ".soundloader\windows.json"
if (-not (Test-Path $ConfigFile)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Configuration not found.`n`nPlease run setup.ps1 from the Soundloader folder first.",
        "Soundloader", "OK", "Error") | Out-Null
    exit 1
}
$Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

$SpotdlPath    = $Config.spotdlPath
$YtdlpPath     = $Config.ytdlpPath
$RepoPath      = $Config.repoPath
$CurrentCommit = $Config.currentCommit
$CommitsURL    = $Config.commitsURL
$CookieBrowser = $Config.cookieBrowser

$SpotdlDir     = Join-Path $env:USERPROFILE ".spotdl"
$SpotdlConfig  = Join-Path $SpotdlDir "config.json"
$MusicDir      = [Environment]::GetFolderPath("MyMusic")
$OutputBase    = Join-Path $MusicDir "Soundloader"
$CacheDir      = Join-Path $env:USERPROFILE ".soundloader\cache"
$VenvPython    = Join-Path (Split-Path -Parent $SpotdlPath) "python.exe"
$IconPath      = Join-Path $RepoPath "assets\soundloader.ico"

$AppIcon = $null
if (Test-Path $IconPath) {
    try { $AppIcon = New-Object System.Drawing.Icon($IconPath) } catch {}
}

# Quote a value for interpolation into a generated PowerShell script
# (single-quoted, with embedded quotes doubled).
function SQ([string]$s) { return "'" + ($s -replace "'", "''") + "'" }

# ── Dialog helpers ────────────────────────────────────────────────────────────

# Custom multi-button choice dialog (WinForms MessageBox only offers fixed
# button sets — this mirrors AppleScript's `display dialog ... buttons {...}`).
function Show-Choice {
    param(
        [string]$Title,
        [string]$Message,
        [string[]]$Buttons,
        [string]$DefaultButton = ""
    )
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.FormBorderStyle = "FixedDialog"
    $form.StartPosition = "CenterScreen"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    if ($AppIcon) { $form.Icon = $AppIcon }

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Message
    $label.AutoSize = $true
    $label.MaximumSize = New-Object System.Drawing.Size(440, 0)
    $label.Location = New-Object System.Drawing.Point(20, 20)
    $form.Controls.Add($label)

    $form.SuspendLayout()
    $btnY = $label.Height + 45
    $btnWidth = 130
    $totalWidth = [Math]::Max(480, ($Buttons.Count * ($btnWidth + 10)) + 40)
    $x = $totalWidth - 20
    $script:choiceResult = $null
    # Right-align buttons, last button rightmost (primary action).
    for ($i = $Buttons.Count - 1; $i -ge 0; $i--) {
        $btnText = $Buttons[$i]
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $btnText
        $btn.Width = $btnWidth
        $btn.Height = 30
        $x -= ($btnWidth + 10)
        $btn.Location = New-Object System.Drawing.Point($x, $btnY)
        $btn.Add_Click({
            $script:choiceResult = $this.Text
            $form.Close()
        }.GetNewClosure())
        $form.Controls.Add($btn)
        if ($btnText -eq $DefaultButton) { $form.AcceptButton = $btn }
    }
    $form.ClientSize = New-Object System.Drawing.Size($totalWidth, ($btnY + 45))
    $form.ResumeLayout()
    $form.ShowDialog() | Out-Null
    $form.Dispose()
    return $script:choiceResult
}

# Text-input dialog (mirrors AppleScript's `display dialog ... default answer`).
function Show-Input {
    param(
        [string]$Title,
        [string]$Message,
        [string]$DefaultValue = "",
        [string]$OkLabel = "OK"
    )
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.FormBorderStyle = "FixedDialog"
    $form.StartPosition = "CenterScreen"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ClientSize = New-Object System.Drawing.Size(480, 150)
    if ($AppIcon) { $form.Icon = $AppIcon }

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Message
    $label.AutoSize = $true
    $label.MaximumSize = New-Object System.Drawing.Size(440, 0)
    $label.Location = New-Object System.Drawing.Point(20, 15)
    $form.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Width = 440
    $textBox.Text = $DefaultValue
    $textBox.Location = New-Object System.Drawing.Point(20, ($label.Height + 25))
    $form.Controls.Add($textBox)

    $btnY = $label.Height + 60

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = $OkLabel
    $okBtn.Width = 130
    $okBtn.Height = 30
    $okBtn.Location = New-Object System.Drawing.Point(330, $btnY)
    $okBtn.DialogResult = "OK"
    $form.Controls.Add($okBtn)
    $form.AcceptButton = $okBtn

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Width = 100
    $cancelBtn.Height = 30
    $cancelBtn.Location = New-Object System.Drawing.Point(220, $btnY)
    $cancelBtn.DialogResult = "Cancel"
    $form.Controls.Add($cancelBtn)
    $form.CancelButton = $cancelBtn

    $form.ClientSize = New-Object System.Drawing.Size(480, ($btnY + 45))
    $result = $form.ShowDialog()
    $value = $textBox.Text
    $form.Dispose()
    if ($result -ne "OK") { return $null }
    return $value
}

function Show-Alert {
    param([string]$Title, [string]$Message, [string]$Icon = "Warning")
    [System.Windows.Forms.MessageBox]::Show($Message, $Title, "OK", $Icon) | Out-Null
}

# Launch a download command in a visible PowerShell console that stays open.
function Start-DownloadConsole {
    param([string]$ScriptText)
    $tmp = Join-Path $env:TEMP "soundloader_run.ps1"
    Set-Content -Path $tmp -Value $ScriptText -Encoding UTF8
    Start-Process powershell.exe -ArgumentList @(
        "-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$tmp`""
    )
}

function Save-Config {
    $Config | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
}

# ── Update ────────────────────────────────────────────────────────────────────

function Get-RemoteCommit {
    # Returns @{sha=..; message=..; date=..} or $null on any failure.
    if (-not $CommitsURL) { return $null }
    try {
        $resp = Invoke-RestMethod -Uri $CommitsURL -TimeoutSec 5 -Headers @{ "User-Agent" = "Soundloader" }
        return @{
            sha     = $resp.sha
            message = ($resp.commit.message -split "`n")[0]
            date    = $resp.commit.author.date.ToString("yyyy-MM-dd")
        }
    } catch { return $null }
}

function Invoke-Update {
    $updateScript = @"
Set-Location '$RepoPath'
Write-Host 'Pulling latest changes...' -ForegroundColor Cyan
git pull --ff-only
if (`$LASTEXITCODE -eq 0) {
    Write-Host ''
    Write-Host 'Rebuilding app...' -ForegroundColor Cyan
    & powershell -NoProfile -ExecutionPolicy Bypass -File '$RepoPath\setup.ps1'
    Write-Host ''
    Write-Host 'Update complete! Please reopen Soundloader from the Start Menu.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host 'Update failed. Check the output above and try again.' -ForegroundColor Red
}
"@
    Start-DownloadConsole $updateScript
}

function Test-ForUpdates {
    # On-demand check (from Settings). Returns $true if user launched an update.
    if (-not $CommitsURL) {
        Show-Alert "Update check unavailable" "No GitHub remote is configured. Re-run setup.ps1 from the project folder to fix this."
        return $false
    }
    $remote = Get-RemoteCommit
    if (-not $remote) {
        Show-Alert "Update check failed" "Could not reach GitHub. Check your internet connection."
        return $false
    }
    $shortLocal  = $CurrentCommit.Substring(0, [Math]::Min(7, $CurrentCommit.Length))
    $shortRemote = $remote.sha.Substring(0, 7)
    if ($remote.sha -eq $CurrentCommit) {
        Show-Alert "You're up to date!" "Commit : $shortLocal`nDate   : $($remote.date)" "Information"
        return $false
    }
    $msg = "A new update is available!`n`nInstalled : $shortLocal`nAvailable : $shortRemote  ($($remote.date))`n            `"$($remote.message)`"`n`nUpdate now?"
    $choice = Show-Choice -Title "Update Available" -Message $msg -Buttons @("Cancel", "Update Now") -DefaultButton "Update Now"
    if ($choice -eq "Update Now") {
        Invoke-Update
        return $true
    }
    return $false
}

# ── Credentials ───────────────────────────────────────────────────────────────

function Read-SpotdlConfig {
    try { return Get-Content $SpotdlConfig -Raw | ConvertFrom-Json } catch { return $null }
}

function Save-Credentials {
    param([string]$ClientId, [string]$ClientSecret)
    New-Item -ItemType Directory -Force -Path $SpotdlDir | Out-Null
    $cfg = Read-SpotdlConfig
    if (-not $cfg) {
        # No config yet — let spotdl generate its defaults, then re-read.
        & $SpotdlPath --generate-config 2>$null | Out-Null
        $cfg = Read-SpotdlConfig
        if (-not $cfg) { $cfg = [PSCustomObject]@{} }
    }
    $cfg | Add-Member -NotePropertyName "client_id" -NotePropertyValue $ClientId -Force
    $cfg | Add-Member -NotePropertyName "client_secret" -NotePropertyValue $ClientSecret -Force
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $SpotdlConfig -Encoding UTF8
    # Clear cached auth tokens so the new credentials take effect.
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $SpotdlDir ".spotipy")
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $env:USERPROFILE ".cache")
}

function Test-HasCredentials {
    $defaultId = "5f573c9620494bae87890c0f08a60293"
    $cfg = Read-SpotdlConfig
    if (-not $cfg) { return $false }
    $cid = [string]$cfg.client_id
    $cs  = [string]$cfg.client_secret
    return ($cid -and $cid.Length -gt 5 -and $cs -and $cs.Length -gt 5 -and $cid -ne $defaultId)
}

function Invoke-CredentialsWizard {
    param([bool]$FirstTime = $false)
    if ($FirstTime) {
        Show-Choice -Title "Spotify Setup Required" -Message (
            "To download from Spotify, you need a free Spotify Developer account.`n`n" +
            "Click 'Open Dashboard' to create an app and get your API credentials."
        ) -Buttons @("Open Dashboard") -DefaultButton "Open Dashboard" | Out-Null
    }
    Start-Process "https://developer.spotify.com/dashboard"
    Show-Alert "Create a Spotify App" (
        "In the dashboard:`n" +
        "1. Click 'Create app'`n" +
        "2. Fill in any name and description`n" +
        "3. Add both Redirect URIs:`n" +
        "   - http://127.0.0.1:9900/`n" +
        "   - http://127.0.0.1:9900`n" +
        "4. Check 'Web API'`n" +
        "5. Go to Settings -> copy Client ID and Client Secret`n`n" +
        "Then click OK and enter your credentials."
    ) "Information"
    $cfg = Read-SpotdlConfig
    $currentId = if ($cfg) { [string]$cfg.client_id } else { "" }
    $newId = Show-Input -Title "Spotify Credentials - Step 1/2" -Message "Spotify Client ID:" -DefaultValue $currentId -OkLabel "Next"
    if ($null -eq $newId) { return $false }
    $newSecret = Show-Input -Title "Spotify Credentials - Step 2/2" -Message "Spotify Client Secret:" -OkLabel "Save"
    if ($null -eq $newSecret) { return $false }
    Save-Credentials $newId $newSecret
    return $true
}

# ── Settings ──────────────────────────────────────────────────────────────────

function Show-Settings {
    $cfg = Read-SpotdlConfig
    $currentId = if ($cfg) { [string]$cfg.client_id } else { "" }
    $maskedId = "(not set)"
    if ($currentId.Length -gt 8) { $maskedId = $currentId.Substring(0, 8) + "........" }
    elseif ($currentId) { $maskedId = $currentId + "...." }

    $shortCommit = $CurrentCommit.Substring(0, [Math]::Min(7, $CurrentCommit.Length))
    $info = "Spotify Client ID : $maskedId`nYouTube browser   : $CookieBrowser`nCommit            : $shortCommit"

    $choice = Show-Choice -Title "Settings" -Message $info -Buttons @(
        "Cancel", "YouTube Browser", "Check for Updates", "Edit Spotify Credentials"
    ) -DefaultButton "Edit Spotify Credentials"

    if ($choice -eq "Check for Updates") {
        Test-ForUpdates | Out-Null
    }
    elseif ($choice -eq "YouTube Browser") {
        $browser = Show-Choice -Title "YouTube Browser" -Message (
            "Which browser should be used for YouTube cookies?`n`n" +
            "You must be logged into YouTube in that browser.`n" +
            "Firefox is the most reliable on Windows.`n" +
            "'None' disables cookies (may hit bot detection)."
        ) -Buttons @("None", "Edge", "Chrome", "Firefox") -DefaultButton "Firefox"
        if ($browser) {
            $script:CookieBrowser = $browser.ToLower()
            $Config.cookieBrowser = $script:CookieBrowser
            Save-Config
            Show-Alert "Saved" "YouTube cookies will now be read from: $script:CookieBrowser" "Information"
        }
    }
    elseif ($choice -eq "Edit Spotify Credentials") {
        if (Invoke-CredentialsWizard) {
            Show-Alert "Credentials Saved" (
                "Your Spotify credentials have been updated and the auth cache has been cleared.`n`n" +
                "The app will open a browser to re-authenticate on your next Spotify download."
            ) "Information"
        }
    }
}

# ── Spotify ───────────────────────────────────────────────────────────────────

function Invoke-Spotify {
    param([string]$PlaylistURL)

    if (-not (Test-HasCredentials)) {
        if (-not (Invoke-CredentialsWizard -FirstTime $true)) { return }
    }

    $outputTemplate = Join-Path $OutputBase "{list-name}\{list-position} - {artists} - {title}.{output-ext}"
    $syncScript     = Join-Path $RepoPath "scripts\spotify_sync.py"
    $precheckScript = Join-Path $RepoPath "scripts\spotify_precheck.py"

    $useCache  = $false
    $cacheFile = ""

    if ($PlaylistURL -match "/playlist/") {
        # ── Pre-check: rate-limit detection + local cache lookup ──────────────
        $precheckOut = ""
        try {
            $precheckOut = (& $VenvPython $precheckScript --url $PlaylistURL --cache-dir $CacheDir 2>$null | Select-Object -First 1)
        } catch {}

        if ($precheckOut) {
            # STATUS|RETRY_AFTER|CACHE_FILE|PLAYLIST_NAME|TRACK_COUNT|CACHE_AGE_HOURS
            $parts = $precheckOut -split "\|"
            $status      = $parts[0]
            $retryAfter  = 0; [int]::TryParse($parts[1], [ref]$retryAfter) | Out-Null
            $cachedFile  = $parts[2]
            $cachedName  = $parts[3]
            $cachedCount = $parts[4]
            $cachedAgeH  = $parts[5]

            $retryStr = ""
            if ($retryAfter -gt 0) {
                $rHours = [Math]::Floor($retryAfter / 3600)
                $rMins  = [Math]::Floor(($retryAfter % 3600) / 60)
                $retryStr = if ($rHours -gt 0) { "${rHours}h ${rMins}min" } else { "${rMins}min" }
            }

            if ($status -eq "RATE_LIMITED") {
                $choice = Show-Choice -Title "Spotify API Rate Limited" -Message (
                    "Your Spotify credentials are blocked for another $retryStr.`n`n" +
                    "To download now:`n" +
                    "1. Open the Spotify Developer Dashboard`n" +
                    "2. Create a new app (2 min)`n" +
                    "3. Come back to Settings -> Edit Spotify Credentials"
                ) -Buttons @("Close", "Open Dashboard") -DefaultButton "Open Dashboard"
                if ($choice -eq "Open Dashboard") {
                    Start-Process "https://developer.spotify.com/dashboard"
                }
                return
            }
            elseif ($status -eq "RATE_LIMITED_CACHE") {
                $choice = Show-Choice -Title "Spotify API Rate Limited" -Message (
                    "The Spotify API is blocked for another $retryStr.`n`n" +
                    "But you have a local cache of `"$cachedName`" ($cachedCount tracks, ${cachedAgeH}h old).`n`n" +
                    "Use the cache to continue the download?"
                ) -Buttons @("Cancel", "Open Dashboard", "Use Cache") -DefaultButton "Use Cache"
                if ($choice -eq "Cancel" -or $null -eq $choice) { return }
                if ($choice -eq "Open Dashboard") {
                    Start-Process "https://developer.spotify.com/dashboard"
                    return
                }
                $useCache = $true
                $cacheFile = $cachedFile
            }
            elseif ($status -eq "OK_CACHE") {
                $choice = Show-Choice -Title "Cache Available" -Message (
                    "Cache available for `"$cachedName`" ($cachedCount tracks, updated ${cachedAgeH}h ago).`n`n" +
                    "Use the cache (fast, 0 Spotify API calls) or fetch fresh data?"
                ) -Buttons @("Cancel", "Fetch Fresh", "Use Cache") -DefaultButton "Use Cache"
                if ($choice -eq "Cancel" -or $null -eq $choice) { return }
                if ($choice -eq "Use Cache") {
                    $useCache = $true
                    $cacheFile = $cachedFile
                }
            }
            # status "OK" (no cache) -> proceed silently
        }
    }

    # ── Build the download script ─────────────────────────────────────────────
    $lines = @()
    $lines += "`$Host.UI.RawUI.WindowTitle = 'Soundloader - Spotify'"
    $dlTarget = $PlaylistURL

    if ($PlaylistURL -match "/playlist/") {
        if ($useCache) {
            # Use cached .spotdl file: sync reconciles local files, spotdl downloads
            # only missing tracks — no Spotify API call in either step.
            # IMPORTANT: spotdl reads a .spotdl save file when it is passed AS THE
            # QUERY (e.g. `spotdl download cache.spotdl`).
            $lines += "& $(SQ $VenvPython) $(SQ $syncScript) --url $(SQ $PlaylistURL) --output-base $(SQ $OutputBase) --spotdl $(SQ $SpotdlPath) --cache-file $(SQ $cacheFile)"
            $dlTarget = $cacheFile
        } else {
            # Fresh fetch: sync saves result to cache for next time.
            $lines += "& $(SQ $VenvPython) $(SQ $syncScript) --url $(SQ $PlaylistURL) --output-base $(SQ $OutputBase) --spotdl $(SQ $SpotdlPath) --cache-dir $(SQ $CacheDir)"
        }
    }

    $lines += "& $(SQ $SpotdlPath) --config --user-auth download $(SQ $dlTarget) --bitrate 320k --format mp3 --threads 4 --scan-for-songs --output $(SQ $outputTemplate)"
    $lines += "Write-Host ''"
    $lines += "Write-Host 'Download complete. You can close this window.' -ForegroundColor Green"

    Start-DownloadConsole ($lines -join "`r`n")
}

# ── SoundCloud ────────────────────────────────────────────────────────────────

function Invoke-SoundCloud {
    param([string]$ScURL)
    $isSet = $ScURL -match "/sets/"
    if ($isSet) {
        $outputTemplate = Join-Path $OutputBase "%(playlist_title)s\%(playlist_index)02d - %(uploader)s - %(title)s.%(ext)s"
    } else {
        $outputTemplate = Join-Path $OutputBase "SoundCloud\%(uploader)s - %(title)s.%(ext)s"
    }

    $lines = @(
        "`$Host.UI.RawUI.WindowTitle = 'Soundloader - SoundCloud'",
        ("& $(SQ $YtdlpPath) --ignore-errors --no-overwrites" +
         " --extract-audio --audio-format mp3 --audio-quality 0" +
         " --add-metadata --embed-thumbnail" +
         " --min-sleep-interval 2 --max-sleep-interval 4" +
         " --retries 5" +
         " -o $(SQ $outputTemplate) $(SQ $ScURL)"),
        "Write-Host ''",
        "Write-Host 'Download complete. You can close this window.' -ForegroundColor Green"
    )
    Start-DownloadConsole ($lines -join "`r`n")
}

# ── YouTube ───────────────────────────────────────────────────────────────────

function Invoke-YouTube {
    param([string]$VideoURL)
    $isPlaylist = $VideoURL -match "list="
    if ($isPlaylist) {
        $outputTemplate = Join-Path $OutputBase "%(playlist_title)s\%(title)s.%(ext)s"
    } else {
        $outputTemplate = Join-Path $OutputBase "YouTube\%(uploader)s - %(title)s.%(ext)s"
    }

    # Cookies: read from the configured browser (must be logged into YouTube).
    $cookieArg = ""
    if ($CookieBrowser -and $CookieBrowser -ne "none") {
        $cookieArg = " --cookies-from-browser $CookieBrowser"
    }

    # Metadata cleanup flags — same as the macOS app:
    # --embed-thumbnail      : embed cover art into the MP3
    # --parse-metadata (1st) : split "Artist - Title" from the video title
    # --parse-metadata (2nd) : extract the 4-digit year from upload_date
    # --postprocessor-args   : 320k bitrate + strip YouTube junk tags
    $lines = @(
        "`$Host.UI.RawUI.WindowTitle = 'Soundloader - YouTube'",
        ("& $(SQ $YtdlpPath) --extract-audio --audio-format mp3" +
         " --embed-thumbnail" +
         " --parse-metadata 'title:(?P<artist>.+?) [–\-] (?P<track>.+)'" +
         " --parse-metadata 'upload_date:(?P<date>\d{4})'" +
         " --postprocessor-args 'ffmpeg:-b:a 320k -metadata description= -metadata synopsis= -metadata purl= -metadata comment='" +
         " --yes-playlist --no-overwrites --add-metadata" +
         $cookieArg +
         " -o $(SQ $outputTemplate) $(SQ $VideoURL)"),
        "Write-Host ''",
        "Write-Host 'Download complete. You can close this window.' -ForegroundColor Green"
    )
    Start-DownloadConsole ($lines -join "`r`n")
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Auto-update check: compare the stored git SHA against GitHub main.
# All errors are swallowed so a network issue never blocks the app.
if ($CommitsURL) {
    $remote = Get-RemoteCommit
    if ($remote -and $remote.sha -ne $CurrentCommit) {
        $shortLocal  = $CurrentCommit.Substring(0, [Math]::Min(7, $CurrentCommit.Length))
        $shortRemote = $remote.sha.Substring(0, 7)
        $msg = "A new update is available!`n`nInstalled : $shortLocal`nAvailable : $shortRemote  ($($remote.date))`n            `"$($remote.message)`"`n`nUpdate now? Opens a console and rebuilds the app automatically."
        $choice = Show-Choice -Title "Update Available" -Message $msg -Buttons @("Later", "Update Now") -DefaultButton "Update Now"
        if ($choice -eq "Update Now") {
            Invoke-Update
            exit 0
        }
    }
}

# Main dialog loop (Settings returns here, like the macOS app's flow).
while ($true) {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Soundloader"
    $form.FormBorderStyle = "FixedDialog"
    $form.StartPosition = "CenterScreen"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ClientSize = New-Object System.Drawing.Size(480, 150)
    if ($AppIcon) { $form.Icon = $AppIcon }

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Paste a Spotify, YouTube or SoundCloud URL:"
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(20, 15)
    $form.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Width = 440
    $textBox.Location = New-Object System.Drawing.Point(20, 45)
    $form.Controls.Add($textBox)

    $downloadBtn = New-Object System.Windows.Forms.Button
    $downloadBtn.Text = "Download"
    $downloadBtn.Width = 130
    $downloadBtn.Height = 30
    $downloadBtn.Location = New-Object System.Drawing.Point(330, 95)
    $downloadBtn.DialogResult = "OK"
    $form.Controls.Add($downloadBtn)
    $form.AcceptButton = $downloadBtn

    $settingsBtn = New-Object System.Windows.Forms.Button
    $settingsBtn.Text = "Settings"
    $settingsBtn.Width = 100
    $settingsBtn.Height = 30
    $settingsBtn.Location = New-Object System.Drawing.Point(220, 95)
    $settingsBtn.DialogResult = "Retry"   # sentinel for "open settings"
    $form.Controls.Add($settingsBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Width = 100
    $cancelBtn.Height = 30
    $cancelBtn.Location = New-Object System.Drawing.Point(110, 95)
    $cancelBtn.DialogResult = "Cancel"
    $form.Controls.Add($cancelBtn)
    $form.CancelButton = $cancelBtn

    $result = $form.ShowDialog()
    $inputURL = $textBox.Text.Trim()
    $form.Dispose()

    if ($result -eq "Retry") {
        Show-Settings
        continue
    }
    if ($result -ne "OK") { exit 0 }

    if (-not $inputURL) {
        Show-Alert "Error" "URL cannot be empty."
        continue
    }

    $isSpotify    = $inputURL -match "spotify\.com"
    $isYouTube    = ($inputURL -match "youtube\.com") -or ($inputURL -match "youtu\.be")
    $isSoundCloud = $inputURL -match "soundcloud\.com"

    if (-not ($isSpotify -or $isYouTube -or $isSoundCloud)) {
        Show-Alert "Unsupported URL" "Please enter a Spotify, YouTube or SoundCloud URL."
        continue
    }

    try {
        if     ($isSpotify)    { Invoke-Spotify $inputURL }
        elseif ($isSoundCloud) { Invoke-SoundCloud $inputURL }
        else                   { Invoke-YouTube $inputURL }
    } catch {
        Show-Alert "An error occurred" $_.Exception.Message "Error"
    }
    exit 0
}
