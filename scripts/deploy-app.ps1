[CmdletBinding()]
param(
    [ValidateRange(10, 600)]
    [int]$TimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$NodesFile = Join-Path $ProjectRoot "config\noeuds.yml"

function Get-AppNodes {
    $nodes = @()
    $current = $null

    foreach ($line in Get-Content -LiteralPath $NodesFile) {
        if ($line -match '^\s*-\s+:nom:\s*(\S+)\s*$') {
            $current = [ordered]@{ Name = $Matches[1]; Ip = $null; Role = $null }
        }
        elseif ($null -ne $current -and $line -match '^\s*:ip:\s*(\S+)\s*$') {
            $current.Ip = $Matches[1]
        }
        elseif ($null -ne $current -and $line -match '^\s*:role:\s*(\S+)\s*$') {
            $current.Role = $Matches[1]
            if ($current.Role -eq "app") {
                $nodes += [pscustomobject]$current
            }
            $current = $null
        }
    }

    return $nodes
}

function Test-AppHealth([string]$Ip) {
    try {
        $response = Invoke-WebRequest -UseBasicParsing `
            -Uri "http://${Ip}:3000/sante" -TimeoutSec 3
        return $response.StatusCode -eq 200
    }
    catch {
        return $false
    }
}

function Wait-AppHealth([pscustomobject]$Node) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-AppHealth $Node.Ip) {
            Write-Host "$($Node.Name) est de nouveau sain."
            return
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    throw "$($Node.Name) n'est pas redevenu sain apres $TimeoutSeconds secondes."
}

if (-not (Get-Command vagrant -ErrorAction SilentlyContinue)) {
    throw "Vagrant est introuvable dans le PATH."
}

$appNodes = @(Get-AppNodes)
if ($appNodes.Count -lt 2) {
    throw "E4 exige au moins deux serveurs applicatifs."
}

$healthyNodes = @($appNodes | Where-Object { Test-AppHealth $_.Ip })
if ($healthyNodes.Count -ne $appNodes.Count) {
    throw "Toutes les applications doivent etre saines avant le deploiement."
}

Push-Location $ProjectRoot
try {
    foreach ($node in $appNodes) {
        $healthyOthers = @(
            $appNodes |
                Where-Object { $_.Name -ne $node.Name -and (Test-AppHealth $_.Ip) }
        )
        if ($healthyOthers.Count -lt 1) {
            throw "Aucun autre serveur sain avant la mise a jour de $($node.Name)."
        }

        Write-Host "Mise a jour de $($node.Name)..."
        & vagrant provision $node.Name
        if ($LASTEXITCODE -ne 0) {
            throw "Le provisionnement de $($node.Name) a echoue."
        }

        Wait-AppHealth $node
        Start-Sleep -Seconds 3
    }
}
finally {
    Pop-Location
}

Write-Host "Deploiement applicatif termine sans interrompre la rotation."
