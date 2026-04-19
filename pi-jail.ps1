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
$HomeDir     = $HOME

# ── Build image if not present ───────────────────────────────────────────────
$imageExists = docker image inspect $ImageName 2>$null
if (-not $imageExists) {
    Write-Host "[pi-jail] Building image '$ImageName'..."
    docker build -t $ImageName $ScriptDir
}

# ── Ensure ~/.pi exists on host ──────────────────────────────────────────────
$piDir = Join-Path $HomeDir ".pi"
if (-not (Test-Path $piDir -PathType Container)) {
    Write-Host "[pi-jail] Creating ~/.pi..."
    New-Item -ItemType Directory -Path $piDir | Out-Null
}

# ── Normalize path for Docker on Windows (convert C:\foo → /c/foo) ───────────
function ConvertTo-DockerPath([string]$path) {
    if ($path -match '^([A-Za-z]):(.+)$') {
        $drive = $Matches[1].ToLower()
        $rest  = $Matches[2] -replace '\\', '/'
        return "/$drive$rest"
    }
    return $path -replace '\\', '/'
}

$WorkspaceDocker = ConvertTo-DockerPath $Workspace
$piDirDocker     = ConvertTo-DockerPath $piDir

# ── Base docker run args ─────────────────────────────────────────────────────
$dockerArgs = @(
    "run", "--rm", "-it",
    "--name", "pi-jail-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())",
    "--user", "1000:1000",
    "--add-host", "host.docker.internal=host-gateway",
    "-v", "${WorkspaceDocker}:${ContainerWd}",
    "-v", "${piDirDocker}:/home/user/.pi",
    "-w", $ContainerWd
)

# ── Load pi-jail.env if present ──────────────────────────────────────────────
if (Test-Path $EnvFile -PathType Leaf) {
    Write-Host "[pi-jail] Loading env from pi-jail.env"
    $EnvFileDocker = ConvertTo-DockerPath $EnvFile
    $dockerArgs += @("--env-file", $EnvFileDocker)
} else {
    Write-Host "[pi-jail] No pi-jail.env found, skipping."
}

# ── Run ──────────────────────────────────────────────────────────────────────
Write-Host "[pi-jail] Starting pi in: $ContainerWd"
$dockerArgs += @($ImageName)
if ($PiArgs) { $dockerArgs += $PiArgs }

& docker @dockerArgs
