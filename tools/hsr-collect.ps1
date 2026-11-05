<#
.SYNOPSIS
  Elevated collector: drive the Honkai Star Rail character panel and capture pages.

.DESCRIPTION
  Runs as administrator (the game itself has requireAdministrator in its manifest,
  so UIPI drops any input coming from a lower integrity process).

  Only view-only UI is touched:
    - left menu tabs: 详情 / 光锥 / 行迹 / 遗器
    - character avatars in the top row
  It never clicks enhance / decompose / shop / confirm style controls.

  Every click is preceded by a foreground check; every step is captured to PNG
  and appended to _run.log in the output folder.
#>
[CmdletBinding()]
param(
  [string] $TitleLike = '星穹铁道',
  [string] $OutDir    = '',
  [switch] $Pilot,
  [int]    $MaxChars  = 9
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not ('UiCap' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class UiCap {
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

[void][UiCap]::SetProcessDPIAware()

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot '..\shots\hsr\sweep' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$LogPath = Join-Path $OutDir '_run.log'
$DonePath = Join-Path $OutDir '_done.txt'
if (Test-Path $DonePath) { Remove-Item $DonePath -Force }

function Log([string]$m) {
  Add-Content -LiteralPath $LogPath -Value ('{0} | {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $m) -Encoding UTF8
}

# ---- window-relative coordinate table (measured from a 1942x1136 window capture) ----
$MENU = @{
  detail = @(171, 204)
  cone   = @(171, 299)
  traces = @(171, 391)
  relics = @(171, 486)
}
$AVATAR_X = @(520, 632, 744, 856, 968, 1080, 1192, 1304, 1416)
$AVATAR_Y = 86

function Find-GameWindow {
  $gamePids = @(Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessName -like '*StarRail*' } |
                Select-Object -ExpandProperty Id)
  Log ('process candidates: {0}' -f ($gamePids -join ','))
  $script:found = $null
  $script:best = 0
  $cb = [UiCap+EnumWindowsProc]{
    param($h, $l)
    if (-not [UiCap]::IsWindowVisible($h)) { return $true }
    $len = [UiCap]::GetWindowTextLength($h)
    if ($len -le 0) { return $true }
    $pid2 = 0
    [void][UiCap]::GetWindowThreadProcessId($h, [ref] $pid2)
    if ($gamePids -notcontains [int]$pid2) { return $true }
    $sb = New-Object System.Text.StringBuilder ($len + 2)
    [void][UiCap]::GetWindowText($h, $sb, $sb.Capacity)
    $r = New-Object UiCap+RECT
    [void][UiCap]::GetWindowRect($h, [ref] $r)
    $area = ($r.Right - $r.Left) * ($r.Bottom - $r.Top)
    if ($area -gt $script:best) {
      $script:best = $area
      $script:found = [pscustomobject]@{
        Hwnd = [int64]$h; Title = $sb.ToString(); Pid = [int]$pid2
        X = $r.Left; Y = $r.Top; W = ($r.Right - $r.Left); H = ($r.Bottom - $r.Top)
      }
    }
    return $true
  }
  [void][UiCap]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:found
}

$script:win = Find-GameWindow
if (-not $script:win) {
  Log 'ABORT: game window not found'
  Set-Content -LiteralPath $DonePath -Value 'ABORT_NO_WINDOW' -Encoding UTF8
  exit 3
}
Log ('window title="{0}" rect={1},{2} {3}x{4}' -f $script:win.Title, $script:win.X, $script:win.Y, $script:win.W, $script:win.H)

$script:files = 0

function Invoke-Focus {
  $h = [IntPtr]$script:win.Hwnd
  if ([UiCap]::IsIconic($h)) { [void][UiCap]::ShowWindow($h, 9) }
  $pid2 = 0
  $ftid = [UiCap]::GetWindowThreadProcessId($h, [ref] $pid2)
  $ctid = [UiCap]::GetCurrentThreadId()
  [void][UiCap]::AttachThreadInput($ctid, $ftid, $true)
  [void][UiCap]::SetForegroundWindow($h)
  [void][UiCap]::AttachThreadInput($ctid, $ftid, $false)
  Start-Sleep -Milliseconds 180
}

function Capture([string]$tag) {
  $bmp = New-Object System.Drawing.Bitmap($script:win.W, $script:win.H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try { $g.CopyFromScreen($script:win.X, $script:win.Y, 0, 0, (New-Object System.Drawing.Size($script:win.W, $script:win.H))) }
  finally { $g.Dispose() }
  $file = Join-Path $OutDir ('{0}.png' -f $tag)
  $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  $script:files++
  Log ('CAPTURE {0}' -f $tag)
  return $file
}

function Click-Rel([int]$rx, [int]$ry, [string]$why) {
  Invoke-Focus
  $fg = [UiCap]::GetForegroundWindow()
  if ($fg -ne [IntPtr]$script:win.Hwnd) {
    Log ('ABORT: lost foreground before click {0} (rx={1},ry={2})' -f $why, $rx, $ry)
    throw 'LOST_FOREGROUND'
  }
  $x = $script:win.X + $rx
  $y = $script:win.Y + $ry
  if ($x -lt $script:win.X -or $x -gt ($script:win.X + $script:win.W) -or $y -lt $script:win.Y -or $y -gt ($script:win.Y + $script:win.H)) {
    Log ('ABORT: point outside window rx={0} ry={1}' -f $rx, $ry)
    throw 'POINT_OUTSIDE'
  }
  [void][UiCap]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 90
  [UiCap]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 70
  [UiCap]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Log ('CLICK {0} at rel={1},{2} screen={3},{4}' -f $why, $rx, $ry, $x, $y)
  Start-Sleep -Milliseconds 320
}

try {
  Invoke-Focus
  Log ('start pilot={0} maxChars={1}' -f $Pilot.IsPresent, $MaxChars)

  if ($Pilot) {
    Capture 'pilot-00-before'
    Click-Rel $MENU.traces[0] $MENU.traces[1] 'menu:traces'
    Start-Sleep -Milliseconds 900
    Capture 'pilot-01-traces'
    Click-Rel $MENU.relics[0] $MENU.relics[1] 'menu:relics'
    Start-Sleep -Milliseconds 900
    Capture 'pilot-02-relics'
    Click-Rel $MENU.detail[0] $MENU.detail[1] 'menu:detail'
    Start-Sleep -Milliseconds 700
    Capture 'pilot-03-detail'
    Log 'pilot done'
  }
  else {
    $n = [Math]::Min($MaxChars, $AVATAR_X.Count)
    for ($i = 0; $i -lt $n; $i++) {
      $tag = 'char{0:D2}' -f ($i + 1)
      Click-Rel $AVATAR_X[$i] $AVATAR_Y ('avatar#{0}' -f ($i + 1))
      Start-Sleep -Milliseconds 800
      Click-Rel $MENU.detail[0] $MENU.detail[1] 'menu:detail'
      Start-Sleep -Milliseconds 650
      Capture ('{0}-1-detail' -f $tag)
      Click-Rel $MENU.cone[0] $MENU.cone[1] 'menu:cone'
      Start-Sleep -Milliseconds 750
      Capture ('{0}-2-cone' -f $tag)
      Click-Rel $MENU.traces[0] $MENU.traces[1] 'menu:traces'
      Start-Sleep -Milliseconds 750
      Capture ('{0}-3-traces' -f $tag)
      Click-Rel $MENU.relics[0] $MENU.relics[1] 'menu:relics'
      Start-Sleep -Milliseconds 750
      Capture ('{0}-4-relics' -f $tag)
      Click-Rel $MENU.detail[0] $MENU.detail[1] 'menu:detail(reset)'
      Start-Sleep -Milliseconds 250
      Log ('character slot {0} done' -f ($i + 1))
    }
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
