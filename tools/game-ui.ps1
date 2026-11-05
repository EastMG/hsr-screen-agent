<#
.SYNOPSIS
  Minimal, audited mouse/keyboard + window capture driver for one target window.

.DESCRIPTION
  Read-only friendly UI driver: enumerate windows, focus a window, capture its
  rect to PNG, move/click at screen coordinates, press a key.
  Guards: every click requires the target window to be foreground, the point to
  be inside the target rect. Every action is appended to an audit log.

.EXAMPLES
  -Action list
  -Action capture -TitleLike 'Star Rail'
  -Action click -TitleLike 'Star Rail' -Points '600,590','610,680' -CaptureEach
#>
[CmdletBinding()]
param(
  [ValidateSet('list','capture','focus','click','move','key')]
  [string]   $Action      = 'list',
  [string]   $TitleLike   = '',
  [int]      $Hwnd        = 0,
  [string[]] $Points      = @(),
  [int]      $IntervalMs  = 700,
  [string]   $Key         = 'Escape',
  [switch]   $CaptureEach,
  [string]   $OutDir      = (Join-Path $PSScriptRoot '..\shots'),
  [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not ('UiWin' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class UiWin {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint data, IntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, IntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
'@
}

[void][UiWin]::SetProcessDPIAware()
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$AuditLog = Join-Path $OutDir '..\ui-actions.log'
$RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'

function Write-Audit([string]$msg) {
  $line = ('{0} | {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $msg)
  Add-Content -LiteralPath $AuditLog -Value $line -Encoding UTF8
}

function Get-Windows {
  $list = New-Object System.Collections.ArrayList
  $cb = [UiWin+EnumWindowsProc]{
    param($h, $l)
    if (-not [UiWin]::IsWindowVisible($h)) { return $true }
    $len = [UiWin]::GetWindowTextLength($h)
    if ($len -le 0) { return $true }
    $sb = New-Object System.Text.StringBuilder ($len + 2)
    [void][UiWin]::GetWindowText($h, $sb, $sb.Capacity)
    $r = New-Object UiWin+RECT
    [void][UiWin]::GetWindowRect($h, [ref] $r)
    $pid2 = 0
    [void][UiWin]::GetWindowThreadProcessId($h, [ref] $pid2)
    [void]$list.Add([pscustomobject]@{
      Hwnd  = [int64]$h
      Title = $sb.ToString()
      Pid   = $pid2
      X = $r.Left; Y = $r.Top; W = ($r.Right - $r.Left); H = ($r.Bottom - $r.Top)
    })
    return $true
  }
  [void][UiWin]::EnumWindows($cb, [IntPtr]::Zero)
  return $list
}

function Resolve-Target {
  if ($Hwnd -ne 0) {
    $m = Get-Windows | Where-Object { $_.Hwnd -eq $Hwnd } | Select-Object -First 1
    if ($m) { return $m }
    throw "HWND_NOT_FOUND $Hwnd"
  }
  if (-not $TitleLike) { throw 'NEED_TITLE_OR_HWND' }
  $m = Get-Windows | Where-Object { $_.Title -like "*$TitleLike*" } |
       Sort-Object -Property W -Descending | Select-Object -First 1
  if (-not $m) { throw "TARGET_NOT_FOUND title=*$TitleLike*" }
  return $m
}

function Invoke-Focus($w) {
  $h = [IntPtr]$w.Hwnd
  if ([UiWin]::IsIconic($h)) { [void][UiWin]::ShowWindow($h, 9) }
  $pid2 = 0
  $ftid = [UiWin]::GetWindowThreadProcessId($h, [ref] $pid2)
  $ctid = [UiWin]::GetCurrentThreadId()
  [void][UiWin]::AttachThreadInput($ctid, $ftid, $true)
  [void][UiWin]::SetForegroundWindow($h)
  [void][UiWin]::AttachThreadInput($ctid, $ftid, $false)
  Start-Sleep -Milliseconds 250
}

function Get-ForegroundTitle {
  $h = [UiWin]::GetForegroundWindow()
  $len = [UiWin]::GetWindowTextLength($h)
  $sb = New-Object System.Text.StringBuilder ($len + 2)
  [void][UiWin]::GetWindowText($h, $sb, $sb.Capacity)
  return [pscustomobject]@{ Hwnd = [int64]$h; Title = $sb.ToString() }
}

function Save-Capture($w, [string]$tag) {
  $bmp = New-Object System.Drawing.Bitmap($w.W, $w.H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try { $g.CopyFromScreen($w.X, $w.Y, 0, 0, (New-Object System.Drawing.Size($w.W, $w.H))) }
  finally { $g.Dispose() }
  $file = Join-Path $OutDir ('{0}-{1}.png' -f $RunStamp, $tag)
  $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  $dims = '{0}x{1}' -f $bmp.Width, $bmp.Height
  $bmp.Dispose()
  Write-Audit ("CAPTURE tag={0} file={1} dims={2} rect={3},{4},{5},{6}" -f $tag, $file, $dims, $w.X, $w.Y, $w.W, $w.H)
  return $file
}

switch ($Action) {

  'list' {
    $ws = Get-Windows | Sort-Object -Property W -Descending
    foreach ($w in $ws) {
      Write-Output ('HWND={0} pid={1} rect={2},{3} {4}x{5} fg={6} | {7}' -f `
        $w.Hwnd, $w.Pid, $w.X, $w.Y, $w.W, $w.H,
        ([UiWin]::GetForegroundWindow() -eq [IntPtr]$w.Hwnd), $w.Title)
    }
  }

  'capture' {
    $w = Resolve-Target
    $f = Save-Capture $w ('win-{0}x{1}' -f $w.W, $w.H)
    Write-Output ('CAPTURED file={0} title={1} rect={2},{3} {4}x{5}' -f $f, $w.Title, $w.X, $w.Y, $w.W, $w.H)
  }

  'focus' {
    $w = Resolve-Target
    Invoke-Focus $w
    $fg = Get-ForegroundTitle
    Write-Output ('FOCUSED foreground="{0}" match={1}' -f $fg.Title, ($fg.Hwnd -eq $w.Hwnd))
    Write-Audit ('FOCUS hwnd={0} foreground="{1}"' -f $w.Hwnd, $fg.Title)
  }

  'move' {
    $w = Resolve-Target
    Invoke-Focus $w
    if ($Points.Count -lt 1) { throw 'NEED_POINTS' }
    $p = $Points[0] -split ','
    $x = [int]$p[0]; $y = [int]$p[1]
    if ($x -lt $w.X -or $x -gt ($w.X + $w.W) -or $y -lt $w.Y -or $y -gt ($w.Y + $w.H)) {
      throw ('POINT_OUTSIDE_WINDOW point={0},{1} rect={2},{3} {4}x{5}' -f $x, $y, $w.X, $w.Y, $w.W, $w.H)
    }
    if (-not $DryRun) { [void][UiWin]::SetCursorPos($x, $y) }
    Write-Audit ('MOVE point={0},{1} dryrun={2}' -f $x, $y, $DryRun)
    Write-Output ('MOVED to {0},{1}' -f $x, $y)
  }

  'click' {
    $w = Resolve-Target
    Invoke-Focus $w
    $fg = Get-ForegroundTitle
    if (-not $DryRun -and $fg.Hwnd -ne [int64]$w.Hwnd) {
      throw ('REFUSED_NOT_FOREGROUND foreground="{0}" target="{1}"' -f $fg.Title, $w.Title)
    }
    $i = 0
    foreach ($pt in $Points) {
      $i++
      $p = $pt -split ','
      $x = [int]$p[0]; $y = [int]$p[1]
      if ($x -lt $w.X -or $x -gt ($w.X + $w.W) -or $y -lt $w.Y -or $y -gt ($w.Y + $w.H)) {
        throw ('POINT_OUTSIDE_WINDOW point={0},{1} rect={2},{3} {4}x{5}' -f $x, $y, $w.X, $w.Y, $w.W, $w.H)
      }
      if (-not $DryRun) {
        [void][UiWin]::SetCursorPos($x, $y)
        Start-Sleep -Milliseconds 80
        [UiWin]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 60
        [UiWin]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
      }
      Write-Audit ('CLICK step={0}/{1} point={2},{3} dryrun={4}' -f $i, $Points.Count, $x, $y, $DryRun)
      Write-Output ('CLICKED {0},{1}' -f $x, $y)
      if ($CaptureEach) {
        Start-Sleep -Milliseconds $IntervalMs
        $f = Save-Capture $w ('step{0}' -f $i)
        Write-Output ('STEPCAP file={0}' -f $f)
      } elseif ($i -lt $Points.Count) {
        Start-Sleep -Milliseconds $IntervalMs
      }
    }
  }

  'key' {
    $w = Resolve-Target
    Invoke-Focus $w
    $vk = switch ($Key) {
      'Escape' { 0x1B } 'Enter' { 0x0D } 'Space' { 0x20 } 'Tab' { 0x09 }
      default { throw "UNSUPPORTED_KEY $Key" }
    }
    if (-not $DryRun) {
      [UiWin]::keybd_event([byte]$vk, 0, 0, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 40
      [UiWin]::keybd_event([byte]$vk, 0, 2, [IntPtr]::Zero)
    }
    Write-Audit ('KEY {0}' -f $Key)
    Write-Output ('KEY {0}' -f $Key)
  }
}
