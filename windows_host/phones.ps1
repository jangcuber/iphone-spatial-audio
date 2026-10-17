# Points the phones' snapclient at the PC or back at the Mac, over SSH (Wi-Fi).
#   phones.ps1 status
#   phones.ps1 host pc        # phones listen to this PC
#   phones.ps1 host mac       # phones listen to the Mac again
#   phones.ps1 addkey         # put this PC's SSH key on reachable phones (asks the phone password)
# Phone addresses come from DHCP and change, so phones are found by scanning the Wi-Fi subnet
# for SSH and reading NAME/CHANNEL from each phone's snapclient.conf. Last result: phones.txt.
param([string]$Cmd = "status", [string]$Target = "")

$ErrorActionPreference = "Continue"
$Here = $PSScriptRoot
$State = Join-Path $Here "state"; New-Item -ItemType Directory -Force $State | Out-Null
# Mac address/IP come from config.json ("mac_wifi_mac" like "aa-bb-cc-dd-ee-ff", "mac_ip"); either may be empty
$Cfg = Get-Content (Join-Path $Here "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$MacHw = "$($Cfg.mac_wifi_mac)".ToLower().Replace(":", "-")
$MacIpFile = Join-Path $State "mac_ip.txt"
$User = "mobile"
$Key = Join-Path $env:USERPROFILE ".ssh\id_ed25519_phones"
$Conf = "/var/jb/etc/snapclient.conf"
$SshArgs = "-n -i `"$Key`" -o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new"

function Get-PcIP {
  $i = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "Wi-Fi" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $i -or $i.IPAddress -notmatch '^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)') { throw "이 PC가 집 Wi-Fi에 있지 않습니다." }
  return $i.IPAddress
}

function Start-Ssh([string]$addr, [string]$cmd) {
  $psi = New-Object Diagnostics.ProcessStartInfo "ssh.exe", "$SshArgs $User@$addr `"$($cmd -replace '"','\"')`""
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $p = [Diagnostics.Process]::Start($psi)
  [pscustomobject]@{ Addr = $addr; P = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
}

function Wait-Ssh($runs) {
  foreach ($r in $runs) {
    if (-not $r.P.WaitForExit(20000)) { try { $r.P.Kill() } catch {} ; $r.P.WaitForExit(2000) | Out-Null }
    $r | Add-Member Text (($r.Out.Result + " " + $r.Err.Result).Trim()) -PassThru | Add-Member Code $r.P.ExitCode -PassThru
  }
}

function Find-Phones {
  Write-Host "  폰 찾는 중..."
  $pc = Get-PcIP
  $net = $pc -replace '\.\d+$', ''
  $probes = 2..254 | ForEach-Object {
    $c = New-Object Net.Sockets.TcpClient
    [pscustomobject]@{ Addr = "$net.$_"; C = $c; T = $c.ConnectAsync("$net.$_", 22) }
  }
  Start-Sleep -Milliseconds 3000
  $open = foreach ($p in $probes) { if ($p.T.IsCompleted -and -not $p.T.IsFaulted -and $p.C.Connected) { $p.Addr }; $p.C.Close() }
  # phones that answered last time are asked again even if this quick probe missed them (slow to wake)
  $cache = Join-Path $Here "phones.txt"
  if (Test-Path $cache) { $open = @($open) + @(Get-Content $cache | Select-String '(\d+\.\d+\.\d+\.\d+)' | ForEach-Object { $_.Matches[0].Value }) | Select-Object -Unique }
  $runs = foreach ($a in $open) { Start-Ssh $a "grep -E '^(NAME|CHANNEL|SERVER)=' $Conf" }
  $found = foreach ($r in (Wait-Ssh $runs)) {
    if ($r.Code -ne 0) { continue }
    $v = @{}; foreach ($m in [regex]::Matches($r.Text, "(NAME|CHANNEL|SERVER)='?([^'\s]+)'?")) { $v[$m.Groups[1].Value] = $m.Groups[2].Value }
    if ($v.NAME) { [pscustomobject]@{ Name = $v.NAME; Channel = $v.CHANNEL; Addr = $r.Addr; Server = $v.SERVER } }
  }
  $found = $found | Sort-Object Name
  $names = "FL", "FR", "C", "SL", "SR", "HL", "HR"
  $lines = @("# found by phones.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')") + ($found | ForEach-Object { "{0} {1} {2}" -f $_.Name, $names[[int]$_.Channel], $_.Addr })
  # keep the last known address of phones not found this time
  if (Test-Path $cache) { $lines += Get-Content $cache | Where-Object { $_ -match '^(node-\d+)\s' -and $Matches[1] -notin $found.Name } }
  $lines | Set-Content $cache -Encoding UTF8
  return $found
}

function Get-MacIP {
  # the sweep in Find-Phones fills the ARP table; look the Mac up by its Wi-Fi address
  $hit = if ($MacHw) { arp -a | Select-String $MacHw | Select-Object -First 1 }
  if ($hit) { $ip = ($hit.Line.Trim() -split '\s+')[0]; $ip | Set-Content $MacIpFile; return $ip }
  if (Test-Path $MacIpFile) { return (Get-Content $MacIpFile | Select-Object -First 1) }
  if ($Cfg.mac_ip) { return $Cfg.mac_ip }
  throw "Mac IP를 모릅니다. config.json의 mac_ip(또는 mac_wifi_mac)를 채우세요."
}

$All = "node-01", "node-02", "node-03", "node-04", "node-05", "node-06", "node-07"

switch ($Cmd) {
  "status" {
    $f = Find-Phones
    foreach ($p in $f) { "{0,-8} CH{1}  {2,-15} SERVER={3}" -f $p.Name, $p.Channel, $p.Addr, $p.Server }
    $miss = $All | Where-Object { $_ -notin $f.Name }
    if ($miss) { "못 찾은 폰: $($miss -join ', ')" }
  }
  "host" {
    $f = Find-Phones
    $ip = if ($Target -eq "mac") { Get-MacIP } elseif ($Target -eq "pc") { Get-PcIP } else { throw "host pc 또는 host mac" }
    # Same steps the Mac uses. The saved clock-sync floor must be cleared on every server switch.
    $remote = "export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:`$PATH; " +
              "grep -Eq `"^SERVER='?$ip'?`$`" $Conf && echo same && exit 0; " +
              "rm -f /var/mobile/Library/Caches/snapclient_rttfloor; " +
              "sudo -n snapclient-ctl set SERVER=$ip >/dev/null && sudo -n snapclient-ctl restart >/dev/null 2>&1; grep '^SERVER=' $Conf"
    $runs = foreach ($p in $f) { Start-Ssh $p.Addr $remote | Add-Member Name $p.Name -PassThru }
    $bad = 0
    foreach ($r in (Wait-Ssh $runs)) {
      $ok = $r.Text -match ("SERVER='?" + [regex]::Escape($ip) + "|\bsame\b")
      if (-not $ok) { $bad++ }
      "{0,-8} {1}" -f $r.Name, $(if ($ok) { "OK" } else { "실패: $($r.Text)" })
    }
    $miss = $All | Where-Object { $_ -notin $f.Name }
    if ($miss) { "못 찾은 폰: $($miss -join ', ')" }
    "폰 $(@($f).Count)대 → $Target ($ip)"
    if ($bad) { exit 1 }
  }
  "addkey" {
    $pub = (Get-Content "$Key.pub" -Raw).Trim()
    $pc = Get-PcIP; $net = $pc -replace '\.\d+$', ''
    foreach ($a in ($Target -split ',')) {
      if (-not $a) { continue }
      $addr = if ($a -match '^\d+$') { "$net.$a" } else { $a }
      "== $addr : 폰 비밀번호를 물으면 입력하세요"
      & ssh -o StrictHostKeyChecking=accept-new "$User@$addr" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && (grep -qF '$pub' ~/.ssh/authorized_keys 2>/dev/null || echo '$pub' >> ~/.ssh/authorized_keys) && chmod 600 ~/.ssh/authorized_keys && echo key-ok"
    }
  }
  default { throw "status | host pc | host mac | addkey <ip,...>" }
}
