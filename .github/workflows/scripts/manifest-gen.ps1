<#
.SYNOPSIS
    Campaign Registry Hydrator V2.3.1
.DESCRIPTION
    Updated to aggregate thread counts into main channel tally and 
    list processed threads during execution.
#>
param (
    [string]$RequestedCampaignSlug,
    [switch]$EnableDebugMode
)

$ErrorActionPreference = "Stop"

# --- 1. Setup & Auth ---
$ManifestFilePath = "assets/campaign-registry.json"
if (-not (Test-Path $ManifestFilePath)) { Write-Error "Manifest missing at $ManifestFilePath."; exit 1 }

$RegistryRaw = Get-Content $ManifestFilePath -Raw -Encoding UTF8
$RegistryData = $RegistryRaw | ConvertFrom-Json
$ActiveCampaignKey = if ([string]::IsNullOrWhiteSpace($RequestedCampaignSlug)) { $RegistryData.activeCampaign } else { $RequestedCampaignSlug.Trim() }
$TargetCampaignObj = $RegistryData.campaigns.$ActiveCampaignKey

if ($null -eq $TargetCampaignObj) { Write-Error "Campaign '${ActiveCampaignKey}' not found."; exit 1 }

$Token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
$RequestHeaders = @{ "Accept" = "application/vnd.github.v3+json" }

if ($Token) { 
    $RequestHeaders.Add("Authorization", "Bearer $Token") 
    if ($EnableDebugMode) { Write-Host "[DEBUG] Authenticating via GitHub Token." -ForegroundColor Gray }
}

# --- Path Logic ---
$BaseFolder = $TargetCampaignObj.dataPath.Trim('./').Trim('/')
$SubFolder = $TargetCampaignObj.paths.json.Trim('/')
$FullRemotePath = if ([string]::IsNullOrWhiteSpace($BaseFolder)) { $SubFolder } else { "$BaseFolder/$SubFolder" }

# Media Registry Auto-Detection
$MediaRegistryFileName = "media-registry.json"
$MediaRegistryRemotePath = if ([string]::IsNullOrWhiteSpace($BaseFolder)) { $MediaRegistryFileName } else { "$BaseFolder/$MediaRegistryFileName" }
$MediaApiUrl = "https://api.github.com/repos/$($TargetCampaignObj.repository)/contents/${MediaRegistryRemotePath}?ref=$($TargetCampaignObj.branch)"

try {
    $MediaCheck = Invoke-RestMethod -Uri $MediaApiUrl -Method Get -Headers $RequestHeaders
    $TargetCampaignObj.paths.mediaRegistry = $MediaRegistryFileName
    if ($EnableDebugMode) { Write-Host "[DEBUG] Media Registry detected." -ForegroundColor Green }
} catch {
    $TargetCampaignObj.paths.mediaRegistry = $null
}

$GitHubApiUrl = "https://api.github.com/repos/$($TargetCampaignObj.repository)/contents/${FullRemotePath}?ref=$($TargetCampaignObj.branch)"

Write-Host "`n>>> Initializing Hydration: $($TargetCampaignObj.name)" -ForegroundColor Cyan

try {
    $RemoteDirectoryListing = Invoke-RestMethod -Uri $GitHubApiUrl -Method Get -Headers $RequestHeaders
    $ValidJsonFiles = $RemoteDirectoryListing | Where-Object { $_.name -like "*.json" }
    Write-Host ">>> Found $($ValidJsonFiles.Count) files to process." -ForegroundColor Green
} catch {
    Write-Error "GitHub API Access Failed: $($_.Exception.Message)"; exit 1
}

$GlobalProcessedIDs = New-Object 'System.Collections.Generic.HashSet[string]'

# --- 2. Helper: Hardened Property Lookup ---
function Get-NormalizedProperty($InputObject, $DesiredPropertyName) {
    if ($null -eq $InputObject) { return $null } 
    try {
        $CurrentProperties = $InputObject.PSObject.Properties
        $FoundMatch = $CurrentProperties | Where-Object { $_.Name -ieq $DesiredPropertyName -or $_.Name -ieq $DesiredPropertyName.Replace('_','') }
        if ($FoundMatch) { return [string]$FoundMatch[0].Value }
    } catch { return $null }
    return $null
}

