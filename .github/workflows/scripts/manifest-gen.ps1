<#
.SYNOPSIS
    Campaign Registry Hydrator V2.0.0 - Final Production Edition
.DESCRIPTION
    Hydrates campaign-registry.json via GitHub API. 
    Strict Parent 1/Locked 8 logic. 0% reserved variable usage.
#>
param (
    [string]$RequestedCampaignSlug,
    [switch]$EnableDebugMode
)

$ErrorActionPreference = "Stop"

# --- 1. Setup & Auth ---
$ManifestFilePath = "assets/campaign-registry.json"
if (-not (Test-Path $ManifestFilePath)) { Write-Error "Manifest missing at $ManifestFilePath."; exit 1 }

$RegistryData = Get-Content $ManifestFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
$ActiveKey = if ([string]::IsNullOrWhiteSpace($RequestedCampaignSlug)) { $RegistryData.activeCampaign } else { $RequestedCampaignSlug }
$TargetCampaign = $RegistryData.campaigns.$ActiveKey

$RequestHeaders = @{ "Accept" = "application/vnd.github.v3+json" }
if ($env:GITHUB_TOKEN) { $RequestHeaders.Add("Authorization", "Bearer $env:GITHUB_TOKEN") }

$RemoteApiUrl = "https://api.github.com/repos/$($TargetCampaign.repository)/contents/$($TargetCampaign.paths.json)?ref=$($TargetCampaign.branch)"

Write-Host "`n>>> Hydrating: $($TargetCampaign.name)" -ForegroundColor Cyan

try {
    $RemoteFiles = Invoke-RestMethod -Uri $RemoteApiUrl -Method Get -Headers $RequestHeaders
    $ValidFiles = $RemoteFiles | Where-Object { $_.name -like "*.json" }
} catch {
    Write-Error "API Access Failed: $($_.Exception.Message)"; exit 1
}

$ProcessedIdentifiers = New-Object 'System.Collections.Generic.HashSet[string]'

