# One-line install (Windows 10/11):
#   irm https://raw.githubusercontent.com/pine-chen/ai-boot-animations/main/codex/windows/web-install.ps1 | iex
# Installs to the non-system drive with the most free space (e.g. D:\AIBootAnimations), C: only as a fallback.
# Pick a folder yourself:  $env:GBA_DIR = 'E:\Apps'; irm ... | iex
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# Shares the repo with the Claude version (which owns releases/latest), so pin the GPT tag here. Bump together with codex/web-install.sh.
$tag = 'gpt-v1.2.5'
$url = "https://github.com/pine-chen/ai-boot-animations/releases/download/$tag/GPTBootAnimation-Windows.zip"
if ($env:GBA_ZIP_URL) { $url = $env:GBA_ZIP_URL }
function Test-Writable([string]$p) {
  try { New-Item -ItemType Directory -Force -Path $p | Out-Null; $f = Join-Path $p ('.w' + [guid]::NewGuid().ToString('N')); [IO.File]::WriteAllText($f, ''); Remove-Item $f -Force; return $true } catch { return $false }
}
$dir = $env:GBA_DIR
if (-not $dir) {
  $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -ne $env:SystemDrive -and $_.FreeSpace -gt 1GB } | Sort-Object FreeSpace -Descending)
  foreach ($d in $disks) { $p = "$($d.DeviceID)\AIBootAnimations"; if (Test-Writable $p) { $dir = $p; break } }
  if (-not $dir) { $dir = "$env:LOCALAPPDATA\Programs" }
}
# Download and unpack next to the install folder, not in C:\...\Temp
$tmp = Join-Path $dir ('.gba-' + [guid]::NewGuid().ToString('N'))
if (-not (Test-Writable $tmp)) { $tmp = Join-Path $env:TEMP ('gba-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $tmp | Out-Null }
try {
  Write-Host "Downloading GPT Boot Animation (~49 MB) -> $dir ..."
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile "$tmp\pkg.zip"
  Expand-Archive -Path "$tmp\pkg.zip" -DestinationPath "$tmp\pkg" -Force
  $inst = "$tmp\pkg\GPTBootAnimation-Windows\install.ps1"
  # Older packages' install.ps1 has no -Dir parameter (they always install to C:)
  if ((Get-Content $inst -Raw) -match '\[string\]\$Dir') {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $inst -Dir $dir
  } else {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $inst
  }
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
