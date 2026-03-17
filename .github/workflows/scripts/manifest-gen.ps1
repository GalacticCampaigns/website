<#
.SYNOPSIS
    Campaign Registry Hydrator V2.2.3
.DESCRIPTION
    Hydrates campaign-registry.json via GitHub API. 
    Includes Low-Level BOM Stripping, ID Resolution Hierarchy, and NSFW Density Logic.
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
    if ($EnableDebugMode) { 
        $Source = if ($env:GH_TOKEN) { "GH_TOKEN (PAT)" } else { "GITHUB_TOKEN (Default)" }
        Write-Host "[DEBUG] Authenticated via $Source." -ForegroundColor Gray 
    }
}

# --- Path Logic ---
$BaseFolder = $TargetCampaignObj.dataPath.Trim('./').Trim('/')
$SubFolder = $TargetCampaignObj.paths.json.Trim('/')
$FullRemotePath = if ([string]::IsNullOrWhiteSpace($BaseFolder)) { $SubFolder } else { "$BaseFolder/$SubFolder" }

# Media Registry Detection
$MediaRegistryFileName = "media-registry.json"
$MediaRegistryRemotePath = if ([string]::IsNullOrWhiteSpace($BaseFolder)) { $MediaRegistryFileName } else { "$BaseFolder/$MediaRegistryFileName" }
$MediaApiUrl = "https://api.github.com/repos/$($TargetCampaignObj.repository)/contents/$($MediaRegistryRemotePath)?ref=$($TargetCampaignObj.branch)"

try {
    $MediaCheck = Invoke-RestMethod -Uri $MediaApiUrl -Method Get -Headers $RequestHeaders
    $TargetCampaignObj.paths.mediaRegistry = $MediaRegistryFileName
    if ($EnableDebugMode) { Write-Host "[DEBUG] Media Registry detected: $MediaRegistryFileName" -ForegroundColor Green }
} catch {
    $TargetCampaignObj.paths.mediaRegistry = $null
}

$GitHubApiUrl = "https://api.github.com/repos/$($TargetCampaignObj.repository)/contents/$($FullRemotePath)?ref=$($TargetCampaignObj.branch)"
if ($EnableDebugMode) { Write-Host "[DEBUG] API Target URL: $GitHubApiUrl" -ForegroundColor Yellow }

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
function Get-NormalizedProperty {
    param($InputObject, $DesiredPropertyName)
    if ($null -eq $InputObject) { return $null } 
    try {
        $CurrentProperties = $InputObject.PSObject.Properties
        $FoundMatch = $CurrentProperties | Where-Object { $_.Name -ieq $DesiredPropertyName -or $_.Name -ieq $DesiredPropertyName.Replace('_','') }
        if ($FoundMatch) { return [string]$FoundMatch[0].Value }
    } catch { return $null }
    return $null
}

