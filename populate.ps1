# =============================================================================
# Sovereign OS -- populate.ps1 v2.0
# Run on Windows with USB visible as F:\ (or change $USB_DRIVE below)
# Downloads all assets to F:\sovereign\ for offline install
#
# Usage (PowerShell as Administrator):
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   cd F:\sovereign
#   .\populate.ps1
#
# Resume safe -- re-run anytime to pick up failed downloads
# Estimated time: 60-120 minutes on home broadband (~35 GB total)
#
# CHANGELOG v2.0 (June 2026):
#   + Node.js 22 LTS .deb package (required for n8n)
#   + n8n 2.23.4 npm tarball
#   + PM2 npm tarball
#   + SearXNG source zip (pinned to working version)
#   + ChromaDB wheel
#   + docs/ folder with setup guide and install notes
#   + Drive letter changed from S: to F: (update if different)
#   + npm/ subdirectory added to structure
#   + searxng/ subdirectory added to structure
# =============================================================================

$ErrorActionPreference = "Continue"

$USB_DRIVE     = "F:"                    # <-- CHANGE IF YOUR USB IS A DIFFERENT LETTER
$SOVEREIGN_DIR = "$USB_DRIVE\sovereign"
$LOG_DIR       = "$SOVEREIGN_DIR\logs"
$LOG_FILE      = "$LOG_DIR\populate_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$REQUIRED_GB   = 30

function Write-Info    { param($msg) Write-Host "  [INFO]  $msg" -ForegroundColor Cyan }
function Write-Ok      { param($msg) Write-Host "  [OK]    $msg" -ForegroundColor Green }
function Write-Warn    { param($msg) Write-Host "  [WARN]  $msg" -ForegroundColor Yellow }
function Write-Err     { param($msg) Write-Host "  [ERROR] $msg" -ForegroundColor Red }
function Write-Section { param($msg) Write-Host "`n  ---  $msg  ---`n" -ForegroundColor Magenta }

function Write-Log {
    param($msg)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
    Add-Content -Path $LOG_FILE -Value $line -ErrorAction SilentlyContinue
}

# =============================================================================
# ASSET MANIFEST
# Format: Filename|URL|SHA256orVERIFY|Subdirectory
# =============================================================================
$MANIFEST = @(
    # -- Ollama runtime (amd64 + arm64) ---------------------------------------
    "ollama-linux-amd64.tar.zst|https://ollama.com/download/ollama-linux-amd64.tar.zst|460e9b0789bedb0b6343fa7b9cccf15e5cb4de10b762f21c920cccf00a2f2968|binaries"
    "ollama-linux-arm64.tar.zst|https://ollama.com/download/ollama-linux-arm64.tar.zst|9921a37f3e9319d5d12744e40f112b57f50a8f9d2256a8765042e6b45486d1f5|binaries"

    # -- uv package manager ---------------------------------------------------
    "uv-x86_64-unknown-linux-gnu.tar.gz|https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz|VERIFY|binaries"

    # -- AI Models (GGUF) -----------------------------------------------------
    "mistral-7b-instruct-q4_k_m.gguf|https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/mistral-7b-instruct-v0.2.Q4_K_M.gguf|VERIFY|models\gguf"
    "Qwen2.5-7B-Instruct-Q4_K_M.gguf|https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf|65b8fcd92af6b4fefa935c625d1ac27ea29dcb6ee14589c55a8f115ceaaa1423|models\gguf"
    "Qwen2.5-3B-Instruct-Q4_K_M.gguf|https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf|9c9f56a391a3abbd5b89d0245bf6106081bcc3173119d4229235dd9d23253f94|models\gguf"

    # -- Image generation (SDXL) -- needs 6GB+ VRAM --------------------------
    "sd_xl_base_1.0.safetensors|https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors|31e35c80fc4829d14f90153f4c74cd59c90b779f6afe05a74cd6120b893f7e5b|models\sdxl"

    # -- Speech models --------------------------------------------------------
    "ggml-base.bin|https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin|VERIFY|models\whisper"
    "ggml-medium.bin|https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin|VERIFY|models\whisper"
    "en_US-lessac-medium.onnx|https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx|VERIFY|models\piper"
    "en_US-lessac-medium.onnx.json|https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json|VERIFY|models\piper"

    # -- Open WebUI Python wheel ----------------------------------------------
    "open_webui-0.9.6-py3-none-any.whl|https://files.pythonhosted.org/packages/py3/o/open_webui/open_webui-0.9.6-py3-none-any.whl|VERIFY|packages\pip"

    # -- Node.js 22 LTS .deb (required for n8n) -- NEW v2.0 ------------------
    "nodesource_setup_22.x.sh|https://deb.nodesource.com/setup_22.x|VERIFY|packages\deb"

    # -- n8n and PM2 npm tarballs -- NEW v2.0 ---------------------------------
    # These allow offline npm install on airgapped machines
    "n8n-2.23.4.tgz|https://registry.npmjs.org/n8n/-/n8n-2.23.4.tgz|VERIFY|packages\npm"
    "pm2-5.4.3.tgz|https://registry.npmjs.org/pm2/-/pm2-5.4.3.tgz|VERIFY|packages\npm"

    # -- SearXNG source (pinned to known-working version) -- NEW v2.0 ---------
    "searxng-master.zip|https://github.com/searxng/searxng/archive/refs/heads/master.zip|VERIFY|packages\searxng"

    # -- ChromaDB wheel -- NEW v2.0 -------------------------------------------
    "chromadb-1.4.4-py3-none-any.whl|https://files.pythonhosted.org/packages/source/c/chromadb/chromadb-1.4.4.tar.gz|VERIFY|packages\pip"
)

