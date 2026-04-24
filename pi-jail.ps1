#Requires -Version 7.0

$PiArgs = $args

# Parse launcher flags
$NoWorkspace = $false
$AdHocRunOnHostValues = @()
$FilteredArgs = @()
for ($i = 0; $i -lt $PiArgs.Count; $i++) {
    $arg = $PiArgs[$i]
    if ($arg -eq "--no-workspace") {
        $NoWorkspace = $true
    } elseif ($arg -like "--run-on-host=*") {
        $AdHocRunOnHostValues += $arg.Substring("--run-on-host=".Length)
    } elseif ($arg -eq "--run-on-host") {
        if ($i + 1 -ge $PiArgs.Count) {
            throw "[pi-jail] Error: --run-on-host requires a value."
        }

        $i += 1
        $AdHocRunOnHostValues += $PiArgs[$i]
    } else {
        $FilteredArgs += $arg
    }
}

$ErrorActionPreference = "Stop"

$PowerShellExecutable = Join-Path $PSHOME "pwsh.exe"

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

function Add-RunOnHostCommands {
    param(
        [AllowNull()]
        [string]$Value,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.IList]$Commands
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    foreach ($entry in $Value.Split(',')) {
        $command = $entry.Trim()
        if ([string]::IsNullOrWhiteSpace($command)) {
            continue
        }

        if (-not $Commands.Contains($command)) {
            $Commands.Add($command)
        }
    }
}

function New-HostExecToken {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }

    return ([Convert]::ToBase64String($bytes)).TrimEnd('=') -replace '\+', '-' -replace '/', '_'
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Wait-HostExecServer {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        [int]$TimeoutMilliseconds = 5000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Process.HasExited) {
            throw "[pi-jail] Host exec server exited unexpectedly."
        }

        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $connectTask = $client.ConnectAsync('127.0.0.1', $Port)
            if ($connectTask.Wait(200) -and $client.Connected) {
                return
            }
        } catch {
        } finally {
            $client.Dispose()
        }

        Start-Sleep -Milliseconds 100
    }

    throw "[pi-jail] Timed out waiting for host exec server on port $Port."
}

function Get-EmbeddedHostExecServerScript {
    return @'
param(
    [Parameter(Mandatory = $true)]
    [int]$Port,
    [Parameter(Mandatory = $true)]
    [string]$Token,
    [Parameter(Mandatory = $true)]
    [string]$Workspace
)

$ErrorActionPreference = "Stop"

function ConvertTo-HostExecBase64 {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        $Value = ""
    }

    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Value))
}

function ConvertFrom-HostExecBase64 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

function Send-HostExecFrame {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.StreamWriter]$Writer,
        [Parameter(Mandatory = $true)]
        [string]$Type,
        [string]$Value = ""
    )

    if ([string]::IsNullOrEmpty($Value)) {
        $Writer.WriteLine($Type)
    } else {
        $Writer.WriteLine("$Type $Value")
    }
    $Writer.Flush()
}

function Send-HostExecData {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.StreamWriter]$Writer,
        [Parameter(Mandatory = $true)]
        [string]$Type,
        [AllowNull()]
        [string]$Data
    )

    Send-HostExecFrame -Writer $Writer -Type $Type -Value (ConvertTo-HostExecBase64 -Value $Data)
}

function Quote-WindowsArgument {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $escaped = $Value -replace '(\\*)"', '$1$1\\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Join-WindowsArguments {
    param(
        [AllowNull()]
        [object[]]$Arguments
    )

    if ($null -eq $Arguments -or $Arguments.Count -eq 0) {
        return ""
    }

    return (($Arguments | ForEach-Object { Quote-WindowsArgument -Value ([string]$_) }) -join ' ')
}

function Resolve-HostExecCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    $candidates = @(Get-Command -Name $Command -ErrorAction SilentlyContinue)
    if ($candidates.Count -eq 0) {
        return $null
    }

    $preferred = $candidates |
        Where-Object { $_.Source } |
        Sort-Object {
            switch ([System.IO.Path]::GetExtension($_.Source).ToLowerInvariant()) {
                '.exe' { 0; break }
                '.cmd' { 1; break }
                '.bat' { 2; break }
                '.com' { 3; break }
                '.ps1' { 4; break }
                default { 9; break }
            }
        } |
        Select-Object -First 1

    if (-not $preferred) {
        return $null
    }

    return $preferred.Source
}

