<#
.SYNOPSIS
    Campaign Registry Hydrator V2.1.0
.DESCRIPTION
    Hydrates campaign-registry.json via GitHub API. 
    Strict Parent 1 / Majority Rule / Locked 8 logic.
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

# LOGIC: Check for your high-clearance PAT first, then fallback to the default token
$Token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }

$RequestHeaders = @{ "Accept" = "application/vnd.github.v3+json" }

if ($Token) { 
    $RequestHeaders.Add("Authorization", "Bearer $Token") 
    if ($EnableDebugMode) { 
        $Source = if ($env:GH_TOKEN) { "GH_TOKEN (PAT)" } else { "GITHUB_TOKEN (Default)" }
        Write-Host "[DEBUG] Authenticating via $Source." -ForegroundColor Gray 
    }
}

# --- PATH LOGIC FIX START ---
# We must combine dataPath (e.g., "swWhispers-Void/") with paths.json (e.g., "json/")
$BaseFolder = $TargetCampaignObj.dataPath.Trim('./').Trim('/')
$SubFolder = $TargetCampaignObj.paths.json.Trim('/')

# Joins them safely: "swWhispers-Void/json"
$FullRemotePath = if ([string]::IsNullOrWhiteSpace($BaseFolder)) { $SubFolder } else { "$BaseFolder/$SubFolder" }

# --- NEW: MEDIA REGISTRY DETECTION ---
# We check the root of the dataPath for the registry file
$MediaRegistryFileName = "media-registry.json"
$MediaRegistryRemotePath = if ([string]::IsNullOrWhiteSpace($BaseFolder)) { $MediaRegistryFileName } else { "$BaseFolder/$MediaRegistryFileName" }
$MediaApiUrl = "https://api.github.com/repos/$($TargetCampaignObj.repository)/contents/$($MediaRegistryRemotePath)?ref=$($TargetCampaignObj.branch)"

try {
    $MediaCheck = Invoke-RestMethod -Uri $MediaApiUrl -Method Get -Headers $RequestHeaders
    $TargetCampaignObj.paths.mediaRegistry = $MediaRegistryFileName
    if ($EnableDebugMode) { Write-Host "[DEBUG] Media Registry detected and linked." -ForegroundColor Green }
} catch {
    $TargetCampaignObj.paths.mediaRegistry = $null
    if ($EnableDebugMode) { Write-Host "[DEBUG] No Media Registry found at $MediaRegistryRemotePath" -ForegroundColor Gray }
}

$GitHubApiUrl = "https://api.github.com/repos/$($TargetCampaignObj.repository)/contents/$($FullRemotePath)?ref=$($TargetCampaignObj.branch)"

if ($EnableDebugMode) { Write-Host "[DEBUG] API Target URL: $GitHubApiUrl" -ForegroundColor Yellow }
# --- PATH LOGIC FIX END ---

Write-Host "`n>>> Initializing Hydration: $($TargetCampaignObj.name)" -ForegroundColor Cyan

try {
    $RemoteDirectoryListing = Invoke-RestMethod -Uri $GitHubApiUrl -Method Get -Headers $RequestHeaders
    $ValidJsonFiles = $RemoteDirectoryListing | Where-Object { $_.name -like "*.json" }
    Write-Host ">>> Found $($ValidJsonFiles.Count) files to process." -ForegroundColor Green
} catch {
    Write-Error "GitHub API Access Failed: $($_.Exception.Message)"; exit 1
}

$GlobalProcessedIDs = New-Object 'System.Collections.Generic.HashSet[string]'
# --- 2. Helper: Hardened Property Lookup (Null-Safe) ---
function Get-NormalizedProperty($InputObject, $DesiredPropertyName) {
    if ($null -eq $InputObject) { return $null } 
    $CurrentProperties = $InputObject.PSObject.Properties
    $FoundMatch = $CurrentProperties | Where-Object { $_.Name -ieq $DesiredPropertyName -or $_.Name -ieq $DesiredPropertyName.Replace('_','') }
    if ($FoundMatch) { return [string]$FoundMatch[0].Value }
    return $null
}

