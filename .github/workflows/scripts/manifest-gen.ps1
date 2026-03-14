<#
.SYNOPSIS
    Campaign Registry Hydrator V2.0.0 - Comprehensive Remote Edition
.DESCRIPTION
    Hydrates the campaign-registry.json manifest using GitHub API.
    Enforces "Parent 1" resolution and the "Locked 8" persistence rules.
    Strictly avoids system-reserved variable names and handles API authentication.
#>
param (
    [string]$RequestedCampaignSlug,
    [switch]$EnableDebugMode
)

$ErrorActionPreference = "Stop"

# --- 1. Environment & API Setup ---
$ManifestFilePath = "assets/campaign-registry.json"
if (-not (Test-Path $ManifestFilePath)) {
    Write-Error "CRITICAL: Manifest not found at $ManifestFilePath."
    exit 1
}

$RegistryData = Get-Content $ManifestFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
$ActiveCampaignKey = if ([string]::IsNullOrWhiteSpace($RequestedCampaignSlug)) { $RegistryData.activeCampaign } else { $RequestedCampaignSlug }
$TargetCampaign = $RegistryData.campaigns.$ActiveCampaignKey

if ($null -eq $TargetCampaign) {
    Write-Error "CRITICAL: Campaign '$ActiveCampaignKey' not found in registry."
    exit 1
}

# Setup Authentication Headers
$RequestHeaders = @{ 
    "Accept" = "application/vnd.github.v3+json"
}

# Check for GITHUB_TOKEN in environment to bypass rate limits (60 -> 5000 requests/hr)
if ($env:GITHUB_TOKEN) {
    $RequestHeaders.Add("Authorization", "Bearer $env:GITHUB_TOKEN")
    if ($EnableDebugMode) { Write-Host "[DEBUG] Auth: Using GITHUB_TOKEN for authenticated requests." -ForegroundColor Gray }
} else {
    Write-Warning "No GITHUB_TOKEN found. You may hit API rate limits (60 req/hr)."
}

$RemoteApiUrl = "https://api.github.com/repos/$($TargetCampaign.repository)/contents/$($TargetCampaign.paths.json)?ref=$($TargetCampaign.branch)"

Write-Host "`n>>> Initializing Hydration: $($TargetCampaign.name)" -ForegroundColor Cyan
Write-Host ">>> Repository: $($TargetCampaign.repository) [$($TargetCampaign.branch)]" -ForegroundColor Gray

try {
    # Fetch file list
    $RemoteFileMetadata = Invoke-RestMethod -Uri $RemoteApiUrl -Method Get -Headers $RequestHeaders
    $ValidJsonFiles = $RemoteFileMetadata | Where-Object { $_.name -like "*.json" }
    Write-Host ">>> Located $($ValidJsonFiles.Count) JSON files in the remote repository." -ForegroundColor Green
} catch {
    Write-Error "CRITICAL: Access Denied to remote files. Verify repo path/branch or Token permissions."
    exit 1
}

$ProcessedChannelIdentifiers = New-Object 'System.Collections.Generic.HashSet[string]'

