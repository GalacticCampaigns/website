<#
.SYNOPSIS
    Campaign Registry Hydrator V2.5.1
.DESCRIPTION
    - Deep Meta Recovery: Uses Get-NormalizedProperty to find thread names even in sparse JSON.
    - Pivot-First Logic: Strictly determines Channel ID by majority frequency.
    - Multi-Pass Scanning: Ensures thread names are recovered from any message in the group.
#>
param (
    [string]$RequestedCampaignSlug,
    [switch]$EnableDebugMode,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if ($DryRun) {
    Write-Host "!!! DRY RUN MODE ACTIVE: Simulation only, no changes will be saved !!!`n" -ForegroundColor Red
}

# --- 1. Setup & Auth ---
$ManifestFilePath = "assets/campaign-registry.json"
if (-not (Test-Path $ManifestFilePath)) { Write-Error "Manifest missing."; exit 1 }

$RegistryData = Get-Content $ManifestFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
$ActiveCampaignKey = if ([string]::IsNullOrWhiteSpace($RequestedCampaignSlug)) { $RegistryData.activeCampaign } else { $RequestedCampaignSlug.Trim() }
$TargetCampaignObj = $RegistryData.campaigns.$ActiveCampaignKey

if ($null -eq $TargetCampaignObj) { Write-Error "Campaign '${ActiveCampaignKey}' not found."; exit 1 }

$Token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
$RequestHeaders = @{ "Accept" = "application/vnd.github.v3+json" }
if ($Token) { $RequestHeaders.Add("Authorization", "Bearer $Token") }

# --- 2. Helper: Normalized Property (.get Parity) ---
function Get-NormalizedProperty($InputObject, $DesiredPropertyName, $DefaultValue = $null) {
    if ($null -eq $InputObject) { return $DefaultValue } 
    try {
        $Props = $InputObject.PSObject.Properties
        $Match = $Props | Where-Object { $_.Name -ieq $DesiredPropertyName -or $_.Name -ieq $DesiredPropertyName.Replace('_','') }
        if ($Match) { return $Match[0].Value } # Return the actual object/value
    } catch { return $DefaultValue }
    return $DefaultValue
}

# --- 3. Pivot-Based ID Resolver ---
function Resolve-PrimaryChannelID($MessageCollection, $FileName) {
    if ($null -eq $MessageCollection -or $MessageCollection.Count -eq 0) { return $null }
    
    $IDs = $MessageCollection | ForEach-Object { Get-NormalizedProperty $_ "channel_id" } | Where-Object { $_ -match '^\d{17,20}$' }
    if ($null -eq $IDs) { 
        if ($EnableDebugMode) { Write-Host "    [DEBUG] No valid Snowflake IDs found in $FileName" -ForegroundColor Red }
        return $null 
    }
        
    $Grouped = $IDs | Group-Object | Sort-Object Count -Descending
    $PivotID = [string]$Grouped[0].Name
    
    if ($EnableDebugMode) {
        Write-Host "    [TRACE] ID Majority Pivot: $PivotID (Found $($Grouped[0].Count) posts)" -ForegroundColor Cyan
    }
    return $PivotID
}

# --- 4. Paths & Media Logic ---
$BaseFolder = $TargetCampaignObj.dataPath.Trim('./').Trim('/')
$SubFolder = $TargetCampaignObj.paths.json.Trim('/')
$FullRemotePath = if ([string]::IsNullOrWhiteSpace($BaseFolder)) { $SubFolder } else { "$BaseFolder/$SubFolder" }

if ($null -eq $TargetCampaignObj.paths.PSObject.Properties['mediaRegistry']) {
    $TargetCampaignObj.paths | Add-Member -MemberType NoteProperty -Name "mediaRegistry" -Value $null -Force
}

$MediaRegistryFileName = "media-registry.json"
$MediaApiUrl = "https://api.github.com/repos/$($TargetCampaignObj.repository)/contents/$($BaseFolder)/${MediaRegistryFileName}?ref=$($TargetCampaignObj.branch)"

try {
    $MediaCheck = Invoke-RestMethod -Uri $MediaApiUrl -Method Get -Headers $RequestHeaders
    $TargetCampaignObj.paths.mediaRegistry = $MediaRegistryFileName
} catch { $TargetCampaignObj.paths.mediaRegistry = $null }

$GitHubApiUrl = "https://api.github.com/repos/$($TargetCampaignObj.repository)/contents/${FullRemotePath}?ref=$($TargetCampaignObj.branch)"
Write-Host "`n>>> Initializing Hydration: $($TargetCampaignObj.name)" -ForegroundColor Cyan

try {
    $RemoteListing = Invoke-RestMethod -Uri $GitHubApiUrl -Method Get -Headers $RequestHeaders
    $ValidJsonFiles = $RemoteListing | Where-Object { $_.name -like "*.json" }
    Write-Host ">>> Found $($ValidJsonFiles.Count) files." -ForegroundColor Green
} catch { Write-Error "API Access Failed."; exit 1 }

$GlobalProcessedIDs = New-Object 'System.Collections.Generic.HashSet[string]'

# --- 5. Main Processing Loop ---
foreach ($RemoteFileRef in $ValidJsonFiles) {
    $CurrentFileName = $RemoteFileRef.name
    try {
        if ($EnableDebugMode) { Write-Host "`n--- Scanning: $CurrentFileName ---" -ForegroundColor Blue }
        $Response = Invoke-WebRequest -Uri $RemoteFileRef.download_url -Headers $RequestHeaders -UseBasicParsing
        $Content = $Response.Content
       if ($Content.StartsWith([char]0xfeff)) { 
            if ($EnableDebugMode) { Write-Host "    [DEBUG] BOM signature stripped." -ForegroundColor Yellow }
            $Content = $Content.Substring(1) 
        }
        $ParsedJson = $Content | ConvertFrom-Json
        $MessageList = if ($ParsedJson.PSObject.Properties.Name -contains "messages") { $ParsedJson.messages } else { $ParsedJson }
        if ($MessageList -isnot [array]) { $MessageList = @($MessageList) }

        # --- Resolve Pivot ID ---
        $ResolvedID = Resolve-PrimaryChannelID $MessageList $CurrentFileName
        if ($null -eq $ResolvedID) { continue }
        [void]$GlobalProcessedIDs.Add($ResolvedID)

        # --- NSFW SCANNER ---
        $GlobalNsfwCounter = 0
        $NsfwEmoji = [char]::ConvertFromUtf32(0x1F51E)
        foreach ($msg in $MessageList) {
            $isPostNsfw = $false
            if ($msg.reactions) {
                foreach ($reac in $msg.reactions) {
                    if ($reac.emoji.name -eq $NsfwEmoji -or $reac.emoji.name -eq "underage") { $isPostNsfw = $true; break }
                }
            }
            if ($isPostNsfw) {
                if (-not ($msg.PSObject.Properties.Name -contains "isNSFW")) { $msg | Add-Member -NotePropertyName "isNSFW" -NotePropertyValue $true -Force }
                $GlobalNsfwCounter++
            }
        }
        $AutoFlagLog = ($GlobalNsfwCounter / $MessageList.Count -ge 0.9)

        # --- Grouping-Based Tally Logic ---
        $NarrativeTypeRegex = "^(0|18|19|21|Default|Reply)$"
        $AllNarrative = $MessageList | Where-Object { [string]$_.type -match $NarrativeTypeRegex }
        $NarrativeTally = if ($null -ne $AllNarrative) { $AllNarrative.Count } else { 0 }
        $NewestTimestamp = ($MessageList | Sort-Object timestamp -Descending | Select-Object -First 1).timestamp

        # Group ALL narrative messages by channel_id
        $ChannelGroups = $AllNarrative | Group-Object { Get-NormalizedProperty $_ "channel_id" }
        
        $MainChannelCount = 0
        $ThreadNarrativeSum = 0
        $UpdatedThreads = New-Object System.Collections.Generic.List[PSObject]

        # Match Manifest Record
        $ExistingRecord = $TargetCampaignObj.logs | Where-Object { ([string]$_.channelID -eq $ResolvedID) -or ($_.fileName -ieq $CurrentFileName) }

        if ($null -eq $ExistingRecord) {
            $MaxOrder = if ($TargetCampaignObj.logs.Count -gt 0) { ($TargetCampaignObj.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
            $ExistingRecord = [PSCustomObject]@{
                title = $CurrentFileName.Split('.')[0].Replace("_", " "); channelID = [string]$ResolvedID; 
                fileName = $CurrentFileName; isActive = $true; isNSFW = $AutoFlagLog; preview = ""; order = $MaxOrder + 1;
                messageCount = $NarrativeTally; lastMessageTimestamp = $NewestTimestamp; threads = @()
            }
            $TargetCampaignObj.logs += $ExistingRecord
        } else {
            $ExistingRecord.channelID = [string]$ResolvedID; $ExistingRecord.messageCount = $NarrativeTally
            $ExistingRecord.lastMessageTimestamp = $NewestTimestamp; $ExistingRecord.isActive = $true
            if ($ExistingRecord.isNSFW -eq $false) { $ExistingRecord.isNSFW = $AutoFlagLog }
        }

        # Process each channel_id group
        foreach ($Group in $ChannelGroups) {
            $groupId = [string]$Group.Name
            
            if ($groupId -eq $ResolvedID) {
                $MainChannelCount = $Group.Count
            } else {
                $TCount = $Group.Count
                $ThreadNarrativeSum += $TCount

                # Meta Recovery: Use helper to find the thread object anywhere in the group
                $tName = "Unknown Thread ($groupId)"
                foreach ($m in $Group.Group) {
                    $tObj = Get-NormalizedProperty $m "thread"
                    if ($null -ne $tObj) {
                        $tName = Get-NormalizedProperty $tObj "name"
                        if ($null -ne $tName) { break } # Found it!
                    }
                }

                $StoredT = $ExistingRecord.threads | Where-Object { [string]$_.threadID -eq $groupId }
                if ($null -ne $StoredT) {
                    $StoredT.messageCount = $TCount; $StoredT.isActive = $true
                    # Only update name if we actually found one
                    if ($tName -notlike "Unknown*") { $StoredT.displayName = $tName }
                    $UpdatedThreads.Add($StoredT)
                } else {
                    $UpdatedThreads.Add([PSCustomObject]@{ threadID = $groupId; displayName = $tName; isActive = $true; isNSFW = $false; messageCount = $TCount })
                }
                if ($EnableDebugMode) { Write-Host "    [THREAD] $tName ($groupId) -> $TCount posts" -ForegroundColor DarkGray }
            }
        }
        $ExistingRecord.threads = $UpdatedThreads.ToArray()

        Write-Host "  [OK] ${CurrentFileName} | Total: $NarrativeTally (Main: $MainChannelCount | Threads: $ThreadNarrativeSum)" -ForegroundColor Green

    } catch { Write-Warning "!! Error in ${CurrentFileName}: $($_.Exception.Message)" }
}

# --- 6. Final Sync & Export ---
$ActiveCount = 0
Write-Host "`n>>> Running Final Integrity Check..." -ForegroundColor Cyan
foreach ($Log in $TargetCampaignObj.logs) {
    $idStr = [string]$Log.channelID
    if ($GlobalProcessedIDs.Contains($idStr)) { 
        $ActiveCount++; $Log.isActive = $true 
    } else { 
        if ($Log.isActive -eq $true) {
            Write-Warning "    [ORPHAN] $($Log.title) ($idStr) - No matching file found. Deactivating." 
            $Log.isActive = $false 
        }
    }
}

if (-not $DryRun) {
    $FinalJson = $RegistryData | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($ManifestFilePath, $FinalJson, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "`n>>> Success: Hydration Complete." -ForegroundColor Green
} else { Write-Host "`n>>> DRY RUN COMPLETE: Manifest was NOT updated." -ForegroundColor Yellow }

Write-Host ">>> Summary v2.5.1: $ActiveCount Active Logs | $($ValidJsonFiles.Count) Scanned." -ForegroundColor Cyan