# --- 3. ID Resolver Hierarchy ---
function Resolve-ChannelIDFromMessages($MessageCollection) {
    if ($null -eq $MessageCollection -or $MessageCollection.Count -eq 0) { return $null }

    # Priority 1: The "Parent 1" Rule
    foreach ($CurrentMsg in $MessageCollection) {
        $ThreadParentCheck = Get-NormalizedProperty $CurrentMsg.thread "parent_id"
        if ($null -ne $ThreadParentCheck -and $ThreadParentCheck -eq "1") {
            $TargetID = Get-NormalizedProperty $CurrentMsg "channel_id"
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID: Priority 1 (Parent 1) matched: $TargetID" -ForegroundColor Gray }
            return $TargetID
        }
    }

    # Priority 2: Majority Rule (Most frequent channel_id)
    $ValidIDList = $MessageCollection | ForEach-Object { Get-NormalizedProperty $_ "channel_id" } | 
                   Where-Object { $_ -ne "1" -and $_ -ne "0" -and -not [string]::IsNullOrWhiteSpace($_) }
    if ($null -ne $ValidIDList) {
        $MajorityIDValue = ($ValidIDList | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
        if ($EnableDebugMode) { Write-Host "[DEBUG] ID: Priority 2 (Majority Rule) matched: $MajorityIDValue" -ForegroundColor Gray }
        return $MajorityIDValue
    }

    # Priority 3: Snowflake Parent Fallback
    foreach ($CurrentMsg in $MessageCollection) {
        $ParentSnowflake = Get-NormalizedProperty $CurrentMsg.thread "parent_id"
        if ($null -ne $ParentSnowflake -and $ParentSnowflake.Length -gt 10 -and $ParentSnowflake -ne "1") {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID: Priority 3 (Snowflake Parent) matched: $ParentSnowflake" -ForegroundColor Gray }
            return $ParentSnowflake
        }
    }
    return $null
}

# --- 4. Main Processing Loop ---
foreach ($RemoteFileRef in $ValidJsonFiles) {
    $CurrentFileName = $RemoteFileRef.name
    try {
        if ($EnableDebugMode) { Write-Host "`n[DEBUG] --- Parsing: ${CurrentFileName} ---" -ForegroundColor Cyan }
        
        # BOM Resiliency: Download as raw string first
        $FileWebResponse = Invoke-WebRequest -Uri $RemoteFileRef.download_url -Headers $RequestHeaders -UseBasicParsing
        $FileStringContent = $FileWebResponse.Content

        # Detect and strip UTF-8 BOM (\ufeff)
        if ($FileStringContent.StartsWith([char]0xfeff)) {
            $FileStringContent = $FileStringContent.Substring(1)
            if ($EnableDebugMode) { Write-Host "[DEBUG] BOM detected and stripped." -ForegroundColor Yellow }
        }

        # Parse JSON and normalize structure
        $ParsedJson = $FileStringContent | ConvertFrom-Json
        $MessageList = if ($ParsedJson.PSObject.Properties.Name -contains "messages") { $ParsedJson.messages } else { $ParsedJson }
        if ($MessageList -isnot [array]) { $MessageList = @($MessageList) }

        $ResolvedTargetChannelID = Resolve-ChannelIDFromMessages $MessageList
        
        # Dual-Key Match Search
        $ExistingRecord = $TargetCampaignObj.logs | Where-Object { 
            [string]$_.channelID -eq $ResolvedTargetChannelID -and -not [string]::IsNullOrWhiteSpace($ResolvedTargetChannelID) 
        }
        $MatchingMethod = "ID Match"
        if ($null -eq $ExistingRecord) {
            $ExistingRecord = $TargetCampaignObj.logs | Where-Object { $_.fileName -ieq $CurrentFileName }
            $MatchingMethod = "Filename Match"
        }

        # Narrative Filter (Types: 0, 19, Default, Reply)
        $NarrativeTypeRegex = "^(0|19|Default|Reply)$"
        $PrimaryChapterMessages = $MessageList | Where-Object { 
            $StringifiedType = [string]$_.type
            $IsNarrativeType = -not [string]::IsNullOrWhiteSpace($StringifiedType) -and $StringifiedType -match $NarrativeTypeRegex
            $MessageOriginID = Get-NormalizedProperty $_ "channel_id"
            return ($IsNarrativeType -and ($MessageOriginID -eq $ResolvedTargetChannelID -or $null -eq $_.thread))
        }
        
        $NarrativeTally = if ($null -ne $PrimaryChapterMessages) { $PrimaryChapterMessages.Count } else { 0 }
        $NewestTimestamp = ($MessageList | Sort-Object timestamp -Descending | Select-Object -First 1).timestamp

        # Thread Discovery Logic
        $DiscoveredThreadGroups = $MessageList | Where-Object { 
            $ThreadIdentifier = Get-NormalizedProperty $_.thread "id"
            $ThreadParentIdentifier = Get-NormalizedProperty $_.thread "parent_id"
            -not [string]::IsNullOrWhiteSpace($ThreadIdentifier) -and 
            $ThreadIdentifier -ne $ResolvedTargetChannelID -and 
            $ThreadIdentifier -ne $ThreadParentIdentifier
        } | Group-Object { [string]$_.thread.id }

        # Output Summary Line
        $ConsoleName = if ($CurrentFileName.Length -gt 25) { $CurrentFileName.Substring(0, 22) + "..." } else { $CurrentFileName.PadRight(25) }
        Write-Host "File: ${ConsoleName} | ID: $($ResolvedTargetChannelID.PadRight(20)) | Posts: $($NarrativeTally.ToString().PadLeft(4)) | Threads: $($DiscoveredThreadGroups.Count)" -ForegroundColor Gray

        if ($null -eq $ExistingRecord) {
            if ($EnableDebugMode) { Write-Host "[DEBUG] New entry detected. Initializing." -ForegroundColor Yellow }
            $HighestOrder = if ($TargetCampaignObj.logs.Count -gt 0) { ($TargetCampaignObj.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
            $ExistingRecord = [PSCustomObject]@{
                title = $CurrentFileName.Split('.')[0].Replace("_", " "); 
                channelID = [string]$ResolvedTargetChannelID; 
                fileName = $CurrentFileName;
                isActive = $true; isNSFW = $false; preview = ""; order = $HighestOrder + 1;
                messageCount = $NarrativeTally; lastMessageTimestamp = $NewestTimestamp; threads = @()
            }
            $TargetCampaignObj.logs += $ExistingRecord
        } else {
            if ($EnableDebugMode) { Write-Host "[DEBUG] Merging into '$($ExistingRecord.title)' via $MatchingMethod" -ForegroundColor Yellow }
            # Update Volatile Fields
            $ExistingRecord.fileName = $CurrentFileName
            $ExistingRecord.messageCount = $NarrativeTally
            $ExistingRecord.lastMessageTimestamp = $NewestTimestamp
            # Conditionals (Locked 8)
            if ([string]::IsNullOrWhiteSpace($ExistingRecord.channelID)) { $ExistingRecord.channelID = [string]$ResolvedTargetChannelID }
            if ($null -eq $ExistingRecord.order) { 
                $InternalMax = if ($TargetCampaignObj.logs.Count -gt 0) { ($TargetCampaignObj.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
                $ExistingRecord.order = $InternalMax + 1 
            }
            if ($ExistingRecord.isActive -ne $false) { $ExistingRecord.isActive = $true }
        }

        # Thread Array Management
        $UpdatedThreadList = New-Object System.Collections.Generic.List[PSObject]
        foreach ($CurrentGroup in $DiscoveredThreadGroups) {
            $TargetThreadLookupID = [string]$CurrentGroup.Name
            $StoredThreadEntry = $ExistingRecord.threads | Where-Object { [string]$_.threadID -eq $TargetThreadLookupID }
            $ThreadNarrativeCount = ($CurrentGroup.Group | Where-Object { [string]$_.type -match $NarrativeTypeRegex }).Count
            
            if ($null -ne $StoredThreadEntry) {
                $StoredThreadEntry.messageCount = $ThreadNarrativeCount
                if ([string]::IsNullOrWhiteSpace($StoredThreadEntry.displayName)) { $StoredThreadEntry.displayName = $CurrentGroup.Group[0].thread.name }
                $UpdatedThreadList.Add($StoredThreadEntry)
            } else {
                $UpdatedThreadList.Add([PSCustomObject]@{ 
                    threadID = $TargetThreadLookupID; 
                    displayName = $CurrentGroup.Group[0].thread.name; 
                    isActive = $true; isNSFW = $false; 
                    messageCount = $ThreadNarrativeCount 
                })
            }
        }
        $ExistingRecord.threads = $UpdatedThreadList.ToArray()
        if (-not [string]::IsNullOrWhiteSpace($ExistingRecord.channelID)) { [void]$GlobalProcessedIDs.Add($ExistingRecord.channelID) }

    } catch { 
        Write-Warning "!! Critical error in ${CurrentFileName}: $($_.Exception.Message)" 
    }
}

# --- 5. Orphan Deactivation ---
foreach ($ManifestLogEntry in $TargetCampaignObj.logs) {
    if (-not $GlobalProcessedIDs.Contains($ManifestLogEntry.channelID) -and -not [string]::IsNullOrWhiteSpace($ManifestLogEntry.channelID)) {
        Write-Warning "Orphaned record found: '$($ManifestLogEntry.title)' ($($ManifestLogEntry.fileName)). Setting to inactive."
        $ManifestLogEntry.isActive = $false
    }
}

# --- 6. Export (Web-Standard UTF-8 No BOM) ---
$FinalJsonPayload = $RegistryData | ConvertTo-Json -Depth 10 -Compress:($false)

# Create a UTF8 encoding object that explicitly disables the BOM (Byte Order Mark)
$Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)

# Write directly to the file to ensure no "Position 3" characters are added
[System.IO.File]::WriteAllText($ManifestFilePath, $FinalJsonPayload, $Utf8NoBomEncoding)

Write-Host "`n>>> Success: Registry Hydration V2.1.0 Complete." -ForegroundColor Green
