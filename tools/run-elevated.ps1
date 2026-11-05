<#
.SYNOPSIS
  Launch a PowerShell script elevated (UAC) and return its exit code.

.DESCRIPTION
  The game process declares requireAdministrator, so UIPI drops any synthetic
  input sent from a lower-integrity process. Every capture/click script must run
  elevated; this wrapper does the Start-Process -Verb RunAs dance and waits.

  Arguments after -Arguments are passed through to the target script as separate
  argv entries. Prefer absolute paths for anything the target script writes.

.EXAMPLE
  .\run-elevated.ps1 -File .\hsr-collect.ps1 -Arguments '-Pilot','-OutDir','C:\tmp\shots'

.EXAMPLE
  .\run-elevated.ps1 -File .\hsr-enum.ps1 -Arguments '-Pages','9','-Slots','9','-DragPx','450'
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $File,
  [string[]] $Arguments = @(),
  [switch] $NoWait
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $File)) { throw "script not found: $File" }
$resolved = (Resolve-Path -LiteralPath $File).Path
$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "powershell.exe not found: $exe" }

$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $resolved) + $Arguments

if ($NoWait) {
  $p = Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs -WindowStyle Hidden -PassThru
  Write-Output ("STARTED pid={0} script={1}" -f $p.Id, $resolved)
  exit 0
}

$p = Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs -WindowStyle Hidden -Wait -PassThru
Write-Output ("EXITED exit={0} pid={1} script={2}" -f $p.ExitCode, $p.Id, $resolved)
exit $p.ExitCode