# --- 2. Advanced ID Resolution (Parent 1 Logic) ---
function Resolve-TargetChannelReference($MessageList) {
    if ($null -eq $MessageList -or $MessageList.Count -eq 0) { return $null }

    # Priority 1: Parent 1 Rule
    foreach ($CurrentMsg in $MessageList) {
        if ($null -ne $CurrentMsg.thread -and [string]$CurrentMsg.thread.parent_id -eq "1") {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID RESOLUTION: Priority 1 (Parent 1 Metadata) matched." -ForegroundColor Gray }
            return [string]$CurrentMsg.channel_id
        }
    }

    # Priority 2: Valid Snowflake Parent
    foreach ($CurrentMsg in $MessageList) {
        $ExtractedParentValue = [string]$CurrentMsg.thread.parent_id
        if ($null -ne $ExtractedParentValue -and $ExtractedParentValue.Length -gt 10 -and $ExtractedParentValue -ne "1") {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID RESOLUTION: Priority 2 (Snowflake Parent) matched." -ForegroundColor Gray }
            return $ExtractedParentValue
        }
    }

    # Priority 3: First Valid Channel ID
    foreach ($CurrentMsg in $MessageList) {
        $ExtractedChannelValue = [string]$CurrentMsg.channel_id
        if ($null -ne $ExtractedChannelValue -and $ExtractedChannelValue.Length -gt 10) { 
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID RESOLUTION: Priority 3 (Standard ID) matched." -ForegroundColor Gray }
            return $ExtractedChannelValue 
        }
    }

    # Priority 4: Majority Rule Fallback
    $FilteredIds = $MessageList | ForEach-Object { [string]$_.channel_id } | Where-Object { 
        $_ -ne "1" -and $_ -ne "0" -and -not [string]::IsNullOrWhiteSpace($_) 
    }
    if ($null -ne $FilteredIds) {
        $Groups = $FilteredIds | Group-Object | Sort-Object Count -Descending
        if ($EnableDebugMode) { Write-Host "[DEBUG] ID RESOLUTION: Priority 4 (Majority Rule) matched." -ForegroundColor Gray }
        return [string]$Groups[0].Name
    }
    return $null
}

