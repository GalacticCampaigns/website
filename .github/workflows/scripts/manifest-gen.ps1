<#
.SYNOPSIS
    Campaign Registry Hydrator V2.0.0 - Comprehensive Remote Edition
.DESCRIPTION
    Hydrates the campaign-registry.json manifest using GitHub API.
    Enforces "Parent 1" resolution and the "Locked 8" persistence rules.
    Optimized for remote execution with comprehensive decision logging.
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

# Construct API Headers (Include GITHUB_TOKEN if available in environment)
$RequestHeaders = @{ "Accept" = "application/vnd.github.v3+json" }
if ($env:GITHUB_TOKEN) {
    $RequestHeaders.Add("Authorization", "token $env:GITHUB_TOKEN")
    if ($EnableDebugMode) { Write-Host "[DEBUG] Using GITHUB_TOKEN for authenticated API access." -ForegroundColor Gray }
}

$RemoteApiUrl = "https://api.github.com/repos/$($TargetCampaign.repository)/contents/$($TargetCampaign.paths.json)?ref=$($TargetCampaign.branch)"

Write-Host "`n>>> Initializing Hydration: $($TargetCampaign.name)" -ForegroundColor Cyan
Write-Host ">>> Repository: $($TargetCampaign.repository) [$($TargetCampaign.branch)]" -ForegroundColor Gray

try {
    $RemoteFilesRaw = Invoke-RestMethod -Uri $RemoteApiUrl -Method Get -Headers $RequestHeaders
    $ValidJsonFiles = $RemoteFilesRaw | Where-Object { $_.name -like "*.json" }
    Write-Host ">>> Found $($ValidJsonFiles.Count) JSON logs to process.`n" -ForegroundColor Green
} catch {
    Write-Error "CRITICAL: API Access Failed. Check repository path, branch, or rate limits. Error: $($_.Exception.Message)"
    exit 1
}

$ProcessedChannelIdentifiers = New-Object 'System.Collections.Generic.HashSet[string]'

# --- 2. Advanced ID Resolution (Parent 1 Logic) ---
function Resolve-TargetChannelReference($MessageList) {
    if ($null -eq $MessageList -or $MessageList.Count -eq 0) { return $null }

    # Priority 1: Parent 1 Rule
    foreach ($CurrentMsg in $MessageList) {
        if ($null -ne $CurrentMsg.thread -and [string]$CurrentMsg.thread.parent_id -eq "1") {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID RESOLUTION: Priority 1 (Parent 1 Metadata) -> $($CurrentMsg.channel_id)" -ForegroundColor Gray }
            return [string]$CurrentMsg.channel_id
        }
    }

    # Priority 2: Snowflake Parent
    foreach ($CurrentMsg in $MessageList) {
        $ExtractedParentVal = [string]$CurrentMsg.thread.parent_id
        if ($null -ne $ExtractedParentVal -and $ExtractedParentVal.Length -gt 10 -and $ExtractedParentVal -ne "1") {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID RESOLUTION: Priority 2 (Thread Parent ID) -> $ExtractedParentVal" -ForegroundColor Gray }
            return $ExtractedParentVal
        }
    }

    # Priority 3: First Valid Snowflake
    foreach ($CurrentMsg in $MessageList) {
        $ExtractedChannelVal = [string]$CurrentMsg.channel_id
        if ($null -ne $ExtractedChannelVal -and $ExtractedChannelVal.Length -gt 10) { 
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID RESOLUTION: Priority 3 (First Valid Channel ID) -> $ExtractedChannelVal" -ForegroundColor Gray }
            return $ExtractedChannelVal 
        }
    }

    # Priority 4: Majority Rule Fallback
    $FilteredIds = $MessageList | ForEach-Object { [string]$_.channel_id } | Where-Object { $_ -ne "1" -and $_ -ne "0" -and -not [string]::IsNullOrWhiteSpace($_) }
    if ($null -ne $FilteredIds) {
        $GroupedIds = $FilteredIds | Group-Object | Sort-Object Count -Descending
        if ($EnableDebugMode) { Write-Host "[DEBUG] ID RESOLUTION: Priority 4 (Majority Rule) -> $($GroupedIds[0].Name)" -ForegroundColor Gray }
        return [string]$GroupedIds[0].Name
    }
    return $null
}

