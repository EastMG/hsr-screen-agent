<#
.SYNOPSIS
  Capture the desktop (or a specific window) to PNG files.

.DESCRIPTION
  Pure OS screenshot via System.Drawing + user32. No third-party tools, no
  memory access, no input injection. Used to let an AI agent read the screen.

.EXAMPLE
  pwsh -NoProfile -File capture-screen.ps1 -OutDir .\shots

.EXAMPLE
  pwsh -NoProfile -File capture-screen.ps1 -WindowTitle 'Star Rail' -Count 5 -IntervalMs 1500
#>
[CmdletBinding()]
param(
  [string] $OutDir = '.\shots',
  [int]    $Count = 1,
  [int]    $IntervalMs = 1000,
  [string] $WindowTitle,
  [int]    $MaxWidth = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Win32Cap {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

[void][Win32Cap]::SetProcessDPIAware()

if (-not (Test-Path -LiteralPath $OutDir)) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

function Get-TargetRect {
  param([string] $TitleLike)
  if ($TitleLike) {
    $proc = Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -and $_.MainWindowTitle -like "*$TitleLike*" } |
            Select-Object -First 1
    if ($proc) {
      $h = $proc.MainWindowHandle
      if ($h -ne [IntPtr]::Zero) {
        $r = New-Object Win32Cap+RECT
        if ([Win32Cap]::GetWindowRect($h, [ref] $r)) {
          if (($r.Right - $r.Left) -gt 16 -and ($r.Bottom - $r.Top) -gt 16) {
            return [pscustomobject]@{
              X = $r.Left; Y = $r.Top
              W = $r.Right - $r.Left; H = $r.Bottom - $r.Top
              Title = $proc.MainWindowTitle; Process = $proc.ProcessName
              Minimized = [Win32Cap]::IsIconic($h)
            }
          }
        }
      }
    }
    return $null
  }
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  return [pscustomobject]@{
    X = $b.X; Y = $b.Y; W = $b.Width; H = $b.Height
    Title = 'PRIMARY_SCREEN'; Process = 'desktop'; Minimized = $false
  }
}

for ($i = 0; $i -lt $Count; $i++) {
  $target = Get-TargetRect -TitleLike $WindowTitle
  if (-not $target) {
    Write-Output "TARGET_NOT_FOUND title=$WindowTitle"
    exit 2
  }

  $bmp = New-Object System.Drawing.Bitmap($target.W, $target.H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.CopyFromScreen($target.X, $target.Y, 0, 0, (New-Object System.Drawing.Size($target.W, $target.H)))
  }
  finally {
    $g.Dispose()
  }

  if ($MaxWidth -gt 0 -and $target.W -gt $MaxWidth) {
    $scale = $MaxWidth / $target.W
    $nw = [int]($target.W * $scale); $nh = [int]($target.H * $scale)
    $small = New-Object System.Drawing.Bitmap($nw, $nh)
    $g2 = [System.Drawing.Graphics]::FromImage($small)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.DrawImage($bmp, 0, 0, $nw, $nh)
    $g2.Dispose(); $bmp.Dispose()
    $bmp = $small
  }

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
  $file = Join-Path $OutDir ("shot-{0}.png" -f $stamp)
  $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  $w = $bmp.Width; $h = $bmp.Height
  $bmp.Dispose()

  $len = (Get-Item -LiteralPath $file).Length
  Write-Output ("CAPTURED path={0} size={1}x{2} bytes={3} source={4} process={5} minimized={6}" -f `
      $file, $w, $h, $len, $target.Title, $target.Process, $target.Minimized)

  if ($i -lt ($Count - 1)) { Start-Sleep -Milliseconds $IntervalMs }
}
