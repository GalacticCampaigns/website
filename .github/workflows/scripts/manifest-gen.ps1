<#
.SYNOPSIS
    Campaign Registry Hydrator V2.0.0 - Comprehensive Remote Edition
.DESCRIPTION
    Hydrates the campaign-registry.json manifest using GitHub API.
    Enforces "Parent 1" resolution and the "Locked 8" persistence rules.
    Strictly avoids system-reserved variable names.
#>
param (
    [string]$RequestedCampaignSlug,
    [switch]$EnableDebugMode
)

$ErrorActionPreference = "Stop"

# --- 1. Environment & API Resolution ---
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

# Construct the API URL for the REMOTE repository
$RemoteApiUrl = "https://api.github.com/repos/$($TargetCampaign.repository)/contents/$($TargetCampaign.paths.json)?ref=$($TargetCampaign.branch)"

Write-Host ">>> Initializing Hydration for: $($TargetCampaign.name)" -ForegroundColor Cyan
if ($EnableDebugMode) { Write-Host "[DEBUG] Remote API Target: $RemoteApiUrl" -ForegroundColor Gray }

try {
    # Fetch file list from GitHub (Properties are lowercase: .name, .download_url)
    $RemoteFileMetadata = Invoke-RestMethod -Uri $RemoteApiUrl -Method Get -Headers @{ "Accept" = "application/vnd.github.v3+json" }
    $ValidJsonFiles = $RemoteFileMetadata | Where-Object { $_.name -like "*.json" }
    Write-Host ">>> Located $($ValidJsonFiles.Count) JSON files in the remote repository." -ForegroundColor Green
} catch {
    Write-Error "CRITICAL: Access Denied to remote files. Verify repository permissions and branch name."
    exit 1
}

$ProcessedChannelIdentifiers = New-Object 'System.Collections.Generic.HashSet[string]'

# --- 2. Advanced ID Resolution (Parent 1 Logic) ---
function Resolve-TargetChannelReference($MessageList) {
    if ($null -eq $MessageList -or $MessageList.Count -eq 0) { return $null }

    # Priority 1: Parent 1 Rule (The Main Feed Anchor)
    foreach ($CurrentMsg in $MessageList) {
        if ($null -ne $CurrentMsg.thread -and [string]$CurrentMsg.thread.parent_id -eq "1") {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID DECISION: Priority 1 match (Parent 1 metadata found)." -ForegroundColor Gray }
            return [string]$CurrentMsg.channel_id
        }
    }

    # Priority 2: Valid Snowflake Parent (Length Check)
    foreach ($CurrentMsg in $MessageList) {
        $ExtractedParentValue = [string]$CurrentMsg.thread.parent_id
        if ($null -ne $ExtractedParentValue -and $ExtractedParentValue.Length -gt 10 -and $ExtractedParentValue -ne "1") {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID DECISION: Priority 2 match (Snowflake parent found)." -ForegroundColor Gray }
            return $ExtractedParentValue
        }
    }

    # Priority 3: Standard Export Context
    foreach ($CurrentMsg in $MessageList) {
        $ExtractedChannelValue = [string]$CurrentMsg.channel_id
        if ($null -ne $ExtractedChannelValue -and $ExtractedChannelValue.Length -gt 10) { 
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID DECISION: Priority 3 match (Standard channel_id found)." -ForegroundColor Gray }
            return $ExtractedChannelValue 
        }
    }

    # Priority 4: Majority Rule Fallback (Filters out 0, 1, and Nulls)
    $FilteredMessageIds = $MessageList | ForEach-Object { [string]$_.channel_id } | Where-Object { 
        $_ -ne "1" -and $_ -ne "0" -and -not [string]::IsNullOrWhiteSpace($_) 
    }
    if ($null -ne $FilteredMessageIds) {
        $FrequencyGroups = $FilteredMessageIds | Group-Object | Sort-Object Count -Descending
        if ($EnableDebugMode) { Write-Host "[DEBUG] ID DECISION: Priority 4 fallback (Majority Rule frequency)." -ForegroundColor Gray }
        return [string]$FrequencyGroups[0].Name
    }

    return $null
}

