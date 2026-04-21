param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$PiArgs
)

# Parse launcher flags
$NoWorkspace = $false
$PortSpecs = @()
$RandomPortRequests = 0
$FilteredArgs = @()
for ($i = 0; $i -lt $PiArgs.Count; $i++) {
    $arg = $PiArgs[$i]
    if ($arg -eq "--no-workspace") {
        $NoWorkspace = $true
    } elseif ($arg -eq "-p") {
        if ($i + 1 -lt $PiArgs.Count -and -not $PiArgs[$i + 1].StartsWith("-")) {
            $i++
            $PortSpecs += $PiArgs[$i]
        } else {
            $RandomPortRequests++
        }
    } else {
        $FilteredArgs += $arg
    }
}

$ErrorActionPreference = "Stop"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ImageName   = "pi-jail"
$EnvFile     = Join-Path $ScriptDir "pi-jail.env"
$Workspace   = (Get-Location).Path
$FolderName  = Split-Path -Leaf $Workspace
if ($NoWorkspace) {
    $ContainerWd = "/home/user"
} else {
    $ContainerWd = "/workspace/$FolderName"
}
$NameSuffix  = (($FolderName.ToLower() -replace '[^a-z0-9_.-]+', '-').Trim('-'))
if ([string]::IsNullOrWhiteSpace($NameSuffix)) { $NameSuffix = "workspace" }
$ContainerName = "pi-jail-$NameSuffix"
$HomeDir     = $HOME

function Get-EnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $escapedName = [regex]::Escape($Name)
    $line = Get-Content -LiteralPath $Path | Where-Object { $_ -match "^\s*$escapedName\s*=" } | Select-Object -First 1
    if (-not $line) {
        return $null
    }

    $value = ($line -replace "^\s*$escapedName\s*=\s*", "").Trim()
    if ($value.Length -ge 2 -and (
        ($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'"))
    )) {
        $value = $value.Substring(1, $value.Length - 2)
    }

    return $value
}

function Test-PortFree {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) {
            $listener.Stop()
        }
    }
}

function Find-FreePort {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$ExcludedPorts
    )

    for ($port = 9000; $port -le 65535; $port++) {
        if ($ExcludedPorts.Contains([string]$port)) {
            continue
        }

        if (Test-PortFree -Port $port) {
            return $port
        }
    }

    return $null
}

# ── Build image if not present ───────────────────────────────────────────────
$imageExists = docker image inspect $ImageName 2>$null
if (-not $imageExists) {
    Write-Host "[pi-jail] Building image '$ImageName'..."
    docker build -t $ImageName $ScriptDir
}

docker container inspect $ContainerName *> $null
if ($LASTEXITCODE -eq 0) {
    $containerRunning = (docker container inspect --format '{{.State.Running}}' $ContainerName).Trim()
    if ($containerRunning -eq "true") {
        throw "[pi-jail] Error: container '$ContainerName' is already running."
    }

    Write-Host "[pi-jail] Removing stopped container '$ContainerName'..."
    docker rm $ContainerName *> $null
}

# ── Ensure ~/.pi exists on host ──────────────────────────────────────────────
$piDir = Join-Path $HomeDir ".pi"
if (-not (Test-Path $piDir -PathType Container)) {
    Write-Host "[pi-jail] Creating ~/.pi..."
    New-Item -ItemType Directory -Path $piDir | Out-Null
}

# ── Docker Desktop on Windows expects native host paths for bind mounts and
#    --env-file. Converting C:\foo to /c/foo breaks local file resolution. ────
$WorkspaceHost = (Resolve-Path -LiteralPath $Workspace).Path
$piDirHost     = (Resolve-Path -LiteralPath $piDir).Path

# ── Base docker run args ─────────────────────────────────────────────────────
$dockerArgs = @(
    "run", "--rm", "-it",
    "--name", $ContainerName,
    "--user", "1000:1000",
    "--add-host", "host.docker.internal=host-gateway"
)
if (-not $NoWorkspace) {
    $dockerArgs += "-v"
    $dockerArgs += "${WorkspaceHost}:${ContainerWd}"
}
$dockerArgs += "-v"
$dockerArgs += "${piDirHost}:/home/user/.pi"
$dockerArgs += "-w"
$dockerArgs += $ContainerWd

# ── Load pi-jail.env if present ──────────────────────────────────────────────
if (Test-Path $EnvFile -PathType Leaf) {
    Write-Host "[pi-jail] Loading env from pi-jail.env"
    $EnvFileHost = (Resolve-Path -LiteralPath $EnvFile).Path
    $dockerArgs += @("--env-file", $EnvFileHost)

    $portsValue = Get-EnvValue -Path $EnvFile -Name "PORTS"
    if ($portsValue) {
        $PortSpecs += $portsValue
    }

    $randomPortValue = Get-EnvValue -Path $EnvFile -Name "RANDOM_PORT"
    if ($randomPortValue -and $randomPortValue.ToLowerInvariant() -eq "true") {
        $RandomPortRequests++
    }
} else {
    Write-Host "[pi-jail] No pi-jail.env found, skipping."
}

$seenPorts = [System.Collections.Generic.HashSet[string]]::new()
$busyPorts = @()
$boundPorts = @()
$randomPortFailures = 0

if ($PortSpecs.Count -gt 0) {
    foreach ($portSpec in $PortSpecs) {
        foreach ($port in ($portSpec -split ',')) {
            $port = $port.Trim()
            if (-not $port) { continue }

            if ($port -notmatch '^\d+$') {
                Write-Warning "[pi-jail] Ignoring invalid port '$port'"
                continue
            }

            $portNumber = [int]$port
            if ($portNumber -lt 1 -or $portNumber -gt 65535) {
                Write-Warning "[pi-jail] Ignoring invalid port '$port'"
                continue
            }

            if (-not $seenPorts.Add([string]$portNumber)) {
                continue
            }

            if (Test-PortFree -Port $portNumber) {
                $dockerArgs += @("-p", "$portNumber`:$portNumber")
                $boundPorts += $portNumber
            } else {
                $busyPorts += $portNumber
            }
        }
    }
}

if ($RandomPortRequests -gt 0) {
    for ($i = 0; $i -lt $RandomPortRequests; $i++) {
        $portNumber = Find-FreePort -ExcludedPorts $seenPorts
        if ($null -eq $portNumber) {
            $randomPortFailures++
            continue
        }

        $null = $seenPorts.Add([string]$portNumber)
        $dockerArgs += @("-p", "$portNumber`:$portNumber")
        $boundPorts += $portNumber
    }
}

if ($busyPorts.Count -gt 0) {
    Write-Warning ("[pi-jail] Not binding ports already in use: " + ($busyPorts -join ', '))
}
if ($randomPortFailures -gt 0) {
    Write-Warning "[pi-jail] Could not find $randomPortFailures free random port(s) starting at 9000"
}

$dockerArgs += @("-e", "EXPOSED_PORTS=$($boundPorts -join ',')")

# ── Run ──────────────────────────────────────────────────────────────────────
Write-Host "[pi-jail] Starting pi in: $ContainerWd"
$dockerArgs += @($ImageName, "pi")
if ($FilteredArgs) { $dockerArgs += $FilteredArgs }

& docker @dockerArgs