# --- 3. Core Hydration Loop ---
foreach ($RemoteFile in $ValidJsonFiles) {
    $CurrentFileName = $RemoteFile.name
    try {
        if ($EnableDebugMode) { Write-Host "`n[DEBUG] PROCESSING: $CurrentFileName" -ForegroundColor Cyan }
        
        # Download Content
        $JsonPayload = Invoke-RestMethod -Uri $RemoteFile.download_url -Headers $RequestHeaders
        
        # Format Normalization
        $WorkableMessages = if ($JsonPayload.PSObject.Properties.Name -contains "messages") { $JsonPayload.messages } else { $JsonPayload }
        if ($WorkableMessages -isnot [array]) { $WorkableMessages = @($WorkableMessages) }

        $ResolvedChannelRef = Resolve-TargetChannelReference $WorkableMessages
        
        # Identity Matching (Dual-Key)
        $TargetLogRecord = $TargetCampaign.logs | Where-Object { [string]$_.channelID -eq $ResolvedChannelRef -and -not [string]::IsNullOrWhiteSpace($ResolvedChannelRef) }
        $MatchTypeString = "ID Match"
        
        if ($null -eq $TargetLogRecord) {
            $TargetLogRecord = $TargetCampaign.logs | Where-Object { $_.fileName -ieq $CurrentFileName }
            $MatchTypeString = "Filename Match"
        }

        # Narrative Stats
        $NarrativeFilter = "^(0|19|Default|Reply)$"
        $MainFeedMessages = $WorkableMessages | Where-Object { 
            $MsgTypeStr = [string]$_.type
            $IsNarrative = -not [string]::IsNullOrWhiteSpace($MsgTypeStr) -and $MsgTypeStr -match $NarrativeFilter
            $IsMainChapterFeed = [string]$_.thread.id -eq $ResolvedChannelRef -or $null -eq $_.thread
            return ($IsNarrative -and $IsMainChapterFeed)
        }
        $PostTally = $MainFeedMessages.Count
        $LatestTimestamp = ($WorkableMessages | Sort-Object timestamp -Descending | Select-Object -First 1).timestamp

        # Thread Grouping (Exclude main chapter ID and self-parenting loops)
        $DetectedThreadGroups = $WorkableMessages | Where-Object { 
            $LoopThreadId = [string]$_.thread.id
            $LoopThreadParent = [string]$_.thread.parent_id
            -not [string]::IsNullOrWhiteSpace($LoopThreadId) -and $LoopThreadId -ne $ResolvedChannelRef -and $LoopThreadId -ne $LoopThreadParent
        } | Group-Object { [string]$_.thread.id }

        # Output Summary (Normal Mode)
        $ShortName = if ($CurrentFileName.Length -gt 30) { $CurrentFileName.Substring(0, 27) + "..." } else { $CurrentFileName.PadRight(30) }
        Write-Host "File: $ShortName | ID: $($ResolvedChannelRef ?? 'MISSING') | Posts: $($PostTally.ToString().PadLeft(4)) | Threads: $($DetectedThreadGroups.Count)" -ForegroundColor Gray

        if ($null -eq $TargetLogRecord) {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ACTION: Initializing new record." -ForegroundColor Yellow }
            $MaxOrderValue = if ($TargetCampaign.logs.Count -gt 0) { ($TargetCampaign.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
            
            $TargetLogRecord = [PSCustomObject]@{
                title = $CurrentFileName.Split('.')[0].Replace("_", " "); channelID = [string]$ResolvedChannelRef; fileName = $CurrentFileName;
                isActive = $true; isNSFW = $false; preview = ""; order = $MaxOrderValue + 1;
                messageCount = $PostTally; lastMessageTimestamp = $LatestTimestamp; threads = @()
            }
            $TargetCampaign.logs += $TargetLogRecord
        } else {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ACTION: Merging via ${MatchTypeString}: '$($TargetLogRecord.title)'" -ForegroundColor Yellow }
            
            if ([string]::IsNullOrWhiteSpace($TargetLogRecord.channelID)) { $TargetLogRecord.channelID = [string]$ResolvedChannelRef }
            if ([string]::IsNullOrWhiteSpace($TargetLogRecord.title)) { $TargetLogRecord.title = $CurrentFileName.Split('.')[0].Replace("_", " ") }
            if ($null -eq $TargetLogRecord.order) { 
                $InternalMaxVal = if ($TargetCampaign.logs.Count -gt 0) { ($TargetCampaign.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
                $TargetLogRecord.order = $InternalMaxVal + 1 
            }
            if ($TargetLogRecord.isActive -ne $false) { $TargetLogRecord.isActive = $true }

            $TargetLogRecord.fileName = $CurrentFileName
            $TargetLogRecord.messageCount = $PostTally
            $TargetLogRecord.lastMessageTimestamp = $LatestTimestamp
        }

        # Thread Persistence
        $FinalThreads = New-Object System.Collections.Generic.List[PSObject]
        foreach ($Group in $DetectedThreadGroups) {
            $LookupThreadId = [string]$Group.Name
            $StoredThread = $TargetLogRecord.threads | Where-Object { [string]$_.threadID -eq $LookupThreadId }
            $ThreadPostTally = ($Group.Group | Where-Object { [string]$_.type -match $NarrativeFilter }).Count

            if ($null -ne $StoredThread) {
                $StoredThread.messageCount = $ThreadPostTally
                if ([string]::IsNullOrWhiteSpace($StoredThread.displayName)) { $StoredThread.displayName = $Group.Group[0].thread.name }
                $FinalThreads.Add($StoredThread)
            } else {
                $FinalThreads.Add([PSCustomObject]@{
                    threadID = $LookupThreadId; displayName = $Group.Group[0].thread.name;
                    isActive = $true; isNSFW = $false; messageCount = $ThreadPostTally
                })
            }
        }
        $TargetLogRecord.threads = $FinalThreads.ToArray()
        
        if (-not [string]::IsNullOrWhiteSpace($TargetLogRecord.channelID)) { [void]$ProcessedChannelIdentifiers.Add($TargetLogRecord.channelID) }

    } catch {
        Write-Warning "!! Error processing $CurrentFileName: $($_.Exception.Message)"
    }
}

# --- 4. Orphan Deactivation ---
foreach ($LogEntry in $TargetCampaign.logs) {
    if (-not $ProcessedChannelIdentifiers.Contains($LogEntry.channelID) -and -not [string]::IsNullOrWhiteSpace($LogEntry.channelID)) {
        if ($EnableDebugMode) { Write-Host "[DEBUG] ORPHAN: '$($LogEntry.title)' ID not found in repo. Set to Inactive." -ForegroundColor Red }
        $LogEntry.isActive = $false
    }
}

# --- 5. Export ---
$RegistryData | ConvertTo-Json -Depth 10 | Out-File -FilePath $ManifestFilePath -Encoding UTF8 -Force
Write-Host "`n>>> Hydration Complete. Manual edits preserved and threads refreshed." -ForegroundColor Green