# --- 2. Robust ID Resolver ---
function Resolve-TargetChannelID($MessageList) {
    if ($null -eq $MessageList -or $MessageList.Count -eq 0) { return $null }

    # Priority 1: Parent 1 Rule
    foreach ($m in $MessageList) {
        if ($null -ne $m.thread -and [string]$m.thread.parent_id -eq "1") {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID: Priority 1 (Parent 1) matched: $($m.channel_id)" -ForegroundColor Gray }
            return [string]$m.channel_id
        }
    }

    # Priority 2: Majority Rule (Most Frequent Channel ID)
    # This correctly identifies Preludes as the thread ID, rather than the parent category.
    $IdTally = $MessageList | ForEach-Object { 
        if ($_.channel_id) { [string]$_.channel_id } elseif ($_.channelID) { [string]$_.channelID }
    } | Where-Object { $_ -ne "1" -and $_ -ne "0" -and -not [string]::IsNullOrWhiteSpace($_) }

    if ($null -ne $IdTally) {
        $Winner = ($IdTally | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
        if ($EnableDebugMode) { Write-Host "[DEBUG] ID: Priority 2 (Majority) matched: $Winner" -ForegroundColor Gray }
        return $Winner
    }

    return $null
}

# --- 3. Main Loop ---
foreach ($RemoteFile in $ValidFiles) {
    $Name = $RemoteFile.name
    try {
        if ($EnableDebugMode) { Write-Host "`n[DEBUG] --- Processing: ${Name} ---" -ForegroundColor Cyan }
        
        # Download and force conversion to ensure property access
        $RawJson = Invoke-RestMethod -Uri $RemoteFile.download_url -Headers $RequestHeaders
        $Messages = if ($RawJson.PSObject.Properties.Name -contains "messages") { $RawJson.messages } else { $RawJson }
        if ($Messages -isnot [array]) { $Messages = @($Messages) }

        if ($EnableDebugMode) { Write-Host "[DEBUG] Message Count: $($Messages.Count)" -ForegroundColor Gray }

        $ResolvedID = Resolve-TargetChannelID $Messages
        
        # Dual-Key Match
        $Record = $TargetCampaign.logs | Where-Object { [string]$_.channelID -eq $ResolvedID -and -not [string]::IsNullOrWhiteSpace($ResolvedID) }
        $MatchStyle = "ID Match"
        if ($null -eq $Record) {
            $Record = $TargetCampaign.logs | Where-Object { $_.fileName -ieq $Name }
            $MatchStyle = "Filename Match"
        }

        # Narrative Filter
        $Filter = "^(0|19|Default|Reply)$"
        $MainPosts = $Messages | Where-Object { 
            $Type = [string]$_.type
            $IsNarrative = -not [string]::IsNullOrWhiteSpace($Type) -and $Type -match $Filter
            $Chan = if ($_.channel_id) { [string]$_.channel_id } else { [string]$_.channelID }
            return ($IsNarrative -and ($Chan -eq $ResolvedID))
        }
        
        $PostCount = $MainPosts.Count
        $LastTS = ($Messages | Sort-Object timestamp -Descending | Select-Object -First 1).timestamp

        # Thread Grouping (Apply user exclusion: ID cannot equal Parent)
        $ThreadGroups = $Messages | Where-Object { 
            $Tid = [string]$_.thread.id
            $Tpid = [string]$_.thread.parent_id
            -not [string]::IsNullOrWhiteSpace($Tid) -and $Tid -ne $ResolvedID -and $Tid -ne $Tpid
        } | Group-Object { [string]$_.thread.id }

        # LOG SUMMARY
        $DispName = if ($Name.Length -gt 25) { $Name.Substring(0, 22) + "..." } else { $Name.PadRight(25) }
        Write-Host "File: ${DispName} | ID: $($ResolvedID.PadRight(20)) | Posts: $($PostCount.ToString().PadLeft(4)) | Threads: $($ThreadGroups.Count)" -ForegroundColor Gray

        if ($null -eq $Record) {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ACTION: Creating New Entry." -ForegroundColor Yellow }
            $MaxO = if ($TargetCampaign.logs.Count -gt 0) { ($TargetCampaign.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
            $Record = [PSCustomObject]@{
                title = $Name.Split('.')[0].Replace("_", " "); channelID = [string]$ResolvedID; fileName = $Name;
                isActive = $true; isNSFW = $false; preview = ""; order = $MaxO + 1;
                messageCount = $PostCount; lastMessageTimestamp = $LastTS; threads = @()
            }
            $TargetCampaign.logs += $Record
        } else {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ACTION: Merging via ${MatchStyle}: '$($Record.title)'" -ForegroundColor Yellow }
            if ([string]::IsNullOrWhiteSpace($Record.channelID)) { $Record.channelID = [string]$ResolvedID }
            if ([string]::IsNullOrWhiteSpace($Record.title)) { $Record.title = $Name.Split('.')[0].Replace("_", " ") }
            if ($null -eq $Record.order) { 
                $InternalMax = if ($TargetCampaign.logs.Count -gt 0) { ($TargetCampaign.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
                $Record.order = $InternalMax + 1 
            }
            if ($Record.isActive -ne $false) { $Record.isActive = $true }
            $Record.fileName = $Name
            $Record.messageCount = $PostCount
            $Record.lastMessageTimestamp = $LastTS
        }

        # Threads
        $FinalT = New-Object System.Collections.Generic.List[PSObject]
        foreach ($G in $ThreadGroups) {
            $TidLookup = [string]$G.Name
            $StoredT = $Record.threads | Where-Object { [string]$_.threadID -eq $TidLookup }
            $TCount = ($G.Group | Where-Object { [string]$_.type -match $Filter }).Count
            if ($null -ne $StoredT) {
                $StoredT.messageCount = $TCount
                if ([string]::IsNullOrWhiteSpace($StoredT.displayName)) { $StoredT.displayName = $G.Group[0].thread.name }
                $FinalT.Add($StoredT)
            } else {
                $FinalT.Add([PSCustomObject]@{ threadID = $TidLookup; displayName = $G.Group[0].thread.name; isActive = $true; isNSFW = $false; messageCount = $TCount })
            }
        }
        $Record.threads = $FinalT.ToArray()
        if (-not [string]::IsNullOrWhiteSpace($Record.channelID)) { [void]$ProcessedIdentifiers.Add($Record.channelID) }

    } catch { Write-Warning "!! Error in ${Name}: $($_.Exception.Message)" }
}

# --- 4. Orphans ---
foreach ($Entry in $TargetCampaign.logs) {
    if (-not $ProcessedIdentifiers.Contains($Entry.channelID) -and -not [string]::IsNullOrWhiteSpace($Entry.channelID)) {
        $Entry.isActive = $false
    }
}

# --- 5. Export ---
$RegistryData | ConvertTo-Json -Depth 10 | Out-File -FilePath $ManifestFilePath -Encoding UTF8 -Force
Write-Host "`n>>> Success: Registry updated." -ForegroundColor Green
