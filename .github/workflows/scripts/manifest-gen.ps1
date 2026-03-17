<#
.SYNOPSIS
    Campaign Registry Hydrator V2.3.6
.DESCRIPTION
    Base: V2.3.0 (Working ID Resolution + Raw Download)
    Updates: Aggregated tallies, Self-thread prevention, MediaRegistry property injection, 
             and detailed narrative telemetry.
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

# --- MEDIA REGISTRY DETECTION (ROBUST PROPERTY INJECTION) ---
$MediaRegistryFileName = "media-registry.json"
$MediaRegistryRemotePath = if ([string]::IsNullOrWhiteSpace($BaseFolder)) { $MediaRegistryFileName } else { "$BaseFolder/$MediaRegistryFileName" }
$MediaApiUrl = "https://api.github.com/repos/$($TargetCampaignObj.repository)/contents/${MediaRegistryRemotePath}?ref=$($TargetCampaignObj.branch)"

$FoundRegistry = $null
try {
    $MediaCheck = Invoke-RestMethod -Uri $MediaApiUrl -Method Get -Headers $RequestHeaders
    $FoundRegistry = $MediaRegistryFileName
    if ($EnableDebugMode) { Write-Host "[DEBUG] Media Registry detected." -ForegroundColor Green }
} catch {
    if ($EnableDebugMode) { Write-Host "[DEBUG] No Media Registry found." -ForegroundColor Gray }
}