function Invoke-HostCommand {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.StreamWriter]$Writer,
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [AllowNull()]
        [object[]]$Arguments
    )

    $resolvedCommand = Resolve-HostExecCommand -Command $Command
    if ([string]::IsNullOrWhiteSpace($resolvedCommand)) {
        Send-HostExecData -Writer $Writer -Type "STDERR" -Data ("Command not found: $Command" + [Environment]::NewLine)
        Send-HostExecFrame -Writer $Writer -Type "EXIT" -Value "127"
        return
    }

    $argumentString = Join-WindowsArguments -Arguments $Arguments
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.WorkingDirectory = $Workspace
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $extension = [System.IO.Path]::GetExtension($resolvedCommand).ToLowerInvariant()
    if ($extension -in @('.cmd', '.bat')) {
        $cmdExe = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        $quotedCommand = Quote-WindowsArgument -Value $resolvedCommand
        $commandLine = if ([string]::IsNullOrEmpty($argumentString)) { $quotedCommand } else { "$quotedCommand $argumentString" }
        $startInfo.FileName = $cmdExe
        $startInfo.Arguments = "/d /s /c `"$commandLine`""
    } elseif ($extension -eq '.ps1') {
        $startInfo.FileName = $PowerShellExecutable
        $quotedCommand = Quote-WindowsArgument -Value $resolvedCommand
        $startInfo.Arguments = if ([string]::IsNullOrEmpty($argumentString)) {
            "-NoLogo -NoProfile -ExecutionPolicy Bypass -File $quotedCommand"
        } else {
            "-NoLogo -NoProfile -ExecutionPolicy Bypass -File $quotedCommand $argumentString"
        }
    } else {
        $startInfo.FileName = $resolvedCommand
        $startInfo.Arguments = $argumentString
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    try {
        $null = $process.Start()
    } catch {
        Send-HostExecData -Writer $Writer -Type "STDERR" -Data ($_.Exception.Message + [Environment]::NewLine)
        Send-HostExecFrame -Writer $Writer -Type "EXIT" -Value "127"
        return
    }

    try {
        $stdoutOpen = $true
        $stderrOpen = $true
        $stdoutTask = $process.StandardOutput.ReadLineAsync()
        $stderrTask = $process.StandardError.ReadLineAsync()

        while ($stdoutOpen -or $stderrOpen) {
            $pendingTasks = @()
            if ($stdoutOpen) { $pendingTasks += $stdoutTask }
            if ($stderrOpen) { $pendingTasks += $stderrTask }

            $completedIndex = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$pendingTasks, 100)
            if ($completedIndex -lt 0) {
                continue
            }

            $completedTask = $pendingTasks[$completedIndex]

            if ($stdoutOpen -and $completedTask -eq $stdoutTask) {
                $line = $stdoutTask.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $stdoutOpen = $false
                } else {
                    Send-HostExecData -Writer $Writer -Type "STDOUT" -Data ($line + [Environment]::NewLine)
                    $stdoutTask = $process.StandardOutput.ReadLineAsync()
                }
                continue
            }

            if ($stderrOpen -and $completedTask -eq $stderrTask) {
                $line = $stderrTask.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $stderrOpen = $false
                } else {
                    Send-HostExecData -Writer $Writer -Type "STDERR" -Data ($line + [Environment]::NewLine)
                    $stderrTask = $process.StandardError.ReadLineAsync()
                }
            }
        }

        $process.WaitForExit()
        Send-HostExecFrame -Writer $Writer -Type "EXIT" -Value ([string]$process.ExitCode)
    } finally {
        $process.Dispose()
    }
}

function Read-HostExecRequest {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.StreamReader]$Reader
    )

    $requestToken = $null
    $command = $null
    $arguments = [System.Collections.Generic.List[string]]::new()

    while ($true) {
        $line = $Reader.ReadLine()
        if ($null -eq $line) {
            return $null
        }

        if ($line -eq "") {
            continue
        }

        if ($line -eq "END") {
            break
        }

        $parts = $line.Split(' ', 2)
        $type = $parts[0]
        $value = if ($parts.Count -gt 1) { $parts[1] } else { "" }

        switch ($type) {
            "TOKEN" {
                $requestToken = ConvertFrom-HostExecBase64 -Value $value
            }
            "COMMAND" {
                $command = ConvertFrom-HostExecBase64 -Value $value
            }
            "ARG" {
                $arguments.Add((ConvertFrom-HostExecBase64 -Value $value))
            }
            default {
                throw "Invalid host exec frame type: $type"
            }
        }
    }

    return [pscustomobject]@{
        Token = $requestToken
        Command = $command
        Arguments = @($arguments)
    }
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
$listener.Start()

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $stream = $null
        $reader = $null
        $writer = $null
        try {
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false), $false, 1024, $true)
            $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false), 1024, $true)
            $writer.AutoFlush = $true

            try {
                $request = Read-HostExecRequest -Reader $reader
            } catch {
                Send-HostExecData -Writer $writer -Type "STDERR" -Data ("Invalid host exec request" + [Environment]::NewLine)
                Send-HostExecFrame -Writer $writer -Type "EXIT" -Value "125"
                continue
            }

            if ($null -eq $request) {
                continue
            }

            if ([string]::IsNullOrWhiteSpace([string]$request.Token) -or $request.Token -ne $Token) {
                Send-HostExecData -Writer $writer -Type "STDERR" -Data ("Unauthorized host exec request" + [Environment]::NewLine)
                Send-HostExecFrame -Writer $writer -Type "EXIT" -Value "126"
                continue
            }

            $command = [string]$request.Command
            if ([string]::IsNullOrWhiteSpace($command)) {
                Send-HostExecData -Writer $writer -Type "STDERR" -Data ("Missing host exec command" + [Environment]::NewLine)
                Send-HostExecFrame -Writer $writer -Type "EXIT" -Value "125"
                continue
            }

            Invoke-HostCommand -Writer $writer -Command $command -Arguments @($request.Arguments)
        } finally {
            if ($writer) { $writer.Dispose() }
            if ($reader) { $reader.Dispose() }
            if ($stream) { $stream.Dispose() }
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
}
'@
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
    "--add-host", "host.docker.internal=host-gateway",
    "-e", "HOST_SYSTEM=windows"
)
if (-not $NoWorkspace) {
    $dockerArgs += "-v"
    $dockerArgs += "${WorkspaceHost}:${ContainerWd}"
}
$dockerArgs += "-v"
$dockerArgs += "${piDirHost}:/home/user/.pi"
$dockerArgs += "-w"
$dockerArgs += $ContainerWd

$runOnHostValue = $null
$hostExecProcess = $null
$hostExecPort = $null
$hostExecToken = $null
$hostExecScriptPath = $null

# ── Load pi-jail.env if present ──────────────────────────────────────────────
if (Test-Path $EnvFile -PathType Leaf) {
    Write-Host "[pi-jail] Loading env from pi-jail.env"
    $EnvFileHost = (Resolve-Path -LiteralPath $EnvFile).Path
    $dockerArgs += @("--env-file", $EnvFileHost)

    $runOnHostValue = Get-EnvValue -Path $EnvFile -Name "RUN_ON_HOST"
} else {
    Write-Host "[pi-jail] No pi-jail.env found, skipping."
}

$runOnHostCommandsList = [System.Collections.Generic.List[string]]::new()
Add-RunOnHostCommands -Value $runOnHostValue -Commands $runOnHostCommandsList
foreach ($value in $AdHocRunOnHostValues) {
    Add-RunOnHostCommands -Value $value -Commands $runOnHostCommandsList
}
$runOnHostCommands = @($runOnHostCommandsList)
$appendSystemPrompt = $null

if ($runOnHostCommands.Count -gt 0) {
    $runOnHostJoined = $runOnHostCommands -join ','
    $dockerArgs += @("-e", "RUN_ON_HOST=$runOnHostJoined")
    $appendSystemPrompt = "Commands listed in RUN_ON_HOST ($runOnHostJoined) are executed directly on the host system (windows), not inside the container. When using those commands, use host-native syntax, paths, quoting, separators, and shell conventions. For all other commands, assume the normal container Linux/bash environment."
    $hostExecPort = Get-FreeTcpPort
    $hostExecToken = New-HostExecToken
    $hostExecScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("pi-jail-host-exec-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($hostExecScriptPath, (Get-EmbeddedHostExecServerScript), [System.Text.UTF8Encoding]::new($false))

    $hostExecProcess = Start-Process -FilePath $PowerShellExecutable `
        -ArgumentList @(
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $hostExecScriptPath,
            "-Port", [string]$hostExecPort,
            "-Token", $hostExecToken,
            "-Workspace", $WorkspaceHost
        ) `
        -PassThru `
        -WindowStyle Hidden

    Wait-HostExecServer -Port $hostExecPort -Process $hostExecProcess
    $dockerArgs += @(
        "-e", "PI_HOST_EXEC_HOST=host.docker.internal",
        "-e", "PI_HOST_EXEC_PORT=$hostExecPort",
        "-e", "PI_HOST_EXEC_TOKEN=$hostExecToken"
    )
}

# ── Run ──────────────────────────────────────────────────────────────────────
try {
    Write-Host "[pi-jail] Starting pi in: $ContainerWd"
    $dockerArgs += @($ImageName, "pi")
    if ($appendSystemPrompt) { $dockerArgs += @("--append-system-prompt", $appendSystemPrompt) }
    if ($FilteredArgs) { $dockerArgs += $FilteredArgs }

    & docker @dockerArgs
} finally {
    if ($hostExecProcess -and -not $hostExecProcess.HasExited) {
        Stop-Process -Id $hostExecProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($hostExecScriptPath -and (Test-Path -LiteralPath $hostExecScriptPath -PathType Leaf)) {
        Remove-Item -LiteralPath $hostExecScriptPath -Force -ErrorAction SilentlyContinue
    }
}