# --- 3. ID Resolver Hierarchy ---
function Resolve-ChannelIDFromMessages($MessageCollection) {
    if ($null -eq $MessageCollection -or $MessageCollection.Count -eq 0) { return $null }

    foreach ($CurrentMsg in $MessageCollection) {
        $ThreadParentCheck = Get-NormalizedProperty $CurrentMsg.thread "parent_id"
        if ($null -ne $ThreadParentCheck -and $ThreadParentCheck -eq "1") {
            return Get-NormalizedProperty $CurrentMsg "channel_id"
        }
    }

    $ValidIDList = $MessageCollection | ForEach-Object { Get-NormalizedProperty $_ "channel_id" } | 
                   Where-Object { $_ -ne "1" -and $_ -ne "0" -and -not [string]::IsNullOrWhiteSpace($_) }
    if ($null -ne $ValidIDList) {
        return ($ValidIDList | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
    }

    foreach ($CurrentMsg in $MessageCollection) {
        $ParentSnowflake = Get-NormalizedProperty $CurrentMsg.thread "parent_id"
        if ($null -ne $ParentSnowflake -and $ParentSnowflake.Length -gt 10 -and $ParentSnowflake -ne "1") {
            return $ParentSnowflake
        }
    }
    return $null
}

# --- 4. Main Processing Loop ---
foreach ($RemoteFileRef in $ValidJsonFiles) {
    $CurrentFileName = $RemoteFileRef.name
    try {
        if ($EnableDebugMode) { Write-Host "`n[DEBUG] --- Processing: ${CurrentFileName} ---" -ForegroundColor Cyan }
        
        $FileWebResponse = Invoke-WebRequest -Uri $RemoteFileRef.download_url -Headers $RequestHeaders -UseBasicParsing
        $FileStringContent = $FileWebResponse.Content

        if ($FileStringContent.StartsWith([char]0xfeff)) {
            $FileStringContent = $FileStringContent.Substring(1)
            if ($EnableDebugMode) { Write-Host "[DEBUG] BOM stripped." -ForegroundColor Yellow }
        }

        $ParsedJson = $FileStringContent | ConvertFrom-Json
        $MessageList = if ($ParsedJson.PSObject.Properties.Name -contains "messages") { $ParsedJson.messages } else { $ParsedJson }
        if ($MessageList -isnot [array]) { $MessageList = @($MessageList) }

        # --- NSFW SCANNER ---
        $GlobalNsfwCounter = 0
        $NsfwEmojiMatch = [char]::ConvertFromUtf32(0x1F51E) 

        foreach ($msg in $MessageList) {
            $isPostNsfw = $false
            if ($msg.reactions) {
                foreach ($reaction in $msg.reactions) {
                    if ($reaction.emoji.name -eq ${NsfwEmojiMatch} -or $reaction.emoji.name -eq "underage") {
                        $isPostNsfw = $true; break
                    }
                }
            }
            if ($isPostNsfw) {
                if (-not ($msg.PSObject.Properties.Name -contains "isNSFW")) {
                    $msg | Add-Member -MemberType NoteProperty -Name "isNSFW" -Value $true -Force
                }
                $GlobalNsfwCounter++
            }
        }

        $NsfwRatio = if ($MessageList.Count -gt 0) { $GlobalNsfwCounter / $MessageList.Count } else { 0 }
        $AutoFlagLog = $NsfwRatio -ge 0.9

        $ResolvedTargetChannelID = Resolve-ChannelIDFromMessages $MessageList
        if ($null -eq $ResolvedTargetChannelID) {
            Write-Warning "!! Skipping ${CurrentFileName}: Could not resolve ID."
            continue
        }

        # --- REVISED TALLY LOGIC ---
        # We count ALL narrative messages in the file (Channel + Threads)
        $NarrativeTypeRegex = "^(0|19|Default|Reply)$"
        $AllNarrativeMessages = $MessageList | Where-Object { 
            [string]$_.type -match $NarrativeTypeRegex
        }
        $NarrativeTally = if ($null -ne $AllNarrativeMessages) { $AllNarrativeMessages.Count } else { 0 }
        
        $NewestTimestamp = ($MessageList | Sort-Object timestamp -Descending | Select-Object -First 1).timestamp

        # Thread Discovery
        $DiscoveredThreadGroups = $MessageList | Where-Object { 
            $tId = Get-NormalizedProperty $_.thread "id"
            return (-not [string]::IsNullOrWhiteSpace($tId) -and $tId -ne $ResolvedTargetChannelID)
        } | Group-Object { [string]$_.thread.id }

        # Match to Manifest
        $ExistingRecord = $TargetCampaignObj.logs | Where-Object { [string]$_.channelID -eq $ResolvedTargetChannelID }
        if ($null -eq $ExistingRecord) {
            $ExistingRecord = $TargetCampaignObj.logs | Where-Object { $_.fileName -ieq $CurrentFileName }
        }

        if ($null -eq $ExistingRecord) {
            $HighestOrder = if ($TargetCampaignObj.logs.Count -gt 0) { ($TargetCampaignObj.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
            $ExistingRecord = [PSCustomObject]@{
                title = $CurrentFileName.Split('.')[0].Replace("_", " "); 
                channelID = [string]$ResolvedTargetChannelID; 
                fileName = $CurrentFileName;
                isActive = $true; isNSFW = $AutoFlagLog; preview = ""; order = $HighestOrder + 1;
                messageCount = $NarrativeTally; lastMessageTimestamp = $NewestTimestamp; threads = @()
            }
            $TargetCampaignObj.logs += $ExistingRecord
        } else {
            $ExistingRecord.fileName = $CurrentFileName
            $ExistingRecord.messageCount = $NarrativeTally
            $ExistingRecord.lastMessageTimestamp = $NewestTimestamp
            $ExistingRecord.isActive = $true
            if ($ExistingRecord.isNSFW -eq $false) { $ExistingRecord.isNSFW = $AutoFlagLog }
        }

        # --- THREAD PROCESSING & DEBUGGING ---
        $UpdatedThreadList = New-Object System.Collections.Generic.List[PSObject]
        foreach ($CurrentGroup in $DiscoveredThreadGroups) {
            $tID = [string]$CurrentGroup.Name
            $tName = $CurrentGroup.Group[0].thread.name
            
            if ($EnableDebugMode) { Write-Host "  [THREAD] Found: $tName ($tID)" -ForegroundColor DarkGray }

            $StoredT = $ExistingRecord.threads | Where-Object { [string]$_.threadID -eq $tID }
            $TCount = ($CurrentGroup.Group | Where-Object { [string]$_.type -match $NarrativeTypeRegex }).Count
            $TNsfwCount = ($CurrentGroup.Group | Where-Object { $_.isNSFW -eq $true }).Count
            $TIsNsfw = if ($CurrentGroup.Group.Count -gt 0) { ($TNsfwCount / $CurrentGroup.Group.Count) -ge 0.9 } else { $false }

            if ($null -ne $StoredT) {
                $StoredT.messageCount = $TCount
                if ($StoredT.isNSFW -eq $false) { $StoredT.isNSFW = $TIsNsfw }
                $UpdatedThreadList.Add($StoredT)
            } else {
                $UpdatedThreadList.Add([PSCustomObject]@{ 
                    threadID = $tID; displayName = $tName; 
                    isActive = $true; isNSFW = $TIsNsfw; messageCount = $TCount 
                })
            }

        }
        
        $ExistingRecord.threads = $UpdatedThreadList.ToArray()
        [void]$GlobalProcessedIDs.Add($ResolvedTargetChannelID)

        Write-Host "  [OK] Processed: ${CurrentFileName} | Total Narrative: $NarrativeTally | NSFW: $([Math]::Round($NsfwRatio*100,1))%" -ForegroundColor Gray

    } catch { 
        Write-Warning "!! Critical error in ${CurrentFileName}: $($_.Exception.Message)" 
    }
}

# --- 5. Orphan Deactivation ---
foreach ($Log in $TargetCampaignObj.logs) {
    if (-not $GlobalProcessedIDs.Contains($Log.channelID) -and -not [string]::IsNullOrWhiteSpace($Log.channelID)) {
        Write-Warning "Orphaned record: '$($Log.title)'. Deactivating."
        $Log.isActive = $false
    }
}

# --- 6. Export ---
$FinalJson = $RegistryData | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($ManifestFilePath, $FinalJson, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "`n>>> Hydration Complete." -ForegroundColor Green