# Ensure the property exists on the object to prevent "Property Not Found" errors
if ($null -eq $TargetCampaignObj.paths.PSObject.Properties['mediaRegistry']) {
    $TargetCampaignObj.paths | Add-Member -MemberType NoteProperty -Name "mediaRegistry" -Value $FoundRegistry -Force
} else {
    $TargetCampaignObj.paths.mediaRegistry = $FoundRegistry
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

    # Priority 1: Parent 1 Rule
    foreach ($CurrentMsg in $MessageCollection) {
        $ThreadParentCheck = Get-NormalizedProperty $CurrentMsg.thread "parent_id"
        if ($null -ne $ThreadParentCheck -and $ThreadParentCheck -eq "1") {
            return Get-NormalizedProperty $CurrentMsg "channel_id"
        }
    }

    # Priority 2: Majority Rule
    $ValidIDList = $MessageCollection | ForEach-Object { Get-NormalizedProperty $_ "channel_id" } | 
                   Where-Object { $_ -match '^\d{17,20}$' }
    if ($null -ne $ValidIDList) {
        return ($ValidIDList | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
    }

    # Priority 3: Snowflake Parent Fallback
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
        # Fetching raw content (V2.3.0 logic)
        $FileWebResponse = Invoke-WebRequest -Uri $RemoteFileRef.download_url -Headers $RequestHeaders -UseBasicParsing
        $FileStringContent = $FileWebResponse.Content

        if ($FileStringContent.StartsWith([char]0xfeff)) {
            $FileStringContent = $FileStringContent.Substring(1)
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

        # Resolve ID
        $ResolvedID = Resolve-ChannelIDFromMessages $MessageList
        if ($null -eq $ResolvedID) { 
            Write-Warning "!! Skipping ${CurrentFileName}: Could not resolve Snowflake ID."
            continue 
        }
        [void]$GlobalProcessedIDs.Add($ResolvedID)

        # --- AGGREGATED NARRATIVE TALLYING ---
        $NarrativeTypeRegex = "^(0|19|Default|Reply)$"
        $AllNarrative = $MessageList | Where-Object { [string]$_.type -match $NarrativeTypeRegex }
        
        # Breakdown: Treat matching threads as Main Channel content
        $MainChannelMsgs = $AllNarrative | Where-Object { 
            $tId = Get-NormalizedProperty $_.thread "id"
            ($_.channel_id -eq $ResolvedID -and $null -eq $_.thread) -or ($tId -eq $ResolvedID)
        }
        $SubThreadMsgs = $AllNarrative | Where-Object { 
            $tId = Get-NormalizedProperty $_.thread "id"
            $null -ne $_.thread -and $tId -ne $ResolvedID 
        }
        
        $NarrativeTally = if ($null -ne $AllNarrative) { $AllNarrative.Count } else { 0 }
        $NewestTimestamp = ($MessageList | Sort-Object timestamp -Descending | Select-Object -First 1).timestamp

        # Thread Discovery (Excluding Self-Threads)
        $DiscoveredThreadGroups = $MessageList | Where-Object { 
            $tId = Get-NormalizedProperty $_.thread "id"
            return (-not [string]::IsNullOrWhiteSpace($tId) -and $tId -ne $ResolvedID)
        } | Group-Object { [string]$_.thread.id }

        # Match Manifest Record
        $ExistingRecord = $TargetCampaignObj.logs | Where-Object { [string]$_.channelID -eq $ResolvedID }
        if ($null -eq $ExistingRecord) { $ExistingRecord = $TargetCampaignObj.logs | Where-Object { $_.fileName -ieq $CurrentFileName } }

        if ($null -eq $ExistingRecord) {
            $MaxOrder = if ($TargetCampaignObj.logs.Count -gt 0) { ($TargetCampaignObj.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
            $ExistingRecord = [PSCustomObject]@{
                title = $CurrentFileName.Split('.')[0].Replace("_", " "); 
                channelID = [string]$ResolvedID; 
                fileName = $CurrentFileName; 
                isActive = $true; isNSFW = $AutoFlagLog; preview = ""; order = $MaxOrder + 1;
                messageCount = $NarrativeTally; lastMessageTimestamp = $NewestTimestamp; threads = @()
            }
            $TargetCampaignObj.logs += $ExistingRecord
        } else {
            $ExistingRecord.fileName = $CurrentFileName
            $ExistingRecord.messageCount = $NarrativeTally
            $ExistingRecord.lastMessageTimestamp = $NewestTimestamp
            $ExistingRecord.isActive = $true
            # Locked 8 logic: don't revert True to False
            if ($ExistingRecord.isNSFW -eq $false) { $ExistingRecord.isNSFW = $AutoFlagLog }
        }

        # Update Thread Array
        $UpdatedThreads = New-Object System.Collections.Generic.List[PSObject]
        foreach ($Group in $DiscoveredThreadGroups) {
            $tID = [string]$Group.Name
            $tName = $Group.Group[0].thread.name
            
            $StoredT = $ExistingRecord.threads | Where-Object { [string]$_.threadID -eq $tID }
            
            # Feature Logic: Thread-Specific NSFW Density
            $TNarrative = $Group.Group | Where-Object { [string]$_.type -match $NarrativeTypeRegex }
            $TCount = if ($null -ne $TNarrative) { $TNarrative.Count } else { 0 }
            $TNsfwCount = ($Group.Group | Where-Object { $_.isNSFW -eq $true }).Count
            $TIsNsfw = if ($TCount -gt 0) { ($TNsfwCount / $TCount) -ge 0.9 } else { $false }

            if ($EnableDebugMode) { 
                $nsfwFlag = if ($TIsNsfw) { "[NSFW]" } else { "" }
                Write-Host "  [THREAD] Found: $tName ($tID) - Posts: $TCount $nsfwFlag" -ForegroundColor DarkGray 
            }

            if ($null -ne $StoredT) {
                $StoredT.messageCount = $TCount
                $StoredT.isActive = $true
                if ($StoredT.isNSFW -eq $false) { $StoredT.isNSFW = $TIsNsfw }
                $UpdatedThreads.Add($StoredT)
            } else {
                $UpdatedThreads.Add([PSCustomObject]@{ 
                    threadID = $tID; displayName = $tName; isActive = $true; isNSFW = $TIsNsfw; messageCount = $TCount 
                })
            }
        }
        $ExistingRecord.threads = $UpdatedThreads.ToArray()
        
        $logStatus = "Main: $($MainChannelMsgs.Count) | Threads: $($SubThreadMsgs.Count)"
        Write-Host "  [OK] Processed: ${CurrentFileName} ($logStatus) | NSFW: $([Math]::Round($NsfwRatio*100,1))%" -ForegroundColor Gray

    } catch { 
        Write-Warning "!! Critical error in ${CurrentFileName}: $($_.Exception.Message)" 
    }
}

# --- 5. Orphan Management ---
$ActiveCount = 0
foreach ($Log in $TargetCampaignObj.logs) {
    if ($GlobalProcessedIDs.Contains($Log.channelID)) {
        $ActiveCount++
        $Log.isActive = $true
    } elseif (-not [string]::IsNullOrWhiteSpace($Log.channelID)) {
        if ($Log.isActive -ne $false) {
            Write-Warning "  [ORPHAN] $($Log.title) not found in repo. Deactivating."
            $Log.isActive = $false
        }
    }
}

# --- 6. Export ---
$FinalJson = $RegistryData | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($ManifestFilePath, $FinalJson, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "`n>>> Hydration V2.3.6 Complete." -ForegroundColor Green
Write-Host ">>> Summary: $ActiveCount Active Logs | $($ValidJsonFiles.Count) Files Scanned." -ForegroundColor Cyan