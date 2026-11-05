<#
.SYNOPSIS
  Diagnose whether synthetic input can reach a target process.

.DESCRIPTION
  Reports the current process integrity level / elevation and the same for a
  target PID, plus the foreground window. Higher-integrity targets silently
  ignore input from lower-integrity senders (UIPI), which looks exactly like
  "my clicks do nothing".
#>
[CmdletBinding()]
param(
  [int] $TargetPid = 0,
  [string] $TitleLike = ''
)

$ErrorActionPreference = 'Stop'

if (-not ('TokProbe' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class TokProbe {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint acc, bool inherit, uint pid);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr p, uint acc, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool GetTokenInformation(IntPtr tok, int cls, IntPtr buf, int len, out int ret);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
}
'@
}

function Get-ProcTokenInfo([int]$procId) {
  $h = if ($procId -eq 0) { [TokProbe]::GetCurrentProcess() } else { [TokProbe]::OpenProcess(0x1000, $false, [uint32]$procId) }
  if ($procId -ne 0 -and $h -eq [IntPtr]::Zero) {
    return [pscustomobject]@{ Pid = $procId; Opened = $false; Err = [Runtime.InteropServices.Marshal]::GetLastWin32Error(); Integrity = $null; Elevated = $null }
  }
  $tok = [IntPtr]::Zero
  if (-not [TokProbe]::OpenProcessToken($h, 0x0008, [ref]$tok)) {
    if ($procId -ne 0) { [void][TokProbe]::CloseHandle($h) }
    return [pscustomobject]@{ Pid = $procId; Opened = $true; Err = [Runtime.InteropServices.Marshal]::GetLastWin32Error(); Integrity = $null; Elevated = $null }
  }

  $integrity = $null
  $len = 0
  [void][TokProbe]::GetTokenInformation($tok, 25, [IntPtr]::Zero, 0, [ref]$len)   # TokenIntegrityLevel
  if ($len -gt 0) {
    $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal($len)
    try {
      if ([TokProbe]::GetTokenInformation($tok, 25, $buf, $len, [ref]$len)) {
        $sidPtr = [Runtime.InteropServices.Marshal]::ReadIntPtr($buf)
        $cnt = [Runtime.InteropServices.Marshal]::ReadByte($sidPtr, 1)
        if ($cnt -ge 1) {
          $rid = [Runtime.InteropServices.Marshal]::ReadInt32($sidPtr, 8 + 4 * ($cnt - 1))
          $integrity = switch ($rid) {
            0x0000 { 'Untrusted' } 0x1000 { 'Low' } 0x2000 { 'Medium' }
            0x2100 { 'MediumPlus' } 0x3000 { 'High' } 0x4000 { 'System' }
            default { ('Other(0x{0:X})' -f $rid) }
          }
        }
      }
    } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buf) }
  }

  $elevated = $null
  $len2 = 4
  $buf2 = [Runtime.InteropServices.Marshal]::AllocHGlobal($len2)
  try {
    if ([TokProbe]::GetTokenInformation($tok, 20, $buf2, $len2, [ref]$len2)) {   # TokenElevation
      $elevated = ([Runtime.InteropServices.Marshal]::ReadInt32($buf2) -ne 0)
    }
  } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buf2) }

  [void][TokProbe]::CloseHandle($tok)
  if ($procId -ne 0) { [void][TokProbe]::CloseHandle($h) }
  return [pscustomobject]@{ Pid = $procId; Opened = $true; Err = 0; Integrity = $integrity; Elevated = $elevated }
}

$self = Get-ProcTokenInfo 0
Write-Output ('SELF pid={0} integrity={1} elevated={2}' -f $PID, $self.Integrity, $self.Elevated)

if ($TargetPid -gt 0) {
  $t = Get-ProcTokenInfo $TargetPid
  Write-Output ('TARGET pid={0} opened={1} err={2} integrity={3} elevated={4}' -f $t.Pid, $t.Opened, $t.Err, $t.Integrity, $t.Elevated)
  if ($t.Integrity -and $self.Integrity) {
    $order = @{ 'Untrusted' = 0; 'Low' = 1; 'Medium' = 2; 'MediumPlus' = 3; 'High' = 4; 'System' = 5 }
    $si = $order[$self.Integrity]; $ti = $order[$t.Integrity]
    if ($null -ne $si -and $null -ne $ti) {
      if ($ti -gt $si) { Write-Output 'VERDICT=UIPI_BLOCKED target is higher integrity; synthetic input will be dropped' }
      else { Write-Output 'VERDICT=INPUT_ALLOWED integrity permits injection' }
    }
  }
}

$fg = [TokProbe]::GetForegroundWindow()
$sb = New-Object System.Text.StringBuilder 512
[void][TokProbe]::GetWindowText($fg, $sb, $sb.Capacity)
Write-Output ('FOREGROUND hwnd={0} title="{1}"' -f $fg, $sb.ToString())

$p = New-Object TokProbe+POINT
[void][TokProbe]::GetCursorPos([ref]$p)
Write-Output ('CURSOR {0},{1}' -f $p.X, $p.Y)
[void][TokProbe]::SetCursorPos($p.X + 5, $p.Y + 3)
Start-Sleep -Milliseconds 120
$q = New-Object TokProbe+POINT
[void][TokProbe]::GetCursorPos([ref]$q)
Write-Output ('CURSOR_AFTER {0},{1} moved={2}' -f $q.X, $q.Y, (($q.X -ne $p.X) -or ($q.Y -ne $p.Y)))
