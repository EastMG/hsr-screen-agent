<#
.SYNOPSIS
  Second deep pass: attribute panel scrolled by touch-style drag, plus the
  soul (eidolon) page.

.DESCRIPTION
  The attribute-detail panel ignores synthetic mouse wheel and scrollbar drags,
  but it does accept a touch-style drag inside its content area (press, drag up,
  release). This pass uses that to reveal the lower rows (effect hit / effect res
  / energy regen), and also captures the 星魂 page.

  Per character: detail (identity) / stats-top / stats-scrolled / soul page.
#>
[CmdletBinding()]
param(
  [string] $OutDir = '',
  [int]    $Pages  = 3,
  [int]    $Slots  = 9,
  [int]    $DragPx = 450,
  [int]    $MaxChars = 18,
  [string] $SeenFile = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not ('UiS' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class UiS {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint data, IntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, IntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
}

[void][UiS]::SetProcessDPIAware()

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot '..\shots\hsr\stats' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$LogPath  = Join-Path $OutDir '_run.log'
$DonePath = Join-Path $OutDir '_done.txt'
if (Test-Path $DonePath) { Remove-Item $DonePath -Force }

function Log([string]$m) {
  Add-Content -LiteralPath $LogPath -Value ('{0} | {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $m) -Encoding UTF8
}

$AVATAR_X   = @(520, 632, 744, 856, 968, 1080, 1192, 1304, 1416)
$AVATAR_Y   = 86
$TAB_DETAIL = @(171, 204)
$TAB_SOUL   = @(171, 581)
$BTN_STATS  = @(1760, 630)
$NAME_X = 1450; $NAME_Y = 178; $NAME_W = 300; $NAME_H = 42; $NAME_TH = 185
$STRIP_TOP = 40; $STRIP_H = 100

function Find-GameWindow {
  $gamePids = @(Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessName -like '*StarRail*' } |
                Select-Object -ExpandProperty Id)
  Log ('process candidates: {0}' -f ($gamePids -join ','))
  $script:found = $null
  $script:best = 0
  $cb = [UiS+EnumWindowsProc]{
    param($h, $l)
    if (-not [UiS]::IsWindowVisible($h)) { return $true }
    $len = [UiS]::GetWindowTextLength($h)
    if ($len -le 0) { return $true }
    $pid2 = 0
    [void][UiS]::GetWindowThreadProcessId($h, [ref] $pid2)
    if ($gamePids -notcontains [int]$pid2) { return $true }
    $r = New-Object UiS+RECT
    [void][UiS]::GetWindowRect($h, [ref] $r)
    $area = ($r.Right - $r.Left) * ($r.Bottom - $r.Top)
    if ($area -gt $script:best) {
      $script:best = $area
      $script:found = [pscustomobject]@{
        Hwnd = [int64]$h; Pid = [int]$pid2
        X = $r.Left; Y = $r.Top; W = ($r.Right - $r.Left); H = ($r.Bottom - $r.Top)
      }
    }
    return $true
  }
  [void][UiS]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:found
}

$script:win = Find-GameWindow
if (-not $script:win) {
  Log 'ABORT: game window not found'
  Set-Content -LiteralPath $DonePath -Value 'ABORT_NO_WINDOW' -Encoding UTF8
  exit 3
}
Log ('window rect={0},{1} {2}x{3}' -f $script:win.X, $script:win.Y, $script:win.W, $script:win.H)

$script:seen = @()
if ($SeenFile -and (Test-Path -LiteralPath $SeenFile)) {
  foreach ($line in Get-Content -LiteralPath $SeenFile) {
    $s = $line.Trim()
    if ($s) { $script:seen += ,([Convert]::FromBase64String($s)) }
  }
}
Log ('seen masks loaded: {0}' -f $script:seen.Count)

$script:files = 0

function Focus-Game {
  $h = [IntPtr]$script:win.Hwnd
  if ([UiS]::IsIconic($h)) { [void][UiS]::ShowWindow($h, 9) }
  $pid2 = 0
  $ftid = [UiS]::GetWindowThreadProcessId($h, [ref] $pid2)
  $ctid = [UiS]::GetCurrentThreadId()
  [void][UiS]::AttachThreadInput($ctid, $ftid, $true)
  [void][UiS]::SetForegroundWindow($h)
  [void][UiS]::AttachThreadInput($ctid, $ftid, $false)
  Start-Sleep -Milliseconds 180
}

function Focus-Robust {
  for ($i = 0; $i -lt 6; $i++) {
    Focus-Game
    Start-Sleep -Milliseconds 350
    if ([UiS]::GetForegroundWindow() -eq [IntPtr]$script:win.Hwnd) { return $true }
    Log ('focus retry {0}' -f ($i + 1))
  }
  [void][UiS]::SetCursorPos(($script:win.X + 900), ($script:win.Y + 15))
  Start-Sleep -Milliseconds 150
  [UiS]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [UiS]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 450
  return ([UiS]::GetForegroundWindow() -eq [IntPtr]$script:win.Hwnd)
}

function Grab([string]$tag) {
  $bmp = New-Object System.Drawing.Bitmap($script:win.W, $script:win.H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try { $g.CopyFromScreen($script:win.X, $script:win.Y, 0, 0, (New-Object System.Drawing.Size($script:win.W, $script:win.H))) }
  finally { $g.Dispose() }
  $file = Join-Path $OutDir ('{0}.png' -f $tag)
  $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  $script:files++
  return $file
}

function Get-NameMask {
  $bmp = New-Object System.Drawing.Bitmap($NAME_W, $NAME_H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try { $g.CopyFromScreen(($script:win.X + $NAME_X), ($script:win.Y + $NAME_Y), 0, 0, (New-Object System.Drawing.Size($NAME_W, $NAME_H))) }
  finally { $g.Dispose() }
  $mask = New-Object byte[] ($NAME_W * $NAME_H)
  $i = 0
  for ($y = 0; $y -lt $NAME_H; $y++) {
    for ($x = 0; $x -lt $NAME_W; $x++) {
      $px = $bmp.GetPixel($x, $y)
      $lum = ($px.R * 299 + $px.G * 587 + $px.B * 114) / 1000
      if ($lum -ge $NAME_TH) { $mask[$i] = 1 }
      $i++
    }
  }
  $bmp.Dispose()
  return ,$mask
}

function Mask-Dist($a, $b) {
  if ($null -eq $a -or $null -eq $b) { return 99999 }
  $h = 0
  for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { $h++ } }
  return $h
}

function Get-Sig([int]$rx, [int]$ry, [int]$rw, [int]$rh, [int]$cols, [int]$rows) {
  $bmp = New-Object System.Drawing.Bitmap($rw, $rh)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try { $g.CopyFromScreen(($script:win.X + $rx), ($script:win.Y + $ry), 0, 0, (New-Object System.Drawing.Size($rw, $rh))) }
  finally { $g.Dispose() }
  $small = New-Object System.Drawing.Bitmap($cols, $rows)
  $g2 = [System.Drawing.Graphics]::FromImage($small)
  $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
  $g2.DrawImage($bmp, 0, 0, $cols, $rows)
  $g2.Dispose(); $bmp.Dispose()
  $vals = New-Object int[] ($cols * $rows)
  $i = 0
  for ($y = 0; $y -lt $rows; $y++) {
    for ($x = 0; $x -lt $cols; $x++) {
      $p = $small.GetPixel($x, $y)
      $vals[$i] = [int](($p.R * 299 + $p.G * 587 + $p.B * 114) / 1000)
      $i++
    }
  }
  $small.Dispose()
  return ,$vals
}

function Sig-Delta($a, $b) {
  if ($null -eq $a -or $null -eq $b) { return 99999 }
  $s = 0
  for ($i = 0; $i -lt $a.Length; $i++) { $s += [Math]::Abs($a[$i] - $b[$i]) }
  return $s
}

function ClickAt([int]$rx, [int]$ry, [string]$why) {
  if (-not (Focus-Robust)) { Log 'ABORT: lost foreground'; throw 'LOST_FOREGROUND' }
  [void][UiS]::SetCursorPos(($script:win.X + $rx), ($script:win.Y + $ry))
  Start-Sleep -Milliseconds 90
  [UiS]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 70
  [UiS]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 300
  Log ('CLICK {0} rel={1},{2}' -f $why, $rx, $ry)
}

# touch-style scroll: press inside the panel content, drag upward, release
function DragPanelUp([int]$x, [int]$y1, [int]$y2) {
  if (-not (Focus-Robust)) { throw 'LOST_FOREGROUND' }
  $sx = $script:win.X + $x
  [void][UiS]::SetCursorPos($sx, ($script:win.Y + $y1))
  Start-Sleep -Milliseconds 200
  [UiS]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 160
  $steps = 16
  for ($t = 1; $t -le $steps; $t++) {
    $yy = [int]($y1 + ($y2 - $y1) * $t / $steps)
    [void][UiS]::SetCursorPos($sx, ($script:win.Y + $yy))
    Start-Sleep -Milliseconds 45
  }
  Start-Sleep -Milliseconds 220
  [UiS]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 700
  Log ('PANEL DRAG {0}->{1}' -f $y1, $y2)
}

function Send-Esc {
  if (-not (Focus-Robust)) { throw 'LOST_FOREGROUND' }
  [UiS]::keybd_event(0x1B, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [UiS]::keybd_event(0x1B, 0, 2, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 450
  Log 'ESC'
}

function DragStrip([int]$x1, [int]$x2, [int]$y, [string]$why) {
  if (-not (Focus-Robust)) { throw 'LOST_FOREGROUND' }
  [void][UiS]::SetCursorPos(($script:win.X + $x1), ($script:win.Y + $y))
  Start-Sleep -Milliseconds 140
  [UiS]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 120
  $steps = 14
  for ($t = 1; $t -le $steps; $t++) {
    $cx = [int]($x1 + (($x2 - $x1) * $t / $steps))
    [void][UiS]::SetCursorPos(($script:win.X + $cx), ($script:win.Y + $y))
    Start-Sleep -Milliseconds 35
  }
  Start-Sleep -Milliseconds 150
  [UiS]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Log ('DRAG {0} {1}->{2}' -f $why, $x1, $x2)

  $prev = $null
  for ($round = 0; $round -lt 7; $round++) {
    Start-Sleep -Milliseconds 650
    $sig = Get-Sig 0 $STRIP_TOP $script:win.W $STRIP_H 32 6
    $d = Sig-Delta $prev $sig
    Log ('SETTLE round={0} diff={1}' -f ($round + 1), $d)
    if ($null -ne $prev -and $d -lt 120) { return }
    $prev = $sig
  }
}

try {
  Log ('start statsdeep pages={0} slots={1} dragPx={2} maxChars={3}' -f $Pages, $Slots, $DragPx, $MaxChars)

  for ($h = 0; $h -lt 10; $h++) { DragStrip (1420 - $DragPx) 1420 $AVATAR_Y ('home{0}' -f $h) }

  $idx = 0
  $prevName = $null

  for ($pg = 1; $pg -le $Pages; $pg++) {
    if ($pg -gt 1) { DragStrip 1420 (1420 - $DragPx) $AVATAR_Y ('page{0}' -f $pg) }

    for ($s = 1; $s -le $Slots; $s++) {
      if ($idx -ge $MaxChars) { break }
      $baseX = $AVATAR_X[$s - 1]
      $tries = @(0, 45, -45, 90)
      $accepted = $false
      foreach ($off in $tries) {
        ClickAt ($baseX + $off) $AVATAR_Y ('p{0}s{1}o{2}' -f $pg, $s, $off)
        Start-Sleep -Milliseconds 650
        ClickAt $TAB_DETAIL[0] $TAB_DETAIL[1] 'tab:detail(ident)'
        Start-Sleep -Milliseconds 600
        $mask = Get-NameMask
        $d = Mask-Dist $prevName $mask
        if ($script:seen.Count -gt 0) {
          $hit = $false
          foreach ($sm in $script:seen) { if ((Mask-Dist $sm $mask) -lt 100) { $hit = $true; break } }
          if ($hit) { Log ('ALREADY_SEEN p{0}s{1} off{2}' -f $pg, $s, $off); continue }
        }
        if ($null -ne $prevName -and $d -lt 100) {
          Start-Sleep -Milliseconds 700
          $mask2 = Get-NameMask
          $d2 = Mask-Dist $prevName $mask2
          Log ('RECHECK p{0}s{1} off{2} h={3}' -f $pg, $s, $off, $d2)
          if ($d2 -lt 100) { Log ('DUPLICATE p{0}s{1} off{2}' -f $pg, $s, $off); continue }
          $mask = $mask2
        }
        $prevName = $mask
        $accepted = $true
        break
      }
      if (-not $accepted) { Log ('SKIP p{0}s{1}' -f $pg, $s); continue }

      $idx++
      $nn = 's{0:D2}' -f $idx
      Log ('ACCEPT {0} p{1}s{2}' -f $nn, $pg, $s)

      Grab ('{0}-detail' -f $nn) | Out-Null

      ClickAt $BTN_STATS[0] $BTN_STATS[1] 'btn:stats'
      Start-Sleep -Milliseconds 950
      Grab ('{0}-stats-top' -f $nn) | Out-Null

      DragPanelUp 900 740 380
      DragPanelUp 900 740 380
      Grab ('{0}-stats-bot' -f $nn) | Out-Null
      Send-Esc
      Start-Sleep -Milliseconds 350

      ClickAt $TAB_SOUL[0] $TAB_SOUL[1] 'tab:soul'
      Start-Sleep -Milliseconds 800
      Grab ('{0}-soul' -f $nn) | Out-Null

      ClickAt $TAB_DETAIL[0] $TAB_DETAIL[1] 'tab:detail(reset)'
      Start-Sleep -Milliseconds 350
      Log ('char {0} done' -f $nn)
    }
    if ($idx -ge $MaxChars) { break }
  }

  for ($i = 1; $i -le $Pages; $i++) { DragStrip (1420 - $DragPx) 1420 $AVATAR_Y ('restore{0}' -f $i) }

  Log ('DONE files={0} chars={1}' -f $script:files, $idx)
  Set-Content -LiteralPath $DonePath -Value ('OK files={0} chars={1}' -f $script:files, $idx) -Encoding UTF8
  exit 0
}
catch {
  Log ('ERROR: {0}' -f $_.Exception.Message)
  Set-Content -LiteralPath $DonePath -Value ('ERROR ' + $_.Exception.Message) -Encoding UTF8
  exit 1
}
