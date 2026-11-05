<#
.SYNOPSIS
  Extra passes: scroll-probe the character row, and capture each character's
  full stat panel (the one behind the 属性详情 button).

.DESCRIPTION
  Runs elevated (the game has requireAdministrator; UIPI drops lower-integrity input).
  Only view-only UI is touched: the character avatar row (scroll), the four view
  tabs, and the 属性详情 button. Modals are closed with ESC.

  Task all:
    1) probe: capture the avatar row, scroll right several times, capture again,
       then scroll back to the original position
    2) stats: for each of the first N avatars, open detail -> 属性详情 -> capture -> ESC
#>
[CmdletBinding()]
param(
  [ValidateSet('probe', 'stats', 'walk', 'tenth', 'pagewalk', 'levels', 'mid6', 'all')]
  [string] $Task = 'all',
  [string] $OutDir = '',
  [int]    $MaxChars = 9
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not ('UiX' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class UiX {
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

[void][UiX]::SetProcessDPIAware()

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot '..\shots\hsr\extra' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$LogPath = Join-Path $OutDir '_run.log'
$DonePath = Join-Path $OutDir '_done.txt'
if (Test-Path $DonePath) { Remove-Item $DonePath -Force }

function Log([string]$m) {
  Add-Content -LiteralPath $LogPath -Value ('{0} | {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $m) -Encoding UTF8
}

$AVATAR_X = @(520, 632, 744, 856, 968, 1080, 1192, 1304, 1416)
$AVATAR_Y = 86
$TAB_DETAIL  = @(171, 204)
$BTN_STATS   = @(1760, 630)

function Find-GameWindow {
  $gamePids = @(Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessName -like '*StarRail*' } |
                Select-Object -ExpandProperty Id)
  Log ('process candidates: {0}' -f ($gamePids -join ','))
  $script:found = $null
  $script:best = 0
  $cb = [UiX+EnumWindowsProc]{
    param($h, $l)
    if (-not [UiX]::IsWindowVisible($h)) { return $true }
    $len = [UiX]::GetWindowTextLength($h)
    if ($len -le 0) { return $true }
    $pid2 = 0
    [void][UiX]::GetWindowThreadProcessId($h, [ref] $pid2)
    if ($gamePids -notcontains [int]$pid2) { return $true }
    $r = New-Object UiX+RECT
    [void][UiX]::GetWindowRect($h, [ref] $r)
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
  [void][UiX]::EnumWindows($cb, [IntPtr]::Zero)
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
  if ([UiX]::IsIconic($h)) { [void][UiX]::ShowWindow($h, 9) }
  $pid2 = 0
  $ftid = [UiX]::GetWindowThreadProcessId($h, [ref] $pid2)
  $ctid = [UiX]::GetCurrentThreadId()
  [void][UiX]::AttachThreadInput($ctid, $ftid, $true)
  [void][UiX]::SetForegroundWindow($h)
  [void][UiX]::AttachThreadInput($ctid, $ftid, $false)
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
  Log ('CAPTURE {0}' -f $tag)
}

function ToScreen([int]$rx, [int]$ry) {
  return @(($script:win.X + $rx), ($script:win.Y + $ry))
}

function ClickAt([int]$rx, [int]$ry, [string]$why) {
  Focus-Game
  if ([UiX]::GetForegroundWindow() -ne [IntPtr]$script:win.Hwnd) {
    Log ('ABORT: lost foreground before {0}' -f $why); throw 'LOST_FOREGROUND'
  }
  $p = ToScreen $rx $ry
  [void][UiX]::SetCursorPos($p[0], $p[1])
  Start-Sleep -Milliseconds 90
  [UiX]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 70
  [UiX]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Log ('CLICK {0} rel={1},{2}' -f $why, $rx, $ry)
  Start-Sleep -Milliseconds 320
}

function WheelAt([int]$rx, [int]$ry, [int]$notches) {
  Focus-Game
  $p = ToScreen $rx $ry
  [void][UiX]::SetCursorPos($p[0], $p[1])
  Start-Sleep -Milliseconds 120
  $delta = [int](120 * $notches)
  if ($delta -lt 0) { $dw = [uint32](4294967296 + [int64]$delta) } else { $dw = [uint32]$delta }
  [UiX]::mouse_event(0x0800, 0, 0, $dw, [IntPtr]::Zero)
  Log ('WHEEL rel={0},{1} notches={2}' -f $rx, $ry, $notches)
  Start-Sleep -Milliseconds 500
}

function Send-Esc {
  Focus-Game
  [UiX]::keybd_event(0x1B, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [UiX]::keybd_event(0x1B, 0, 2, [IntPtr]::Zero)
  Log 'KEY Escape'
  Start-Sleep -Milliseconds 420
}

function DragStrip([int]$x1, [int]$x2, [int]$y, [string]$why) {
  Focus-Game
  $p1 = ToScreen $x1 $y
  [void][UiX]::SetCursorPos($p1[0], $p1[1])
  Start-Sleep -Milliseconds 140
  [UiX]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 120
  $steps = 14
  for ($t = 1; $t -le $steps; $t++) {
    $cx = [int]($x1 + (($x2 - $x1) * $t / $steps))
    [void][UiX]::SetCursorPos(($script:win.X + $cx), ($script:win.Y + $y))
    Start-Sleep -Milliseconds 35
  }
  Start-Sleep -Milliseconds 150
  [UiX]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Log ('DRAG {0} {1}->{2} y={3}' -f $why, $x1, $x2, $y)
  Start-Sleep -Milliseconds 600
}

try {
  Focus-Game
  Log ('start task={0} maxChars={1}' -f $Task, $MaxChars)

  if ($Task -eq 'probe' -or $Task -eq 'all') {
    WheelAt 900 $AVATAR_Y 0
    Grab 'row-00'
    for ($k = 1; $k -le 4; $k++) {
      WheelAt 900 $AVATAR_Y -600
      Grab ('row-{0:D2}' -f $k)
    }
    WheelAt 900 $AVATAR_Y 3000
    Grab 'row-99-restored'
    Log 'probe done'
  }

  if ($Task -eq 'stats' -or $Task -eq 'all') {
    $n = [Math]::Min($MaxChars, $AVATAR_X.Count)
    for ($i = 0; $i -lt $n; $i++) {
      $tag = 'st{0:D2}' -f ($i + 1)
      ClickAt $AVATAR_X[$i] $AVATAR_Y ('avatar#{0}' -f ($i + 1))
      Start-Sleep -Milliseconds 700
      ClickAt $TAB_DETAIL[0] $TAB_DETAIL[1] 'tab:detail'
      Start-Sleep -Milliseconds 650
      Grab ('{0}-1-detail' -f $tag)
      ClickAt $BTN_STATS[0] $BTN_STATS[1] 'btn:stats'
      Start-Sleep -Milliseconds 800
      Grab ('{0}-2-stats' -f $tag)
      Send-Esc
      Start-Sleep -Milliseconds 200
      Log ('stat slot {0} done' -f ($i + 1))
    }
  }

  if ($Task -eq 'walk') {
    for ($i = 1; $i -le $MaxChars; $i++) {
      $tag = 'walk{0:D2}' -f $i
      ClickAt 1466 $AVATAR_Y 'avatar:rightmost'
      Start-Sleep -Milliseconds 850
      Grab ('{0}-1-detail' -f $tag)
      ClickAt $BTN_STATS[0] $BTN_STATS[1] 'btn:stats'
      Start-Sleep -Milliseconds 800
      Grab ('{0}-2-stats' -f $tag)
      Send-Esc
      Start-Sleep -Milliseconds 250
      Log ('walk slot {0} done' -f $i)
    }
  }

  if ($Task -eq 'tenth') {
    ClickAt 1466 $AVATAR_Y 'avatar:rightmost'
    Start-Sleep -Milliseconds 900
    ClickAt $TAB_DETAIL[0] $TAB_DETAIL[1] 'tab:detail'
    Start-Sleep -Milliseconds 650
    Grab 't-1-detail'
    ClickAt 171 299 'tab:cone'
    Start-Sleep -Milliseconds 750
    Grab 't-2-cone'
    ClickAt 171 391 'tab:traces'
    Start-Sleep -Milliseconds 750
    Grab 't-3-traces'
    ClickAt 171 486 'tab:relics'
    Start-Sleep -Milliseconds 750
    Grab 't-4-relics'
    ClickAt $TAB_DETAIL[0] $TAB_DETAIL[1] 'tab:detail'
    Start-Sleep -Milliseconds 600
    ClickAt $BTN_STATS[0] $BTN_STATS[1] 'btn:stats'
    Start-Sleep -Milliseconds 800
    Grab 't-5-stats'
    Send-Esc
    Grab 'drag-00'
    DragStrip 1420 620 $AVATAR_Y 'left1'
    Grab 'drag-01'
    DragStrip 1420 620 $AVATAR_Y 'left2'
    Grab 'drag-02'
    DragStrip 1420 620 $AVATAR_Y 'left3'
    Grab 'drag-03'
    DragStrip 620 1420 $AVATAR_Y 'right-restore1'
    DragStrip 620 1420 $AVATAR_Y 'right-restore2'
    DragStrip 620 1420 $AVATAR_Y 'right-restore3'
    Grab 'drag-99-restored'
  }

  if ($Task -eq 'pagewalk') {
    for ($i = 1; $i -le $MaxChars; $i++) {
      DragStrip 1420 620 $AVATAR_Y ('page{0}' -f $i)
      Grab ('page-{0:D2}' -f $i)
      Log ('page {0} captured' -f $i)
    }
    for ($i = 1; $i -le $MaxChars; $i++) {
      DragStrip 620 1420 $AVATAR_Y ('restore{0}' -f $i)
    }
    Grab 'page-99-restored'
  }

  if ($Task -eq 'levels') {
    $slots = @(520, 632, 744, 856, 968, 1080, 1192, 1304, 1416, 1466)
    for ($pg = 1; $pg -le $MaxChars; $pg++) {
      for ($s = 0; $s -lt $slots.Count; $s++) {
        $tag = 'lv-p{0}D-s{1:D2}' -f $pg, ($s + 1)
        ClickAt $slots[$s] $AVATAR_Y ('level page{0} slot{1}' -f $pg, ($s + 1))
        Start-Sleep -Milliseconds 620
        Grab $tag
      }
      DragStrip 1420 620 $AVATAR_Y ('levels-next-page{0}' -f $pg)
    }
    for ($i = 1; $i -le $MaxChars; $i++) { DragStrip 620 1420 $AVATAR_Y ('levels-restore{0}' -f $i) }
    Grab 'levels-restored'
  }

  if ($Task -eq 'mid6') {
    DragStrip 1420 620 $AVATAR_Y 'goto-page2'
    Start-Sleep -Milliseconds 900
    $slots = @(744, 856, 968, 1080, 1192, 1304)
    for ($i = 0; $i -lt $slots.Count; $i++) {
      $tag = 'm{0}' -f ($i + 1)
      ClickAt $slots[$i] $AVATAR_Y ('mid slot{0}' -f ($i + 3))
      Start-Sleep -Milliseconds 800
      ClickAt $TAB_DETAIL[0] $TAB_DETAIL[1] 'tab:detail'
      Start-Sleep -Milliseconds 600
      Grab ('{0}-1-detail' -f $tag)
      ClickAt 171 299 'tab:cone'
      Start-Sleep -Milliseconds 700
      Grab ('{0}-2-cone' -f $tag)
      ClickAt 171 391 'tab:traces'
      Start-Sleep -Milliseconds 700
      Grab ('{0}-3-traces' -f $tag)
      ClickAt 171 486 'tab:relics'
      Start-Sleep -Milliseconds 700
      Grab ('{0}-4-relics' -f $tag)
      ClickAt $TAB_DETAIL[0] $TAB_DETAIL[1] 'tab:detail'
      Start-Sleep -Milliseconds 550
      ClickAt $BTN_STATS[0] $BTN_STATS[1] 'btn:stats'
      Start-Sleep -Milliseconds 800
      Grab ('{0}-5-stats' -f $tag)
      Send-Esc
      Log ('mid char {0} done' -f ($i + 1))
    }
    DragStrip 620 1420 $AVATAR_Y 'restore-page1'
    Grab 'mid-restored'
  }

  Log ('DONE files={0}' -f $script:files)
  Set-Content -LiteralPath $DonePath -Value ('OK files={0}' -f $script:files) -Encoding UTF8
  exit 0
}
catch {
  Log ('ERROR: {0}' -f $_.Exception.Message)
  Set-Content -LiteralPath $DonePath -Value ('ERROR ' + $_.Exception.Message) -Encoding UTF8
  exit 1
}
