# Soundloader — Windows setup
# Run from the repo root in PowerShell:
#   powershell -ExecutionPolicy Bypass -File setup.ps1

$ErrorActionPreference = "Stop"

function Info($msg)    { Write-Host "==> $msg" -ForegroundColor White }
function Success($msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Warn($msg)    { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Fail($msg)    { Write-Host "[X] $msg" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "=====================================" -ForegroundColor White
Write-Host "   Soundloader - Windows Setup"       -ForegroundColor White
Write-Host "=====================================" -ForegroundColor White
Write-Host ""

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Refresh PATH from registry so tools installed moments ago are visible
# in this same session (winget adds entries to the user/machine PATH).
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user    = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
}

# ── 1. winget ─────────────────────────────────────────────────────────────────
Info "Checking winget..."
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Fail "winget not found. Install 'App Installer' from the Microsoft Store, then re-run setup.ps1."
}
Success "winget available"

function Install-WingetPackage($id, $label) {
    Info "Checking $label..."
    $listed = winget list --id $id --exact --accept-source-agreements 2>$null | Out-String
    if ($listed -match [regex]::Escape($id)) {
        Success "$label already installed"
    } else {
        Info "Installing $label..."
        winget install --id $id --exact --silent --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { Warn "$label install returned exit code $LASTEXITCODE" }
        Update-SessionPath
    }
}

# ── 2. ffmpeg ─────────────────────────────────────────────────────────────────
if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    Success "ffmpeg already installed"
} else {
    Install-WingetPackage "Gyan.FFmpeg" "ffmpeg"
    Update-SessionPath
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        Warn "ffmpeg not on PATH yet - it will be available in new terminals"
    }
}

# ── 3. Python 3.10-3.13 (spotdl requires >=3.10, <3.14) ──────────────────────
Info "Checking Python version for spotdl..."

function Find-CompatiblePython {
    # Try the py launcher for each compatible version, newest first.
    foreach ($ver in @("3.13", "3.12", "3.11", "3.10")) {
        if (Get-Command py -ErrorAction SilentlyContinue) {
            & py "-$ver" -c "import sys" 2>$null
            if ($LASTEXITCODE -eq 0) {
                return (& py "-$ver" -c "import sys; print(sys.executable)")
            }
        }
    }
    # Fall back to whatever `python` resolves to, if in range.
    if (Get-Command python -ErrorAction SilentlyContinue) {
        $verOk = & python -c "import sys; print(1 if (sys.version_info.major==3 and 10<=sys.version_info.minor<14) else 0)" 2>$null
        if ($verOk -eq "1") {
            return (& python -c "import sys; print(sys.executable)")
        }
    }
    return $null
}

$PythonForSpotdl = Find-CompatiblePython
if (-not $PythonForSpotdl) {
    Warn "Python 3.10-3.13 not found (spotdl is not yet compatible with Python 3.14+)."
    Install-WingetPackage "Python.Python.3.13" "Python 3.13"
    Update-SessionPath
    $PythonForSpotdl = Find-CompatiblePython
    if (-not $PythonForSpotdl) {
        Fail "Python 3.13 was installed but not found. Open a new PowerShell window and re-run setup.ps1."
    }
}
Success "Using $PythonForSpotdl for spotdl"

# ── 4. pipx ───────────────────────────────────────────────────────────────────
Info "Checking pipx..."
& $PythonForSpotdl -m pipx --version 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Info "Installing pipx..."
    & $PythonForSpotdl -m pip install --user --quiet pipx
    & $PythonForSpotdl -m pipx ensurepath
    Update-SessionPath
} else {
    Success "pipx already installed"
}

# ── 5. spotdl (nyekuuu fork - adds --user-auth OAuth for Spotify) ─────────────
$SpotdlFork = "git+https://github.com/nyekuuu/spotify-downloader.git"
Info "Installing spotdl from nyekuuu fork..."
& $PythonForSpotdl -m pipx install --force --python $PythonForSpotdl $SpotdlFork
if ($LASTEXITCODE -ne 0) { Fail "spotdl install failed. Check the output above." }

# ── 6. yt-dlp ─────────────────────────────────────────────────────────────────
Install-WingetPackage "yt-dlp.yt-dlp" "yt-dlp"

# ── 7. Resolve binary paths ───────────────────────────────────────────────────
Info "Resolving binary paths..."

$PipxVenvs = (& $PythonForSpotdl -m pipx environment --value PIPX_LOCAL_VENVS 2>$null | Select-Object -First 1)
if (-not $PipxVenvs) { $PipxVenvs = Join-Path $env:USERPROFILE "pipx\venvs" }

$SpotdlPath = Join-Path $PipxVenvs "spotdl\Scripts\spotdl.exe"
if (-not (Test-Path $SpotdlPath)) {
    $found = Get-Command spotdl -ErrorAction SilentlyContinue
    if ($found) { $SpotdlPath = $found.Source }
    else { Fail "spotdl binary not found. Try re-running setup.ps1 in a new PowerShell window." }
}
Success "spotdl: $SpotdlPath"

