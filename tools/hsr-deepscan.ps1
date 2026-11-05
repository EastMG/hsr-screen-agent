<#
.SYNOPSIS
  Deep scan: for each character on the strip, capture the full attribute panel
  (scrolled, so effect hit / effect res / energy regen are visible) and the
  detail popup of all six relic pieces (main stat + substats).

.DESCRIPTION
  Runs elevated. Only view-only UI: the four view tabs, the attribute-detail
  button, the six relic slot icons, mouse wheel inside the panel, ESC to close.

  Character identity is verified with a name-panel signature so the scan skips
  duplicates caused by list inertia. Each accepted character is written as:
    cNN-detail.png       view tab = detail (name/level, used for identity)
    cNN-stats-top.png    attribute panel, not scrolled
    cNN-stats-bot.png    attribute panel, scrolled down
    cNN-relic1..6.png    relic piece popups
#>
[CmdletBinding()]
param(
  [string] $OutDir = '',
  [int]    $Pages  = 4,
  [int]    $Slots  = 9,
  [int]    $DragPx = 450,
  [int]    $MaxChars = 20
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not ('UiD' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class UiD {
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

[void][UiD]::SetProcessDPIAware()

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot '..\shots\hsr\deep' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$LogPath  = Join-Path $OutDir '_run.log'
$DonePath = Join-Path $OutDir '_done.txt'
if (Test-Path $DonePath) { Remove-Item $DonePath -Force }

function Log([string]$m) {
  Add-Content -LiteralPath $LogPath -Value ('{0} | {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $m) -Encoding UTF8
}

$AVATAR_X  = @(520, 632, 744, 856, 968, 1080, 1192, 1304, 1416)
$AVATAR_Y  = 86
$TAB_DETAIL = @(171, 204)
$TAB_RELIC  = @(171, 486)
$BTN_STATS  = @(1760, 630)
$RELIC_SLOTS = @(
  @(739, 338), @(1161, 417), @(868, 468), @(970, 744), @(677, 778), @(1099, 863)
)
$PANEL_WHEEL = @(1000, 620)
$NAME_X = 1450; $NAME_Y = 178; $NAME_W = 300; $NAME_H = 42; $NAME_TH = 185
$STRIP_TOP = 40; $STRIP_H = 100

function Find-GameWindow {
  $gamePids = @(Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessName -like '*StarRail*' } |
                Select-Object -ExpandProperty Id)
  Log ('process candidates: {0}' -f ($gamePids -join ','))
  $script:found = $null
  $script:best = 0
  $cb = [UiD+EnumWindowsProc]{
    param($h, $l)
    if (-not [UiD]::IsWindowVisible($h)) { return $true }
    $len = [UiD]::GetWindowTextLength($h)
    if ($len -le 0) { return $true }
    $pid2 = 0
    [void][UiD]::GetWindowThreadProcessId($h, [ref] $pid2)
    if ($gamePids -notcontains [int]$pid2) { return $true }
    $r = New-Object UiD+RECT
    [void][UiD]::GetWindowRect($h, [ref] $r)
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
  [void][UiD]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:found
}

$script:win = Find-GameWindow
if (-not $script:win) {
  Log 'ABORT: game window not found'
  Set-Content -LiteralPath $DonePath -Value 'ABORT_NO_WINDOW' -Encoding UTF8
  exit 3
}
Log ('window rect={0},{1} {2}x{3}' -f $script:win.X, $script:win.Y, $script:win.W, $script:win.H)

$script:files = 0

function Focus-Game {
  $h = [IntPtr]$script:win.Hwnd
  if ([UiD]::IsIconic($h)) { [void][UiD]::ShowWindow($h, 9) }
  $pid2 = 0
  $ftid = [UiD]::GetWindowThreadProcessId($h, [ref] $pid2)
  $ctid = [UiD]::GetCurrentThreadId()
  [void][UiD]::AttachThreadInput($ctid, $ftid, $true)
  [void][UiD]::SetForegroundWindow($h)
  [void][UiD]::AttachThreadInput($ctid, $ftid, $false)
  Start-Sleep -Milliseconds 180
}

function Focus-Robust {
  for ($i = 0; $i -lt 6; $i++) {
    Focus-Game
    Start-Sleep -Milliseconds 350
    if ([UiD]::GetForegroundWindow() -eq [IntPtr]$script:win.Hwnd) { return $true }
    Log ('focus retry {0}' -f ($i + 1))
  }
  [void][UiD]::SetCursorPos(($script:win.X + 900), ($script:win.Y + 15))
  Start-Sleep -Milliseconds 150
  [UiD]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [UiD]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 450
  return ([UiD]::GetForegroundWindow() -eq [IntPtr]$script:win.Hwnd)
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

function ClickAt([int]$rx, [int]$ry, [string]$why) {
  if (-not (Focus-Robust)) { Log 'ABORT: lost foreground'; throw 'LOST_FOREGROUND' }
  [void][UiD]::SetCursorPos(($script:win.X + $rx), ($script:win.Y + $ry))
  Start-Sleep -Milliseconds 90
  [UiD]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 70
  [UiD]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 300
  Log ('CLICK {0} rel={1},{2}' -f $why, $rx, $ry)
}

function WheelPanel([int]$notches) {
  if (-not (Focus-Robust)) { throw 'LOST_FOREGROUND' }
  [void][UiD]::SetCursorPos(($script:win.X + $PANEL_WHEEL[0]), ($script:win.Y + $PANEL_WHEEL[1]))
  Start-Sleep -Milliseconds 150
  $delta = [int](120 * $notches)
  if ($delta -lt 0) { $dw = [uint32](4294967296 + [int64]$delta) } else { $dw = [uint32]$delta }
  [UiD]::mouse_event(0x0800, 0, 0, $dw, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 550
  Log ('WHEEL notches={0}' -f $notches)
}

# The attribute-detail panel swallows synthetic wheel events, so scroll it by
# dragging the panel's own scrollbar thumb instead.
function ScrollStatsPanel {
  if (-not (Focus-Robust)) { throw 'LOST_FOREGROUND' }
  $x  = $script:win.X + 1457
  $y1 = $script:win.Y + 415
  $y2 = $script:win.Y + 800
  [void][UiD]::SetCursorPos($x, $y1)
  Start-Sleep -Milliseconds 200
  [UiD]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 150
  for ($t = 1; $t -le 12; $t++) {
    $y = [int]($y1 + ($y2 - $y1) * $t / 12)
    [void][UiD]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 40
  }
  Start-Sleep -Milliseconds 200
  [UiD]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 600
  Log 'SCROLLBAR drag done'
}

function Send-Esc {
  if (-not (Focus-Robust)) { throw 'LOST_FOREGROUND' }
  [UiD]::keybd_event(0x1B, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [UiD]::keybd_event(0x1B, 0, 2, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 400
  Log 'ESC'
}

function DragStrip([int]$x1, [int]$x2, [int]$y, [string]$why) {
  if (-not (Focus-Robust)) { throw 'LOST_FOREGROUND' }
  [void][UiD]::SetCursorPos(($script:win.X + $x1), ($script:win.Y + $y))
  Start-Sleep -Milliseconds 140
  [UiD]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 120
  $steps = 14
  for ($t = 1; $t -le $steps; $t++) {
    $cx = [int]($x1 + (($x2 - $x1) * $t / $steps))
    [void][UiD]::SetCursorPos(($script:win.X + $cx), ($script:win.Y + $y))
    Start-Sleep -Milliseconds 35
  }
  Start-Sleep -Milliseconds 150
  [UiD]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
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
  Log ('start deep pages={0} slots={1} dragPx={2} maxChars={3}' -f $Pages, $Slots, $DragPx, $MaxChars)

  # clamp the strip back to its leftmost position before enumerating
  for ($h = 0; $h -lt 10; $h++) { DragStrip (1420 - $DragPx) 1420 $AVATAR_Y ('home{0}' -f $h) }

  $idx = 0
  $prevName = $null

  for ($pg = 1; $pg -le $Pages; $pg++) {
    if ($pg -gt 1) {
      DragStrip 1420 (1420 - $DragPx) $AVATAR_Y ('page{0}' -f $pg)
    }

    for ($s = 1; $s -le $Slots; $s++) {
      if ($idx -ge $MaxChars) { break }
      $baseX = $AVATAR_X[$s - 1]
      $tries = @(0, 45, -45, 90)
      $accepted = $false
      foreach ($off in $tries) {
        ClickAt ($baseX + $off) $AVATAR_Y ('p{0}s{1}o{2}' -f $pg, $s, $off)
        Start-Sleep -Milliseconds 900
        ClickAt $TAB_DETAIL[0] $TAB_DETAIL[1] 'tab:detail(ident)'
        Start-Sleep -Milliseconds 600
        $mask = Get-NameMask
        $d = Mask-Dist $prevName $mask
        if ($null -ne $prevName -and $d -lt 100) {
          Start-Sleep -Milliseconds 700
          $mask2 = Get-NameMask
          $d2 = Mask-Dist $prevName $mask2
          Log ('RECHECK p{0}s{1} off{2} h={3} -> {4}' -f $pg, $s, $off, $d2, $d2)
          if ($d2 -lt 100) {
            Log ('DUPLICATE p{0}s{1} off{2}' -f $pg, $s, $off)
            continue
          }
          $mask = $mask2; $d = $d2
        }
        $prevName = $mask
        $accepted = $true
        break
      }
      if (-not $accepted) { Log ('SKIP p{0}s{1}' -f $pg, $s); continue }

      $idx++
      $nn = 'c{0:D2}' -f $idx
      Log ('ACCEPT {0} p{1}s{2}' -f $nn, $pg, $s)

      ClickAt $TAB_DETAIL[0] $TAB_DETAIL[1] 'tab:detail'
      Start-Sleep -Milliseconds 550
      Grab ('{0}-detail' -f $nn) | Out-Null

      ClickAt $BTN_STATS[0] $BTN_STATS[1] 'btn:stats'
      Start-Sleep -Milliseconds 900
      Grab ('{0}-stats-top' -f $nn) | Out-Null
      ScrollStatsPanel
      Grab ('{0}-stats-bot' -f $nn) | Out-Null
      Send-Esc
      Start-Sleep -Milliseconds 350

      ClickAt $TAB_RELIC[0] $TAB_RELIC[1] 'tab:relic'
      Start-Sleep -Milliseconds 850
      for ($r = 0; $r -lt $RELIC_SLOTS.Count; $r++) {
        ClickAt $RELIC_SLOTS[$r][0] $RELIC_SLOTS[$r][1] ('relic{0}' -f ($r + 1))
        Start-Sleep -Milliseconds 800
        Grab ('{0}-relic{1}' -f $nn, ($r + 1)) | Out-Null
        Send-Esc
        Start-Sleep -Milliseconds 300
      }
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