# --- 3. Core Hydration Loop ---
foreach ($RemoteFile in $ValidJsonFiles) {
    $CurrentFileName = $RemoteFile.name
    try {
        if ($EnableDebugMode) { Write-Host "[DEBUG] --- START PROCESSING: $CurrentFileName ---" -ForegroundColor Cyan }
        
        # Download and Parse JSON
        $JsonContent = Invoke-RestMethod -Uri $RemoteFile.download_url -Headers $RequestHeaders
        $WorkableMessages = if ($JsonContent.PSObject.Properties.Name -contains "messages") { $JsonContent.messages } else { $JsonContent }
        if ($WorkableMessages -isnot [array]) { $WorkableMessages = @($WorkableMessages) }

        # Resolve ID and Match Record
        $ResolvedID = Resolve-TargetChannelReference $WorkableMessages
        
        # DUAL-KEY MATCHING
        $TargetRecord = $TargetCampaign.logs | Where-Object { [string]$_.channelID -eq $ResolvedID -and -not [string]::IsNullOrWhiteSpace($ResolvedID) }
        $MatchType = "ID Match"
        
        if ($null -eq $TargetRecord) {
            $TargetRecord = $TargetCampaign.logs | Where-Object { $_.fileName -ieq $CurrentFileName }
            $MatchType = "Filename Match"
        }

        # NARRATIVE FILTERING & STATS
        # Logic: Main count includes messages where thread.id matches resolved ID OR thread is null
        $NarrativeFilter = "^(0|19|Default|Reply)$"
        $MainFeedMessages = $WorkableMessages | Where-Object { 
            $TypeStr = [string]$_.type
            $IsNarrative = -not [string]::IsNullOrWhiteSpace($TypeStr) -and $TypeStr -match $NarrativeFilter
            $IsMainFeed = [string]$_.thread.id -eq $ResolvedID -or $null -eq $_.thread
            return ($IsNarrative -and $IsMainFeed)
        }
        
        $CurrentPostCount = $MainFeedMessages.Count
        $LastMsgTimestamp = ($WorkableMessages | Sort-Object timestamp -Descending | Select-Object -First 1).timestamp

        # THREAD DETECTION
        # Logic: Exclude if thread.id matches main channel OR matches its own parent
        $ThreadGroups = $WorkableMessages | Where-Object { 
            $MessageThreadId = [string]$_.thread.id
            $MessageThreadParent = [string]$_.thread.parent_id
            -not [string]::IsNullOrWhiteSpace($MessageThreadId) -and $MessageThreadId -ne $ResolvedID -and $MessageThreadId -ne $MessageThreadParent
        } | Group-Object { [string]$_.thread.id }

        # OUTPUT SUMMARY (Normal Mode)
        $CleanName = $CurrentFileName.PadRight(35).Substring(0, 35)
        Write-Host "$CleanName | ID: $($ResolvedID.PadRight(20)) | Posts: $($CurrentPostCount.ToString().PadLeft(4)) | Threads: $($ThreadGroups.Count)" -ForegroundColor Gray

        if ($null -eq $TargetRecord) {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ACTION: Initializing NEW manifest entry." -ForegroundColor Yellow }
            $MaxOrder = if ($TargetCampaign.logs.Count -gt 0) { ($TargetCampaign.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
            
            $TargetRecord = [PSCustomObject]@{
                title = $CurrentFileName.Split('.')[0].Replace("_", " "); channelID = [string]$ResolvedID; fileName = $CurrentFileName;
                isActive = $true; isNSFW = $false; preview = ""; order = $MaxOrder + 1;
                messageCount = $CurrentPostCount; lastMessageTimestamp = $LastMsgTimestamp; threads = @()
            }
            $TargetCampaign.logs += $TargetRecord
        } else {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ACTION: Merging into existing record via $MatchType: '$($TargetRecord.title)'" -ForegroundColor Yellow }
            
            # Locked 8 Merging Rules
            if ([string]::IsNullOrWhiteSpace($TargetRecord.channelID)) { $TargetRecord.channelID = [string]$ResolvedID }
            if ([string]::IsNullOrWhiteSpace($TargetRecord.title)) { $TargetRecord.title = $CurrentFileName.Split('.')[0].Replace("_", " ") }
            if ($null -eq $TargetRecord.order) { 
                $MaxOrderInternal = if ($TargetCampaign.logs.Count -gt 0) { ($TargetCampaign.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
                $TargetRecord.order = $MaxOrderInternal + 1 
            }
            if ($TargetRecord.isActive -ne $false) { $TargetRecord.isActive = $true }

            $TargetRecord.fileName = $CurrentFileName
            $TargetRecord.messageCount = $CurrentPostCount
            $TargetRecord.lastMessageTimestamp = $LastMsgTimestamp
        }

        # THREAD REFRESH (Locked displayName protection)
        $RefreshedThreads = New-Object System.Collections.Generic.List[PSObject]
        foreach ($Group in $ThreadGroups) {
            $LookupThreadId = [string]$Group.Name
            $StoredThread = $TargetRecord.threads | Where-Object { [string]$_.threadID -eq $LookupThreadId }
            $ThreadCount = ($Group.Group | Where-Object { [string]$_.type -match $NarrativeFilter }).Count

            if ($null -ne $StoredThread) {
                $StoredThread.messageCount = $ThreadCount
                if ([string]::IsNullOrWhiteSpace($StoredThread.displayName)) { $StoredThread.displayName = $Group.Group[0].thread.name }
                $RefreshedThreads.Add($StoredThread)
            } else {
                $RefreshedThreads.Add([PSCustomObject]@{
                    threadID = $LookupThreadId; displayName = $Group.Group[0].thread.name;
                    isActive = $true; isNSFW = $false; messageCount = $ThreadCount
                })
            }
        }
        $TargetRecord.threads = $RefreshedThreads.ToArray()
        
        if (-not [string]::IsNullOrWhiteSpace($TargetRecord.channelID)) { 
            [void]$ProcessedChannelIdentifiers.Add($TargetRecord.channelID) 
        }

    } catch {
        Write-Warning "!! Failed to process $CurrentFileName: $($_.Exception.Message)"
    }
}

# --- 4. Orphan & Deactivation ---
foreach ($Entry in $TargetCampaign.logs) {
    if (-not $ProcessedChannelIdentifiers.Contains($Entry.channelID) -and -not [string]::IsNullOrWhiteSpace($Entry.channelID)) {
        if ($EnableDebugMode) { Write-Host "[DEBUG] DROPPED: '$($Entry.title)' ID not found in current repo files. Setting Inactive." -ForegroundColor Red }
        $Entry.isActive = $false
    }
}

# --- 5. Export ---
$RegistryData | ConvertTo-Json -Depth 10 | Out-File -FilePath $ManifestFilePath -Encoding UTF8 -Force
Write-Host "`n>>> Hydration Complete. Manifest updated with full Parent 1 compliance." -ForegroundColor Green
