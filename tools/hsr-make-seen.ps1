<#
.SYNOPSIS
  Build a "seen characters" mask file from existing -detail.png captures.

.DESCRIPTION
  The scan scripts can skip characters that were already collected by comparing
  the binarized name band of the current character against a list of known masks.
  This helper produces that list from a folder of captures, so a follow-up run
  spends its click budget only on characters it has not seen yet.

.EXAMPLE
  .\hsr-make-seen.ps1 -Dir ..\shots\hsr\deep4 -OutFile ..\shots\hsr\seen.txt
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $Dir,
  [string] $OutFile = '',
  [string] $FilePattern = '*-detail.png',
  [int] $NameX = 1450,
  [int] $NameY = 178,
  [int] $NameW = 300,
  [int] $NameH = 42,
  [int] $NameTh = 185
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $Dir)) { throw "dir not found: $Dir" }
if (-not $OutFile) { $OutFile = Join-Path (Resolve-Path $Dir).Path 'seen.txt' }

function Get-NameMask([string]$path) {
  $bmp = [System.Drawing.Bitmap]::FromFile($path)
  try {
    $mask = New-Object byte[] ($NameW * $NameH)
    $i = 0
    for ($y = 0; $y -lt $NameH; $y++) {
      for ($x = 0; $x -lt $NameW; $x++) {
        $px = $bmp.GetPixel($NameX + $x, $NameY + $y)
        $lum = ($px.R * 299 + $px.G * 587 + $px.B * 114) / 1000
        if ($lum -ge $NameTh) { $mask[$i] = 1 }
        $i++
      }
    }
    return ,$mask
  }
  finally { $bmp.Dispose() }
}

$files = Get-ChildItem -LiteralPath $Dir -Filter $FilePattern -File | Sort-Object Name
if ($files.Count -eq 0) { throw "no files matching $FilePattern in $Dir" }

$lines = New-Object System.Collections.Generic.List[string]
foreach ($f in $files) {
  $mask = Get-NameMask $f.FullName
  $lines.Add([Convert]::ToBase64String($mask))
}
[System.IO.File]::WriteAllLines($OutFile, $lines, [System.Text.UTF8Encoding]::new($false))
Write-Output ("WROTE {0} masks from {1} files -> {2}" -f $lines.Count, $files.Count, $OutFile)