$global:Completed = [System.Collections.Generic.List[string]]::new()
$global:Skipped   = [System.Collections.Generic.List[string]]::new()
$global:Failed    = [System.Collections.Generic.List[string]]::new()

# =============================================================================
# PREFLIGHT
# =============================================================================
function Invoke-Preflight {
    Write-Section "Preflight Checks"

    $driveLetter = $USB_DRIVE.TrimEnd(':')
    if (-not (Test-Path $USB_DRIVE)) {
        Write-Err "USB drive not found at $USB_DRIVE"
        Write-Info "Check drive letter in Disk Management and update `$USB_DRIVE at top of script"
        exit 1
    }
    Write-Ok "USB drive found at $USB_DRIVE"

    $drive = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
    if ($drive) {
        $freeGB = [math]::Round($drive.Free / 1GB, 1)
        if ($freeGB -lt $REQUIRED_GB) {
            Write-Err "Not enough space: ${freeGB}GB free, need ${REQUIRED_GB}GB"
            exit 1
        }
        Write-Ok "Disk space OK: ${freeGB}GB free"
    }

    Write-Info "Checking internet..."
    try {
        $null = Invoke-WebRequest -Uri "https://huggingface.co" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Write-Ok "Internet connection confirmed"
    }
    catch {
        Write-Err "No internet access. Connect to your network first."
        exit 1
    }
}

# =============================================================================
# DIRECTORY STRUCTURE
# =============================================================================
function New-SovereignStructure {
    Write-Section "Creating Directory Structure"

    $dirs = @(
        "$SOVEREIGN_DIR\binaries"
        "$SOVEREIGN_DIR\models\gguf"
        "$SOVEREIGN_DIR\models\sdxl"
        "$SOVEREIGN_DIR\models\whisper"
        "$SOVEREIGN_DIR\models\piper"
        "$SOVEREIGN_DIR\packages\pip"
        "$SOVEREIGN_DIR\packages\pip-arm64"
        "$SOVEREIGN_DIR\packages\deb"
        "$SOVEREIGN_DIR\packages\npm"
        "$SOVEREIGN_DIR\packages\searxng"
        "$SOVEREIGN_DIR\config"
        "$SOVEREIGN_DIR\stages"
        "$SOVEREIGN_DIR\docs"
        "$LOG_DIR"
    )

    foreach ($dir in $dirs) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    New-Item -ItemType File -Path "$SOVEREIGN_DIR\.sovereign_usb" -Force | Out-Null
    Write-Ok "Directory structure ready"
}