$VenvPython = Join-Path (Split-Path -Parent $SpotdlPath) "python.exe"

Update-SessionPath
$YtdlpCmd = Get-Command yt-dlp -ErrorAction SilentlyContinue
if ($YtdlpCmd) {
    $YtdlpPath = $YtdlpCmd.Source
} else {
    $YtdlpPath = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\yt-dlp.exe"
    if (-not (Test-Path $YtdlpPath)) {
        Fail "yt-dlp binary not found. Try: winget install yt-dlp.yt-dlp"
    }
}
Success "yt-dlp: $YtdlpPath"

# ── 8. Apply Soundloader's spotdl patches (shared with macOS setup) ───────────
Info "Applying spotdl patches..."
if (Test-Path $VenvPython) {
    & $VenvPython (Join-Path $ScriptDir "scripts\patch_spotdl.py")
    if ($LASTEXITCODE -ne 0) { Warn "spotdl patching reported an issue - check output above" }
    else { Success "spotdl patches applied" }
} else {
    Warn "spotdl venv python not found - skipping patches"
}

# ── 9. Detect a browser for YouTube cookies ───────────────────────────────────
# yt-dlp reads cookies from an installed browser to avoid bot detection.
# Firefox is the most reliable on Windows (Chrome/Edge use app-bound cookie
# encryption since 2024 which yt-dlp cannot always bypass).
Info "Detecting a browser for YouTube cookies..."
$CookieBrowser = "none"
$firefoxPaths = @(
    (Join-Path $env:ProgramFiles "Mozilla Firefox\firefox.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Mozilla Firefox\firefox.exe")
)
$chromePaths = @(
    (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe")
)
$edgePaths = @(
    (Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe")
)
if ($firefoxPaths | Where-Object { $_ -and (Test-Path $_) }) { $CookieBrowser = "firefox" }
elseif ($chromePaths | Where-Object { $_ -and (Test-Path $_) }) { $CookieBrowser = "chrome" }
elseif ($edgePaths | Where-Object { $_ -and (Test-Path $_) }) { $CookieBrowser = "edge" }

if ($CookieBrowser -eq "none") {
    Warn "No browser detected - YouTube downloads will run without cookies (may hit bot detection)."
} else {
    Success "YouTube cookies will be read from: $CookieBrowser"
}

# ── 10. Write app config ──────────────────────────────────────────────────────
Info "Writing app configuration..."

$CurrentCommit = "unknown"
try { $CurrentCommit = (git -C $ScriptDir rev-parse HEAD 2>$null).Trim() } catch {}

$CommitsURL = ""
try {
    $remote = (git -C $ScriptDir remote get-url origin 2>$null).Trim()
    if ($remote -match "github\.com[:/](.+?)(\.git)?$") {
        $CommitsURL = "https://api.github.com/repos/$($Matches[1])/commits/main"
    }
} catch {}

$ConfigDir = Join-Path $env:USERPROFILE ".soundloader"
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
$Config = [ordered]@{
    spotdlPath    = $SpotdlPath
    ytdlpPath     = $YtdlpPath
    repoPath      = $ScriptDir
    currentCommit = $CurrentCommit
    commitsURL    = $CommitsURL
    cookieBrowser = $CookieBrowser
}
$Config | ConvertTo-Json | Set-Content -Path (Join-Path $ConfigDir "windows.json") -Encoding UTF8
Success "Config written to $ConfigDir\windows.json"

# ── 11. Create shortcuts (Start Menu + Desktop) ───────────────────────────────
Info "Creating shortcuts..."

$AppScript = Join-Path $ScriptDir "app\Soundloader.ps1"
$IconPath  = Join-Path $ScriptDir "assets\soundloader.ico"
$WshShell  = New-Object -ComObject WScript.Shell

foreach ($dest in @(
    (Join-Path ([Environment]::GetFolderPath("Programs")) "Soundloader.lnk"),
    (Join-Path ([Environment]::GetFolderPath("Desktop"))  "Soundloader.lnk")
)) {
    $shortcut = $WshShell.CreateShortcut($dest)
    $shortcut.TargetPath = "powershell.exe"
    $shortcut.Arguments  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AppScript`""
    $shortcut.WorkingDirectory = $ScriptDir
    if (Test-Path $IconPath) { $shortcut.IconLocation = $IconPath }
    $shortcut.Description = "Soundloader - download music from Spotify, YouTube and SoundCloud"
    $shortcut.Save()
}
Success "Shortcuts created (Start Menu + Desktop)"

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host "   Setup complete!"                                 -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Open 'Soundloader' from the Start Menu or the Desktop shortcut."
Write-Host ""
Write-Host "  YouTube  -> works immediately (uses $CookieBrowser cookies)."
Write-Host "  Spotify  -> the app will guide you through credentials on first use."
Write-Host "              See docs/spotify-setup.md for a step-by-step guide."
Write-Host ""
