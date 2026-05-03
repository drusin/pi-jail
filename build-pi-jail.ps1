#!/usr/bin/env pwsh

param(
    [switch]$Dry
)

$Package = '@mariozechner/pi-coding-agent'

Write-Host "🔍 Querying npm for latest version of $Package..."

try {
    $Response = Invoke-RestMethod -Uri "https://registry.npmjs.org/$Package/latest" -ErrorAction Stop
    $Version = $Response.version
} catch {
    Write-Host "❌ Failed to retrieve latest version from npm registry." -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrEmpty($Version)) {
    Write-Host "❌ Failed to retrieve latest version from npm registry." -ForegroundColor Red
    exit 1
}

Write-Host "✅ Latest version: $Version"
Write-Host ""

$DockerCmd = "docker build --build-arg PI_VERSION=$Version -t pi-jail ."

if ($Dry) {
    Write-Host "🏗️  Dry run — would execute:"
    Write-Host ""
    Write-Host "    $DockerCmd"
} else {
    Write-Host "🏗️  Building pi-jail image with pi-coding-agent@${Version}..."
    Write-Host ""
    Invoke-Expression $DockerCmd
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "✅ Done! Image 'pi-jail' built with pi-coding-agent@${Version}."
    } else {
        Write-Host ""
        Write-Host "❌ Build failed." -ForegroundColor Red
        exit $LASTEXITCODE
    }
}