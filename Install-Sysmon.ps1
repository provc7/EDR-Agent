#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Automated setup script for Sysmon on Windows.

.DESCRIPTION
    This script automates Sysmon installation:
      1. Downloads the latest Sysmon from Sysinternals.
      2. Writes a hardened sysmon-config.xml (process creation, network, image loads).
      3. Installs Sysmon with the configuration.
      4. Verifies the Sysmon service is running.

.EXAMPLE
    .\Install-Sysmon.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Msg) Write-Host "`n>> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "   [OK] $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "   [WARN] $Msg" -ForegroundColor Yellow }

$InstallDir = "C:\Sysmon"
$ConfigPath = "$InstallDir\sysmon-config.xml"

# -- Step 1: Download Sysmon --------------------------------------------------
Write-Step "Step 1/4 - Downloading Sysmon from Sysinternals"

$ZipUrl  = "https://download.sysinternals.com/files/Sysmon.zip"
$ZipFile = Join-Path $env:TEMP "Sysmon.zip"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipFile -UseBasicParsing
Write-Ok "Downloaded Sysmon.zip"

$ExtractDir = Join-Path $env:TEMP "Sysmon_extract"
if (Test-Path $ExtractDir) { Remove-Item $ExtractDir -Recurse -Force }
Expand-Archive -Path $ZipFile -DestinationPath $ExtractDir -Force

if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
Copy-Item -Path "$ExtractDir\*" -Destination $InstallDir -Recurse -Force
Remove-Item $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $ZipFile    -Force           -ErrorAction SilentlyContinue
Write-Ok "Sysmon extracted to $InstallDir"

# -- Step 2: Write configuration ----------------------------------------------
Write-Step "Step 2/4 - Writing sysmon-config.xml"

$ConfigXml = @"
<Sysmon schemaversion="4.90">
  <HashAlgorithms>md5,sha256,imphash</HashAlgorithms>
  <EventFiltering>

    <!-- Event ID 1: Process Creation -->
    <ProcessCreate onmatch="exclude">
      <Image condition="is">C:\Windows\System32\conhost.exe</Image>
    </ProcessCreate>

    <!-- Event ID 3: Network Connection -->
    <NetworkConnect onmatch="exclude">
      <Image condition="is">C:\Windows\System32\svchost.exe</Image>
    </NetworkConnect>

    <!-- Event ID 7: Image Loaded -->
    <ImageLoad onmatch="include">
      <Signed condition="is">false</Signed>
    </ImageLoad>

    <!-- Event ID 10: Process Access (credential access detection) -->
    <ProcessAccess onmatch="include">
      <TargetImage condition="end with">lsass.exe</TargetImage>
    </ProcessAccess>

    <!-- Event ID 11: File Creation -->
    <FileCreate onmatch="include">
      <TargetFilename condition="end with">.exe</TargetFilename>
      <TargetFilename condition="end with">.dll</TargetFilename>
      <TargetFilename condition="end with">.ps1</TargetFilename>
      <TargetFilename condition="end with">.bat</TargetFilename>
      <TargetFilename condition="end with">.vbs</TargetFilename>
    </FileCreate>

    <!-- Event ID 22: DNS Query -->
    <DnsQuery onmatch="exclude">
      <QueryName condition="end with">.microsoft.com</QueryName>
      <QueryName condition="end with">.windowsupdate.com</QueryName>
    </DnsQuery>

  </EventFiltering>
</Sysmon>
"@

Set-Content -Path $ConfigPath -Value $ConfigXml -Encoding UTF8
Write-Ok "Configuration written to $ConfigPath"

# -- Step 3: Install Sysmon ---------------------------------------------------
Write-Step "Step 3/4 - Installing Sysmon service"

$SysmonExe = "$InstallDir\Sysmon64.exe"
if (-not (Test-Path $SysmonExe)) {
    $SysmonExe = "$InstallDir\Sysmon.exe"
}
if (-not (Test-Path $SysmonExe)) {
    throw "Sysmon executable not found in $InstallDir"
}

# Uninstall existing instance first (idempotent)
$existingSvc = Get-Service -Name "Sysmon*" -ErrorAction SilentlyContinue
if ($existingSvc) {
    Write-Host "   Existing Sysmon service found - removing first ..."
    & $SysmonExe -u force 2>&1 | Out-Null
    Start-Sleep -Seconds 2
}

& $SysmonExe -accepteula -i $ConfigPath
if ($LASTEXITCODE -ne 0) {
    throw "Sysmon installation failed with exit code $LASTEXITCODE"
}
Write-Ok "Sysmon installed with configuration"

# -- Step 4: Verify -----------------------------------------------------------
Write-Step "Step 4/4 - Verifying Sysmon service"

Start-Sleep -Seconds 2
$svc = Get-Service -Name "Sysmon*" -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    Write-Ok "Sysmon is RUNNING — telemetry is active"
} else {
    Write-Warn "Sysmon service status: $($svc.Status) — check Event Viewer for errors"
}

# -- Summary ------------------------------------------------------------------
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Sysmon Setup Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Install path : $InstallDir"
Write-Host "  Config file  : $ConfigPath"
Write-Host "  Service      : $($svc.DisplayName) ($($svc.Status))"
Write-Host "  Events at    : Event Viewer > Microsoft > Windows > Sysmon > Operational"
Write-Host "========================================`n" -ForegroundColor Cyan
