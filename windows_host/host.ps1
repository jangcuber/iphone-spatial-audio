# 켜기 / 끄기 behind the two double-click files.
#   host.ps1 on    : Windows sound -> VB-CABLE -> snaphost -> phones (phones switched to this PC)
#   host.ps1 off   : phones back to the Mac, snaphost stopped, Windows sound back to the previous device
param([string]$Cmd = "on")

$ErrorActionPreference = "Continue"
$Here = $PSScriptRoot
$State = Join-Path $Here "state"; New-Item -ItemType Directory -Force $State | Out-Null
$Logs = Join-Path $Here "logs"; New-Item -ItemType Directory -Force $Logs | Out-Null
$PidFile = Join-Path $State "snaphost.pid"
$PrevFile = Join-Path $State "prev_device.txt"
$Cable = "CABLE Input"

function AudioDev { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Here "audiodev.ps1") @args }
function Phones { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Here "phones.ps1") @args | Out-Host; return $LASTEXITCODE }

function Get-Host {
  if (Test-Path $PidFile) {
    $p = Get-Process -Id (Get-Content $PidFile) -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -like "python*") { return $p }
  }
}

if ($Cmd -eq "on") {
  Write-Host "켜는 중입니다. 폰 7대를 찾아 연결하느라 15초쯤 걸려요. 창을 닫지 마세요..."
  if (-not ((AudioDev list) -match [regex]::Escape($Cable))) { throw "VB-CABLE 이 설치돼 있지 않습니다." }
  $cur = AudioDev get
  if ($cur -notmatch [regex]::Escape($Cable)) { ($cur -split "`t")[1] | Set-Content $PrevFile -Encoding UTF8 }
  if (-not (Get-Host)) {
    $log = Join-Path $Logs ("snaphost_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
    $p = Start-Process python -ArgumentList "-u", "`"$Here\snaphost.py`"" -WindowStyle Hidden -PassThru `
           -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    $p.Id | Set-Content $PidFile
    Start-Sleep 2
    if ($p.HasExited) { Get-Content "$log.err" -Tail 5; throw "송출 프로그램이 바로 멈췄습니다. 로그: $log" }
    "송출 프로그램 시작 (로그: $log)"
  } else { "송출 프로그램은 이미 실행 중" }
  AudioDev set $Cable
  if ((Phones host pc) -ne 0) { "일부 폰을 PC로 돌리지 못했습니다. 위 '실패' 줄을 확인하세요." }
}
elseif ($Cmd -eq "off") {
  Write-Host "끄는 중입니다. 폰 7대를 맥으로 되돌리느라 15초쯤 걸려요. 창을 닫지 마세요..."
  $null = Phones host mac
  $p = Get-Host
  if ($p) { Stop-Process -Id $p.Id -Force; "송출 프로그램 종료" }
  Get-Process volwatch -ErrorAction SilentlyContinue | Stop-Process -Force
  Remove-Item $PidFile -ErrorAction SilentlyContinue
  $prev = if (Test-Path $PrevFile) { (Get-Content $PrevFile -Encoding UTF8 | Select-Object -First 1) } else { "Realtek" }
  AudioDev set $prev
}
Write-Host ""
Write-Host "끝났습니다. 아무 키나 누르면 창이 닫혀요."