# --- 3. ID Resolver Hierarchy ---
function Resolve-ChannelIDFromMessages($MessageCollection, $RootJsonObj) {
    if ($null -eq $MessageCollection -or $MessageCollection.Count -eq 0) { return $null }

    # Priority 1: Parent 1 Rule
    foreach ($CurrentMsg in $MessageCollection) {
        if ($CurrentMsg.thread -and $CurrentMsg.thread.parent_id -eq "1") {
            $TargetID = Get-NormalizedProperty $CurrentMsg "channel_id"
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID Resolved (Parent 1): $TargetID" -ForegroundColor Gray }
            return $TargetID
        }
    }

    # Priority 2: Majority Rule
    $ValidIDs = $MessageCollection | ForEach-Object { Get-NormalizedProperty $_ "channel_id" } | 
                Where-Object { $_ -match '^\d{17,20}$' }
    if ($ValidIDs) {
        $MajorityID = ($ValidIDs | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
        if ($EnableDebugMode) { Write-Host "[DEBUG] ID Resolved (Majority): $MajorityID" -ForegroundColor Gray }
        return $MajorityID
    }

    # Priority 3: Root Metadata
    if ($RootJsonObj.channel -and $RootJsonObj.channel.id) {
        if ($EnableDebugMode) { Write-Host "[DEBUG] ID Resolved (Root Meta): $($RootJsonObj.channel.id)" -ForegroundColor Gray }
        return $RootJsonObj.channel.id
    }

    return $null
}

# --- 4. Main Processing Loop ---
foreach ($RemoteFileRef in $ValidJsonFiles) {
    $CurrentFileName = $RemoteFileRef.name
    try {
        # Fetching content
        $FileResp = Invoke-RestMethod -Uri $RemoteFileRef.url -Headers $RequestHeaders
        $FileBytes = [System.Convert]::FromBase64String($FileResp.content)
        
        # --- THE BOM STRIPPER ---
        # Using a MemoryStream and StreamReader with detection allows us to bypass the UTF-8 BOM automatically
        $ms = [System.IO.MemoryStream]::new($FileBytes)
        $sr = [System.IO.StreamReader]::new($ms, [System.Text.Encoding]::UTF8, $true)
        $FileStringContent = $sr.ReadToEnd()
        $sr.Close(); $ms.Close()

        $ParsedJson = $FileStringContent | ConvertFrom-Json
        $MessageList = if ($ParsedJson.PSObject.Properties.Name -contains "messages") { $ParsedJson.messages } else { $ParsedJson }

        # --- NSFW SCANNER ---
        $GlobalNsfwCounter = 0
        $NsfwEmojiMatch = [char]::ConvertFromUtf32(0x1F51E) # Literal 🔞

        foreach ($msg in $MessageList) {
            $isPostNsfw = $false
            if ($msg.reactions) {
                foreach ($reaction in $msg.reactions) {
                    if ($reaction.emoji.name -eq $NsfwEmojiMatch -or $reaction.emoji.name -eq "underage") {
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

        if ($EnableDebugMode -and $GlobalNsfwCounter -gt 0) {
            Write-Host "[DEBUG] NSFW for $CurrentFileName: $GlobalNsfwCounter posts ($([Math]::Round($NsfwRatio*100, 2))%)" -ForegroundColor Magenta
        }

        # Resolve ID
        $ResolvedID = Resolve-ChannelIDFromMessages $MessageList $ParsedJson
        
        if ($null -eq $ResolvedID) { 
            Write-Warning "!! Skipping $CurrentFileName: Could not resolve Channel ID."
            continue
        }
        $GlobalProcessedIDs.Add($ResolvedID) | Out-Null

        # Match to Manifest
        $ExistingRecord = $TargetCampaignObj.logs | Where-Object { $_.channelID -eq $ResolvedID }

        if ($null -ne $ExistingRecord) {
            $ExistingRecord.isActive = $true
            $ExistingRecord.fileName = $CurrentFileName
            if ($null -eq $ExistingRecord.isNSFW -or $ExistingRecord.isNSFW -eq $false) {
                $ExistingRecord.isNSFW = $AutoFlagLog
            }
            Write-Host "  [OK] Hydrated: $($ExistingRecord.title)" -ForegroundColor Gray
        } else {
            if ($EnableDebugMode) { Write-Host "  [DEBUG] ID $ResolvedID ($CurrentFileName) not in manifest." -ForegroundColor DarkYellow }
        }

    } catch { 
        Write-Warning "!! Critical error in ${CurrentFileName}: $($_.Exception.Message)" 
    }
}

# --- 5. Orphan Deactivation ---
foreach ($LogEntry in $TargetCampaignObj.logs) {
    if (-not $GlobalProcessedIDs.Contains($LogEntry.channelID) -and -not [string]::IsNullOrWhiteSpace($LogEntry.channelID)) {
        Write-Warning "Orphaned record found: '$($LogEntry.title)' ($($LogEntry.fileName)). Setting to inactive."
        $LogEntry.isActive = $false
    }
}

# --- 6. Export ---
$FinalJsonPayload = $RegistryData | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($ManifestFilePath, $FinalJsonPayload, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "`n>>> Success: Hydration V2.2.3 Complete." -ForegroundColor Green