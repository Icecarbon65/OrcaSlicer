param(
    [Parameter(Mandatory = $true)]
    [string] $Root,

    [Parameter(Mandatory = $true)]
    [ValidateSet('x64', 'arm64')]
    [string] $Architecture,

    [string] $InstallerPath
)

$ErrorActionPreference = 'Stop'
$expectedMachine = if ($Architecture -eq 'arm64') { 0xAA64 } else { 0x8664 }

function Get-PeMachine([string] $Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $reader = [System.IO.BinaryReader]::new($stream)
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) {
            throw "Missing DOS header"
        }
        $stream.Position = 0x3c
        $peOffset = $reader.ReadUInt32()
        if ($peOffset -gt $stream.Length - 6) {
            throw "Invalid PE header offset"
        }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "Missing PE signature"
        }
        return $reader.ReadUInt16()
    } finally {
        $stream.Dispose()
    }
}

function Assert-PeArchitecture([string] $Path) {
    try {
        $machine = Get-PeMachine $Path
    } catch {
        throw "Invalid Windows binary '$Path': $($_.Exception.Message)"
    }
    if ($machine -ne $expectedMachine) {
        throw ("Wrong architecture for '{0}': expected {1} (0x{2:X4}), found 0x{3:X4}" -f $Path, $Architecture, $expectedMachine, $machine)
    }
}

$resolvedRoot = (Resolve-Path $Root).Path
$binaries = @(Get-ChildItem $resolvedRoot -Recurse -File | Where-Object { $_.Extension -in '.exe', '.dll', '.pyd' })
if ($binaries.Count -eq 0) {
    throw "No Windows binaries found under '$resolvedRoot'"
}

foreach ($binary in $binaries) {
    Assert-PeArchitecture $binary.FullName
}

$requiredFiles = @('orca-slicer.exe', 'swscale-8.dll')
foreach ($required in $requiredFiles) {
    $matches = @($binaries | Where-Object { $_.Name -eq $required })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one '$required' under '$resolvedRoot'; found $($matches.Count)"
    }
}

Write-Host "Validated $($binaries.Count) $Architecture Windows binaries in $resolvedRoot"

if ($InstallerPath) {
    $resolvedInstaller = (Resolve-Path $InstallerPath).Path

    $extractDir = Join-Path $env:RUNNER_TEMP "orcaslicer-installer-$Architecture-$PID"
    New-Item -ItemType Directory -Path $extractDir | Out-Null
    try {
        & 'C:\Program Files\7-Zip\7z.exe' x -y "-o$extractDir" $resolvedInstaller | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "7-Zip failed to extract '$resolvedInstaller' (exit $LASTEXITCODE)"
        }

        foreach ($required in $requiredFiles) {
            $source = @($binaries | Where-Object { $_.Name -eq $required })[0]
            $sourceHash = (Get-FileHash $source.FullName -Algorithm SHA256).Hash
            $payloadMatches = @(Get-ChildItem $extractDir -Recurse -File -Filter $required)
            if ($payloadMatches.Count -eq 0) {
                throw "'$required' is missing from the installer"
            }

            $payload = @($payloadMatches | Where-Object {
                (Get-FileHash $_.FullName -Algorithm SHA256).Hash -eq $sourceHash
            }) | Select-Object -First 1
            if (-not $payload) {
                throw "Installer payload '$required' does not match the validated build"
            }
            Assert-PeArchitecture $payload.FullName
        }
    } finally {
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Validated the $Architecture NSIS installer payload: $resolvedInstaller"
}