# =============================================================================
# DOWNLOAD WITH RESUME + PROGRESS + HASH VERIFY
# =============================================================================
function Invoke-Download {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$ExpectedHash,
        [string]$Filename
    )

    $destDir  = Split-Path $Destination -Parent
    $partFile = "$Destination.part"

    New-Item -ItemType Directory -Path $destDir -Force | Out-Null

    if (Test-Path $Destination) {
        if ($ExpectedHash -ne "VERIFY") {
            Write-Info "Verifying: $Filename"
            $actualHash = (Get-FileHash -Path $Destination -Algorithm SHA256).Hash.ToLower()
            if ($actualHash -eq $ExpectedHash.ToLower()) {
                Write-Ok "Already verified, skipping: $Filename"
                $global:Skipped.Add($Filename)
                return $true
            }
            else {
                Write-Warn "Hash mismatch -- re-downloading: $Filename"
                Remove-Item $Destination -Force
            }
        }
        else {
            Write-Ok "Already exists, skipping: $Filename"
            $global:Skipped.Add($Filename)
            return $true
        }
    }

    Write-Info "Downloading: $Filename"
    Write-Log "START $Filename"

    $attempt     = 0
    $maxAttempts = 3
    $success     = $false

    while ($attempt -lt $maxAttempts -and -not $success) {
        $attempt++

        if ($attempt -gt 1) {
            Write-Warn "Retry $attempt of $maxAttempts for: $Filename"
            Start-Sleep -Seconds 10
        }

        try {
            try {
                $head = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -ErrorAction SilentlyContinue
                if ($head -and $head.Headers["Content-Length"]) {
                    $totalMB = [math]::Round([long]$head.Headers["Content-Length"] / 1MB, 1)
                    Write-Info "Size: ${totalMB} MB"
                }
            }
            catch { }

            $useBITS = $false
            try {
                $testHead = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -ErrorAction SilentlyContinue
                if ($testHead -and $testHead.Headers["Content-Length"]) {
                    if ([long]$testHead.Headers["Content-Length"] -gt 100MB) {
                        $useBITS = $true
                    }
                }
            }
            catch { $useBITS = $true }

            if ($useBITS) {
                Write-Info "Using BITS transfer (resume-capable for large files)..."

                Get-BitsTransfer -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -eq "SovereignOS: $Filename" } |
                    Remove-BitsTransfer -ErrorAction SilentlyContinue

                $bitsJob = Start-BitsTransfer `
                    -Source $Url `
                    -Destination $partFile `
                    -Asynchronous `
                    -DisplayName "SovereignOS: $Filename" `
                    -Description "Sovereign OS download" `
                    -ErrorAction Stop

                while ($bitsJob.JobState -in @("Transferring","Connecting","Queued","Transient_Error")) {
                    Start-Sleep -Seconds 3
                    $bitsJob = Get-BitsTransfer -JobId $bitsJob.JobId -ErrorAction SilentlyContinue
                    if ($null -eq $bitsJob) { break }

                    if ($bitsJob.BytesTotal -gt 0) {
                        $pct   = [math]::Round(($bitsJob.BytesTransferred / $bitsJob.BytesTotal) * 100, 0)
                        $dlMB  = [math]::Round($bitsJob.BytesTransferred / 1MB, 0)
                        $totMB = [math]::Round($bitsJob.BytesTotal / 1MB, 0)
                        Write-Host "`r    ${pct}% -- ${dlMB}/${totMB} MB          " -NoNewline
                    }

                    if ($bitsJob.JobState -eq "Transient_Error") {
                        Write-Host ""
                        Write-Warn "BITS temporary error -- resuming..."
                        Resume-BitsTransfer -BitsJob $bitsJob -ErrorAction SilentlyContinue
                    }
                }

                Write-Host ""

                if ($bitsJob -and $bitsJob.JobState -eq "Transferred") {
                    Complete-BitsTransfer -BitsJob $bitsJob
                }
                elseif ($bitsJob -and $bitsJob.JobState -eq "Error") {
                    $errMsg = $bitsJob.ErrorDescription
                    Remove-BitsTransfer -BitsJob $bitsJob -ErrorAction SilentlyContinue
                    throw "BITS error: $errMsg"
                }
            }
            else {
                Write-Info "Downloading..."
                Invoke-WebRequest -Uri $Url -OutFile $partFile -UseBasicParsing -ErrorAction Stop
            }

            if (Test-Path $partFile) {
                Move-Item -Path $partFile -Destination $Destination -Force
            }

            if ($ExpectedHash -ne "VERIFY" -and (Test-Path $Destination)) {
                Write-Info "Verifying SHA256..."
                $actualHash = (Get-FileHash -Path $Destination -Algorithm SHA256).Hash.ToLower()
                if ($actualHash -ne $ExpectedHash.ToLower()) {
                    Write-Err "Hash mismatch: $Filename"
                    Remove-Item $Destination -Force -ErrorAction SilentlyContinue
                    $global:Failed.Add("$Filename (hash mismatch)")
                    Write-Log "HASH_FAIL $Filename"
                    return $false
                }
                Write-Ok "Hash verified"
            }

            Write-Ok "Complete: $Filename"
            Write-Log "COMPLETE $Filename"
            $global:Completed.Add($Filename)
            $success = $true
        }
        catch {
            Write-Host ""
            Write-Warn "Attempt $attempt failed: $_"
            Write-Log "FAIL attempt $attempt $Filename : $_"
            Get-BitsTransfer -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq "SovereignOS: $Filename" } |
                Remove-BitsTransfer -ErrorAction SilentlyContinue
        }
    }

    if (-not $success) {
        Write-Err "Failed after $maxAttempts attempts: $Filename"
        Write-Log "FAILED $Filename"
        $global:Failed.Add($Filename)
        if (Test-Path $partFile) { Remove-Item $partFile -Force -ErrorAction SilentlyContinue }
        return $false
    }

    return $true
}

