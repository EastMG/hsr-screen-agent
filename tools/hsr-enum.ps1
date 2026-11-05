<#
.SYNOPSIS
  Robust roster enumeration: waits for list inertia to settle, verifies each
  click actually changed character, and jitters+retries on duplicates.

.DESCRIPTION
  Runs elevated (game manifest requires admin; UIPI blocks lower-integrity input).

  Fixes observed in an earlier pass: after a horizontal drag the avatar strip keeps
  coasting, so clicking fixed slots immediately produced duplicate captures
  (same character 3-4 times) and skipped others.

  Guards:
    * after every drag: wait, then compare two strip signatures 250ms apart;
      keep waiting while the strip is still moving (max 6 rounds)
    * after every click: compare the right-hand name panel signature with the
      previous one; if unchanged, jitter the click (+-45 / +-90 px) and retry
    * never clicks the rightmost clipped slot (it auto-scrolls the strip)
#>
[CmdletBinding()]
param(
  [string] $OutDir = '',
  [int]    $Pages  = 6,
  [int]    $Slots  = 9,
  [int]    $DragPx = 450
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not ('UiE' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class UiE {
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
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
}

[void][UiE]::SetProcessDPIAware()

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot '..\shots\hsr\enum' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$LogPath = Join-Path $OutDir '_run.log'
$DonePath = Join-Path $OutDir '_done.txt'
if (Test-Path $DonePath) { Remove-Item $DonePath -Force }

function Log([string]$m) {
  Add-Content -LiteralPath $LogPath -Value ('{0} | {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $m) -Encoding UTF8
}

$AVATAR_X  = @(520, 632, 744, 856, 968, 1080, 1192, 1304, 1416)
$AVATAR_Y  = 86
$TAB_DETAIL = @(171, 204)
$STRIP_TOP = 40
$STRIP_H   = 100
$NAME_X    = 1420
$NAME_Y    = 165
$NAME_W    = 500
$NAME_H    = 50

function Find-GameWindow {
  $gamePids = @(Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessName -like '*StarRail*' } |
                Select-Object -ExpandProperty Id)
  Log ('process candidates: {0}' -f ($gamePids -join ','))
  $script:found = $null
  $script:best = 0
  $cb = [UiE+EnumWindowsProc]{
    param($h, $l)
    if (-not [UiE]::IsWindowVisible($h)) { return $true }
    $len = [UiE]::GetWindowTextLength($h)
    if ($len -le 0) { return $true }
    $pid2 = 0
    [void][UiE]::GetWindowThreadProcessId($h, [ref] $pid2)
    if ($gamePids -notcontains [int]$pid2) { return $true }
    $r = New-Object UiE+RECT
    [void][UiE]::GetWindowRect($h, [ref] $r)
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
  [void][UiE]::EnumWindows($cb, [IntPtr]::Zero)
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
  if ([UiE]::IsIconic($h)) { [void][UiE]::ShowWindow($h, 9) }
  $pid2 = 0
  $ftid = [UiE]::GetWindowThreadProcessId($h, [ref] $pid2)
  $ctid = [UiE]::GetCurrentThreadId()
  [void][UiE]::AttachThreadInput($ctid, $ftid, $true)
  [void][UiE]::SetForegroundWindow($h)
  [void][UiE]::AttachThreadInput($ctid, $ftid, $false)
  Start-Sleep -Milliseconds 180
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

function Sig-Diff($a, $b) {
  if ($null -eq $a -or $null -eq $b) { return 99999 }
  $sum = 0
  for ($i = 0; $i -lt $a.Length; $i++) { $sum += [Math]::Abs($a[$i] - $b[$i]) }
  return $sum
}

function Focus-Robust {
  for ($i = 0; $i -lt 6; $i++) {
    Focus-Game
    Start-Sleep -Milliseconds 350
    if ([UiE]::GetForegroundWindow() -eq [IntPtr]$script:win.Hwnd) { return $true }
    Log ('focus retry {0}' -f ($i + 1))
  }
  # last resort: click the window title bar (focuses without activating in-game UI)
  [void][UiE]::SetCursorPos(($script:win.X + 900), ($script:win.Y + 15))
  Start-Sleep -Milliseconds 150
  [UiE]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [UiE]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 450
  Log ('focus titlebar fallback fg-ok={0}' -f ([UiE]::GetForegroundWindow() -eq [IntPtr]$script:win.Hwnd))
  return ([UiE]::GetForegroundWindow() -eq [IntPtr]$script:win.Hwnd)
}

function ClickAt([int]$rx, [int]$ry, [string]$why) {
  if (-not (Focus-Robust)) { Log 'ABORT: lost foreground'; throw 'LOST_FOREGROUND' }
  [void][UiE]::SetCursorPos(($script:win.X + $rx), ($script:win.Y + $ry))
  Start-Sleep -Milliseconds 90
  [UiE]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 70
  [UiE]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 320
  Log ('CLICK {0} rel={1},{2}' -f $why, $rx, $ry)
}

function DragStrip([int]$x1, [int]$x2, [int]$y, [string]$why) {
  Focus-Game
  [void][UiE]::SetCursorPos(($script:win.X + $x1), ($script:win.Y + $y))
  Start-Sleep -Milliseconds 140
  [UiE]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 120
  $steps = 14
  for ($t = 1; $t -le $steps; $t++) {
    $cx = [int]($x1 + (($x2 - $x1) * $t / $steps))
    [void][UiE]::SetCursorPos(($script:win.X + $cx), ($script:win.Y + $y))
    Start-Sleep -Milliseconds 35
  }
  Start-Sleep -Milliseconds 150
  [UiE]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Log ('DRAG {0} {1}->{2}' -f $why, $x1, $x2)

  # wait until the strip stops coasting (inertia)
  $prev = $null
  for ($round = 0; $round -lt 6; $round++) {
    Start-Sleep -Milliseconds 650
    $sig = Get-Sig 0 $STRIP_TOP $script:win.W $STRIP_H 32 6
    $d = Sig-Diff $prev $sig
    Log ('SETTLE round={0} diff={1}' -f ($round + 1), $d)
    if ($null -ne $prev -and $d -lt 120) { return }
    $prev = $sig
  }
  Log 'SETTLE gave up after 6 rounds'
}

try {
  Focus-Game
  Log ('start enum pages={0} slots={1}' -f $Pages, $Slots)

  ClickAt $TAB_DETAIL[0] $TAB_DETAIL[1] 'tab:detail'
  Start-Sleep -Milliseconds 500

  $seen = 0
  $dups = 0

  for ($pg = 1; $pg -le $Pages; $pg++) {
    if ($pg -gt 1) {
      DragStrip 1420 (1420 - $DragPx) $AVATAR_Y ('page{0}' -f $pg)
      Grab ('row-p{0}' -f $pg)
    } else {
      Grab 'row-p1'
    }

    $prevName = $null
    for ($s = 1; $s -le $Slots; $s++) {
      $baseX = $AVATAR_X[$s - 1]
      $tries = @(0, 45, -45, 90)
      $ok = $false
      foreach ($off in $tries) {
        $x = $baseX + $off
        ClickAt $x $AVATAR_Y ('page{0} slot{1} off{2}' -f $pg, $s, $off)
        Start-Sleep -Milliseconds 620
        $tag = 'e-p{0}-s{1}-o{2}' -f $pg, $s, $off
        Grab $tag | Out-Null
        $sig = Get-Sig $NAME_X $NAME_Y $NAME_W $NAME_H 24 4
        $d = Sig-Diff $prevName $sig
        if ($null -eq $prevName -or $d -ge 400) {
          $prevName = $sig
          $ok = $true
          $seen++
          Log ('ACCEPT p{0} s{1} off{2} diff={3}' -f $pg, $s, $off, $d)
          break
        }
        $dups++
        Log ('DUPLICATE p{0} s{1} off{2} diff={3} -> jitter' -f $pg, $s, $off, $d)
      }
      if (-not $ok) { Log ('GIVEUP p{0} s{1}' -f $pg, $s) }
    }
  }

  for ($i = 1; $i -le $Pages; $i++) { DragStrip (1420 - $DragPx) 1420 $AVATAR_Y ('restore{0}' -f $i) }
  Grab 'row-restored'

  Log ('DONE files={0} accepted={1} duplicates={2}' -f $script:files, $seen, $dups)
  Set-Content -LiteralPath $DonePath -Value ('OK files={0} accepted={1} dups={2}' -f $script:files, $seen, $dups) -Encoding UTF8
  exit 0
}
catch {
  Log ('ERROR: {0}' -f $_.Exception.Message)
  Set-Content -LiteralPath $DonePath -Value ('ERROR ' + $_.Exception.Message) -Encoding UTF8
  exit 1
}
