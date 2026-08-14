param(
    [string]$NettingAddress = $env:NETTING_ADDRESS,
    [string]$PrivateKey = $env:PRIVATE_KEY,
    [string]$RpcUrl = $(if ($env:RPC_URL) { $env:RPC_URL } else { "http://127.0.0.1:8545" }),
    [ValidateRange(1, 60)]
    [int]$PollSeconds = 1
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Get-Command cast -ErrorAction SilentlyContinue)) {
    throw "cast was not found. Install Foundry and add it to PATH."
}

if ([string]::IsNullOrWhiteSpace($NettingAddress)) {
    throw "Set NETTING_ADDRESS or pass -NettingAddress."
}

if ([string]::IsNullOrWhiteSpace($PrivateKey)) {
    throw "Set PRIVATE_KEY or pass -PrivateKey."
}

function Get-AutomationState {
    $output = & cast call $NettingAddress "automationState()(bool,bool)" --rpc-url $RpcUrl 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw ($output -join [Environment]::NewLine)
    }

    $flagMatches = [regex]::Matches(($output -join " "), "\b(?:true|false)\b")

    if ($flagMatches.Count -lt 2) {
        throw "Could not decode automationState(): $($output -join ' ')"
    }

    return @($flagMatches[0].Value -eq "true", $flagMatches[1].Value -eq "true")
}

function Send-NettingTransaction([string]$Signature) {
    $output = & cast send $NettingAddress $Signature --private-key $PrivateKey --rpc-url $RpcUrl --json 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw ($output -join [Environment]::NewLine)
    }
}

Write-Host "NettedX automatic window operator is running." -ForegroundColor Green
Write-Host "RPC: $RpcUrl"
Write-Host "Netting: $NettingAddress"
Write-Host "Press Ctrl+C to stop."

while ($true) {
    try {
        $state = Get-AutomationState
        $freezeNeeded = [bool]$state[0]
        $settlementNeeded = [bool]$state[1]

        if ($freezeNeeded) {
            Send-NettingTransaction "freezeWindow()"
            Write-Host "Window frozen." -ForegroundColor Cyan
        }

        if ($settlementNeeded) {
            Send-NettingTransaction "executeWindow()"
            Write-Host "Window settlement executed." -ForegroundColor Cyan
        }
    }
    catch {
        Write-Warning ("Automation poll failed: " + $_.Exception.Message)
    }

    Start-Sleep -Seconds $PollSeconds
}