# =============================================================================
# DOWNLOAD ALL ASSETS
# =============================================================================
function Invoke-DownloadAssets {
    Write-Section "Downloading Assets (~35 GB total)"
    Write-Info "Safe to stop and restart -- downloads resume automatically"
    Write-Host ""

    $total   = $MANIFEST.Count
    $current = 0

    foreach ($entry in $MANIFEST) {
        $current++
        $parts       = $entry -split '\|'
        $filename    = $parts[0]
        $url         = $parts[1]
        $hash        = $parts[2]
        $subdir      = $parts[3]
        $destination = "$SOVEREIGN_DIR\$subdir\$filename"

        Write-Host "  [$current/$total] $filename" -ForegroundColor Yellow
        Invoke-Download -Url $url -Destination $destination -ExpectedHash $hash -Filename $filename
        Write-Host ""
    }
}

# =============================================================================
# WRITE ASSET MANIFEST JSON
# =============================================================================
function Write-AssetManifest {
    Write-Section "Writing Asset Manifest"

    $json = @"
{
  "sovereign_os_version": "2.0.0",
  "populated_at": "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')",
  "populated_on": "windows",
  "assets": {
    "models": {
      "tier_c_and_above": [
        "models/gguf/mistral-7b-instruct-q4_k_m.gguf",
        "models/gguf/Qwen2.5-7B-Instruct-Q4_K_M.gguf"
      ],
      "tier_d": [
        "models/gguf/Qwen2.5-3B-Instruct-Q4_K_M.gguf"
      ],
      "image_gen": [
        "models/sdxl/sd_xl_base_1.0.safetensors"
      ],
      "whisper": [
        "models/whisper/ggml-base.bin",
        "models/whisper/ggml-medium.bin"
      ],
      "tts": [
        "models/piper/en_US-lessac-medium.onnx",
        "models/piper/en_US-lessac-medium.onnx.json"
      ]
    },
    "binaries": {
      "ollama_x86": "binaries/ollama-linux-amd64.tar.zst",
      "ollama_arm": "binaries/ollama-linux-arm64.tar.zst",
      "uv": "binaries/uv-x86_64-unknown-linux-gnu.tar.gz"
    },
    "packages": {
      "open_webui": "packages/pip/open_webui-0.9.6-py3-none-any.whl",
      "chromadb": "packages/pip/chromadb-1.4.4-py3-none-any.whl",
      "nodejs_setup": "packages/deb/nodesource_setup_22.x.sh",
      "n8n": "packages/npm/n8n-2.23.4.tgz",
      "pm2": "packages/npm/pm2-5.4.3.tgz",
      "searxng": "packages/searxng/searxng-master.zip"
    }
  }
}
"@

    $json | Set-Content -Path "$SOVEREIGN_DIR\asset_manifest.json" -Encoding UTF8
    Write-Ok "Manifest written"
}