# --- 3. Core Hydration Loop ---
foreach ($RemoteFile in $ValidJsonFiles) {
    $CurrentFileName = $RemoteFile.name
    try {
        if ($EnableDebugMode) { Write-Host "`n[DEBUG] ANALYZING FILE: $CurrentFileName" -ForegroundColor Cyan }
        
        # Download the JSON payload
        $JsonPayload = Invoke-RestMethod -Uri $RemoteFile.download_url
        
        # Handle Nested vs Flat JSON
        $WorkableMessages = if ($JsonPayload.PSObject.Properties.Name -contains "messages") { $JsonPayload.messages } else { $JsonPayload }
        if ($WorkableMessages -isnot [array]) { $WorkableMessages = @($WorkableMessages) }

        $ResolvedChannelRef = Resolve-TargetChannelReference $WorkableMessages
        
        # Identity Matching (Dual-Key)
        $TargetLogRecord = $TargetCampaign.logs | Where-Object { [string]$_.channelID -eq $ResolvedChannelRef -and -not [string]::IsNullOrWhiteSpace($ResolvedChannelRef) }
        if ($null -eq $TargetLogRecord) {
            $TargetLogRecord = $TargetCampaign.logs | Where-Object { $_.fileName -ieq $CurrentFileName }
        }

        # Narrative Message Filter
        $NarrativeMessages = $WorkableMessages | Where-Object { 
            $MsgType = [string]$_.type
            -not [string]::IsNullOrWhiteSpace($MsgType) -and $MsgType -match "^(0|19|Default|Reply)$" 
        }
        $CurrentPostTally = $NarrativeMessages.Count
        $LatestMsgTimestamp = ($WorkableMessages | Sort-Object timestamp -Descending | Select-Object -First 1).timestamp

        # --- Normal Mode Summary ---
        Write-Host "File: $($CurrentFileName.PadRight(30)) | ID: $($ResolvedChannelRef ?? 'MISSING') | Posts: $($CurrentPostTally.ToString().PadLeft(4)) | Threads: " -NoNewline -ForegroundColor Gray

        if ($null -eq $TargetLogRecord) {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ACTION: Initializing new manifest record." -ForegroundColor Yellow }
            $HighestOrderValue = if ($TargetCampaign.logs.Count -gt 0) { ($TargetCampaign.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
            
            $TargetLogRecord = [PSCustomObject]@{
                title                = $CurrentFileName.Split('.')[0].Replace("_", " ")
                channelID            = [string]$ResolvedChannelRef
                fileName             = $CurrentFileName
                isActive             = $true
                isNSFW               = $false
                preview              = ""
                order                = $HighestOrderValue + 1
                messageCount         = $CurrentPostTally
                lastMessageTimestamp = $LatestMsgTimestamp
                threads              = @()
            }
            $TargetCampaign.logs += $TargetLogRecord
        } else {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ACTION: Merging data into existing record: '$($TargetLogRecord.title)'" -ForegroundColor Yellow }
            
            # Locked 8 Merging Rules
            if ([string]::IsNullOrWhiteSpace($TargetLogRecord.channelID)) { $TargetLogRecord.channelID = [string]$ResolvedChannelRef }
            if ([string]::IsNullOrWhiteSpace($TargetLogRecord.title)) { $TargetLogRecord.title = $CurrentFileName.Split('.')[0].Replace("_", " ") }
            if ($null -eq $TargetLogRecord.order) { 
                $InternalOrderMax = if ($TargetCampaign.logs.Count -gt 0) { ($TargetCampaign.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
                $TargetLogRecord.order = $InternalOrderMax + 1 
            }
            if ($TargetLogRecord.isActive -ne $false) { $TargetLogRecord.isActive = $true }

            # Refresh Volatile Metadata
            $TargetLogRecord.fileName = $CurrentFileName
            $TargetLogRecord.messageCount = $CurrentPostTally
            $TargetLogRecord.lastMessageTimestamp = $LatestMsgTimestamp
        }

        # --- Thread Management ---
        # Logic: Exclude if Thread ID matches resolved Main Channel OR Thread ID matches its own Parent ID
        $DetectedThreadGroups = $WorkableMessages | Where-Object { 
            $CurrentThreadId = [string]$_.thread.id
            $CurrentThreadParent = [string]$_.thread.parent_id
            $CurrentThreadId -ne $ResolvedChannelRef -and $CurrentThreadId -ne $CurrentThreadParent -and -not [string]::IsNullOrWhiteSpace($CurrentThreadId) 
        } | Group-Object { [string]$_.thread.id }

        # Finish Normal Mode Summary
        Write-Host "$($DetectedThreadGroups.Count)" -ForegroundColor White

        $UpdatedThreadCollection = New-Object System.Collections.Generic.List[PSObject]
        foreach ($ThreadGroup in $DetectedThreadGroups) {
            $ThreadLookupId = [string]$ThreadGroup.Name
            $ManifestThread = $TargetLogRecord.threads | Where-Object { [string]$_.threadID -eq $ThreadLookupId }
            $ThreadPostCount = ($ThreadGroup.Group | Where-Object { [string]$_.type -match "^(0|19|Default|Reply)$" }).Count

            if ($null -ne $ManifestThread) {
                # Update volatile post count
                $ManifestThread.messageCount = $ThreadPostCount
                # Locked Rule: Only update displayName if it is blank in the manifest
                if ([string]::IsNullOrWhiteSpace($ManifestThread.displayName)) {
                    $ManifestThread.displayName = $ThreadGroup.Group[0].thread.name
                }
                $UpdatedThreadCollection.Add($ManifestThread)
            } else {
                $UpdatedThreadCollection.Add([PSCustomObject]@{
                    threadID     = $ThreadLookupId
                    displayName  = $ThreadGroup.Group[0].thread.name
                    isActive     = $true
                    isNSFW       = $false
                    messageCount = $ThreadPostCount
                })
            }
        }
        $TargetLogRecord.threads = $UpdatedThreadCollection.ToArray()
        
        if (-not [string]::IsNullOrWhiteSpace($TargetLogRecord.channelID)) { 
            [void]$ProcessedChannelIdentifiers.Add($TargetLogRecord.channelID) 
        }

    } catch {
        Write-Warning "ERROR: Processing failed for $CurrentFileName. Details: $($_.Exception.Message)"
    }
}

# --- 4. Orphan & Deactivation Logic ---
foreach ($LogEntry in $TargetCampaign.logs) {
    if (-not $ProcessedChannelIdentifiers.Contains($LogEntry.channelID) -and -not [string]::IsNullOrWhiteSpace($LogEntry.channelID)) {
        if ($EnableDebugMode) { Write-Host "[DEBUG] ORPHAN: '$($LogEntry.title)' no longer found in repo. Deactivating." -ForegroundColor Red }
        $LogEntry.isActive = $false
    }
}

# --- 5. Export Strategy ---
$RegistryData | ConvertTo-Json -Depth 10 | Out-File -FilePath $ManifestFilePath -Encoding UTF8 -Force
Write-Host "`nHydration Successful: Manifest updated and manual locks respected." -ForegroundColor Green
