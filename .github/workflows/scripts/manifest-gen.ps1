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

# --- 4. Main Processing Loop (Updated for NSFW Detection) ---
foreach ($RemoteFileRef in $ValidJsonFiles) {
    $CurrentFileName = $RemoteFileRef.name
    try {
        # ... [BOM Stripping & JSON Parsing as before] ...
        $ParsedJson = $FileStringContent | ConvertFrom-Json
        $MessageList = if ($ParsedJson.PSObject.Properties.Name -contains "messages") { $ParsedJson.messages } else { $ParsedJson }
        
        # --- NEW: PER-POST NSFW DETECTION ---
        $GlobalNsfwCounter = 0
        $NsfwEmojiMatch = "🔞" # Or use your custom emoji name like ":nsfw:"

        foreach ($msg in $MessageList) {
            $isPostNsfw = $false
            
            # Check reactions for the NSFW emoji
            if ($msg.reactions) {
                foreach ($reaction in $msg.reactions) {
                    if ($reaction.emoji.name -eq $NsfwEmojiMatch) {
                        $isPostNsfw = $true
                        break
                    }
                }
            }

            if ($isPostNsfw) {
                $msg | Add-Member -MemberType NoteProperty -Name "isNSFW" -Value $true -Force
                $GlobalNsfwCounter++
            }
        }

        # Calculate Percentages
        $NsfwPercentage = if ($MessageList.Count -gt 0) { $GlobalNsfwCounter / $MessageList.Count } else { 0 }
        $AutoFlagLog = $NsfwPercentage -ge 0.9

        # ... [ResolvedTargetChannelID & ExistingRecord Logic as before] ...

        if ($null -eq $ExistingRecord) {
            # ... [Initialization as before] ...
            $ExistingRecord = [PSCustomObject]@{
                # ...
                isNSFW = $AutoFlagLog; # AUTO-FLAGGED IF > 90%
                # ...
            }
        } else {
            # Locked 8 Logic: We only auto-flag if it wasn't already manually set
            if ($ExistingRecord.isNSFW -eq $false) { $ExistingRecord.isNSFW = $AutoFlagLog }
        }

        # --- THREAD-LEVEL AUTO-FLAGGING ---
        foreach ($CurrentGroup in $DiscoveredThreadGroups) {
            $ThreadMsgs = $CurrentGroup.Group
            $ThreadNsfwCount = ($ThreadMsgs | Where-Object { $_.isNSFW -eq $true }).Count
            $ThreadPercent = if ($ThreadMsgs.Count -gt 0) { $ThreadNsfwCount / $ThreadMsgs.Count } else { 0 }
            
            # Update/Create thread entry
            # ...
            $StoredThreadEntry.isNSFW = ($ThreadPercent -ge 0.9)
        }

        # --- IMPORTANT: RESAVE THE SOURCE JSON ---
        # Since we added 'isNSFW' to individual messages, we must save this back to the file
        # or ensure the website render logic handles the missing key as 'false'.
        # Note: If you want the website to see the per-post tag, you must re-upload these JSONs.
        
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