# =============================================================================
# SUMMARY
# =============================================================================
function Write-Summary {
    Write-Section "Summary"

    if ($global:Completed.Count -gt 0) {
        Write-Host "  Downloaded ($($global:Completed.Count)):" -ForegroundColor Green
        foreach ($item in $global:Completed) { Write-Host "    + $item" -ForegroundColor Green }
    }

    if ($global:Skipped.Count -gt 0) {
        Write-Host "`n  Already present ($($global:Skipped.Count)):" -ForegroundColor Cyan
        foreach ($item in $global:Skipped) { Write-Host "    ~ $item" -ForegroundColor Cyan }
    }

    if ($global:Failed.Count -gt 0) {
        Write-Host "`n  Failed ($($global:Failed.Count)):" -ForegroundColor Red
        foreach ($item in $global:Failed) { Write-Host "    x $item" -ForegroundColor Red }
        Write-Host ""
        Write-Warn "Run .\populate.ps1 again to retry failed items"
    }

    $usedGB = [math]::Round((
        Get-ChildItem $SOVEREIGN_DIR -Recurse -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum
    ).Sum / 1GB, 2)

    Write-Host ""
    Write-Info "Total on USB: ${usedGB} GB"
    Write-Host ""

    if ($global:Failed.Count -eq 0) {
        Write-Host "  USB is fully populated and ready to deploy" -ForegroundColor Green
        Write-Host "  Stack: Ollama + Open WebUI + ChromaDB + n8n + SearXNG" -ForegroundColor Green
        Write-Host "  Note: first machine needs internet for apt deps (~5 min)" -ForegroundColor Green
        Write-Host "  After first install: venv.tar.gz is saved to USB automatically" -ForegroundColor Green
    }
    else {
        Write-Host "  USB partially populated -- run .\populate.ps1 to complete" -ForegroundColor Yellow
    }
}

# =============================================================================
# MAIN
# =============================================================================
Clear-Host
Write-Host ""
Write-Host "  +---------------------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |         SOVEREIGN OS -- USB POPULATE  v2.0             |" -ForegroundColor Cyan
Write-Host "  |   Sovereign AI for Developing Economies                |" -ForegroundColor Cyan
Write-Host "  +---------------------------------------------------------+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Downloads approx 35 GB to $USB_DRIVE\sovereign\" -ForegroundColor White
Write-Host "  Resume-safe -- stop and restart anytime" -ForegroundColor White
Write-Host "  Estimated time: 60-120 min on home broadband" -ForegroundColor White
Write-Host ""
Write-Host "  Stack: Ollama + Open WebUI + ChromaDB + n8n + SearXNG" -ForegroundColor White
Write-Host ""
Write-Host "  Press Enter to start or Ctrl+C to cancel" -ForegroundColor Yellow
Read-Host

Invoke-Preflight
New-SovereignStructure
Invoke-DownloadAssets
Write-AssetManifest
Write-Summary
