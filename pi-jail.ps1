param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$PiArgs
)

$ErrorActionPreference = "Stop"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ImageName   = "pi-jail"
$EnvFile     = Join-Path $ScriptDir "pi-jail.env"
$Workspace   = (Get-Location).Path
$FolderName  = Split-Path -Leaf $Workspace
$ContainerWd = "/workspace/$FolderName"
$NameSuffix  = (($FolderName.ToLower() -replace '[^a-z0-9_.-]+', '-').Trim('-'))
if ([string]::IsNullOrWhiteSpace($NameSuffix)) { $NameSuffix = "workspace" }
$ContainerName = "pi-jail-$NameSuffix"
$HomeDir     = $HOME

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
    "--add-host", "host.docker.internal=host-gateway",
    "-v", "${WorkspaceHost}:${ContainerWd}",
    "-v", "${piDirHost}:/home/user/.pi",
    "-w", $ContainerWd
)

# ── Load pi-jail.env if present ──────────────────────────────────────────────
if (Test-Path $EnvFile -PathType Leaf) {
    Write-Host "[pi-jail] Loading env from pi-jail.env"
    $EnvFileHost = (Resolve-Path -LiteralPath $EnvFile).Path
    $dockerArgs += @("--env-file", $EnvFileHost)
} else {
    Write-Host "[pi-jail] No pi-jail.env found, skipping."
}

# ── Run ──────────────────────────────────────────────────────────────────────
Write-Host "[pi-jail] Starting pi in: $ContainerWd"
$dockerArgs += @($ImageName)
if ($PiArgs) { $dockerArgs += $PiArgs }

& docker @dockerArgs
