<#
.SYNOPSIS
    Campaign Registry Hydrator V2.0.0 - Final Remote Build
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
$ActiveKey = if ([string]::IsNullOrWhiteSpace($RequestedCampaignSlug)) { $RegistryData.activeCampaign } else { $RequestedCampaignSlug.Trim() }
$TargetCampaign = $RegistryData.campaigns.$ActiveKey

if ($null -eq $TargetCampaign) { Write-Error "Campaign '${ActiveKey}' not found."; exit 1 }

$RequestHeaders = @{ "Accept" = "application/vnd.github.v3+json" }
if ($env:GITHUB_TOKEN) { $RequestHeaders.Add("Authorization", "Bearer $env:GITHUB_TOKEN") }

$CleanJsonPath = $TargetCampaign.paths.json.Trim('/')
$RemoteApiUrl = "https://api.github.com/repos/$($TargetCampaign.repository)/contents/${CleanJsonPath}?ref=$($TargetCampaign.branch)"

Write-Host "`n>>> Initializing Hydration: $($TargetCampaign.name)" -ForegroundColor Cyan

try {
    $RemoteFiles = Invoke-RestMethod -Uri $RemoteApiUrl -Method Get -Headers $RequestHeaders
    $ValidFiles = $RemoteFiles | Where-Object { $_.name -like "*.json" }
    Write-Host ">>> Found $($ValidFiles.Count) files to process." -ForegroundColor Green
} catch {
    Write-Error "API Access Failed: $($_.Exception.Message)"; exit 1
}

$ProcessedIdentifiers = New-Object 'System.Collections.Generic.HashSet[string]'

# --- 2. Helper: Hardened Property Lookup (Null-Safe) ---
function Get-PropertySafe($InputObject, $PropName) {
    if ($null -eq $InputObject) { return $null } 
    # Fix: Accessing .PSObject on a null value causes the "method on a null-valued expression" error
    $Props = $InputObject.PSObject.Properties
    $Match = $Props | Where-Object { $_.Name -ieq $PropName -or $_.Name -ieq $PropName.Replace('_','') }
    if ($Match) { return [string]$Match[0].Value }
    return $null
}

# --- 3. Robust ID Resolver (Flipped Priority) ---
function Resolve-TargetChannelID($MessageList) {
    if ($null -eq $MessageList -or $MessageList.Count -eq 0) { return $null }

    # Priority 1: The "Parent 1" Rule (Definitive Chapter Anchor)
    foreach ($msg in $MessageList) {
        $ParentCheck = Get-PropertySafe $msg.thread "parent_id"
        if ($null -ne $ParentCheck -and $ParentCheck -eq "1") {
            $FoundID = Get-PropertySafe $msg "channel_id"
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID: Priority 1 (Parent 1) matched: $FoundID" -ForegroundColor Gray }
            return $FoundID
        }
    }

    # Priority 2: Majority Rule (Most common ID in the file)
    # Corrects the Prelude issue by favoring the actual channel ID over the category parent ID.
    $AllFoundIDs = $MessageList | ForEach-Object { Get-PropertySafe $_ "channel_id" } | Where-Object { $_ -ne "1" -and $_ -ne "0" -and -not [string]::IsNullOrWhiteSpace($_) }
    if ($null -ne $AllFoundIDs) {
        $MajorityID = ($AllFoundIDs | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
        if ($EnableDebugMode) { Write-Host "[DEBUG] ID: Priority 2 (Majority Rule) matched: $MajorityID" -ForegroundColor Gray }
        return $MajorityID
    }

    # Priority 3: Snowflake Parent Fallback
    foreach ($msg in $MessageList) {
        $ParentVal = Get-PropertySafe $msg.thread "parent_id"
        if ($null -ne $ParentVal -and $ParentVal.Length -gt 10 -and $ParentVal -ne "1") {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID: Priority 3 (Snowflake Parent) matched: $ParentVal" -ForegroundColor Gray }
            return $ParentVal
        }
    }

    return $null
}

# --- 4. Main Loop ---
foreach ($RemoteFile in $ValidFiles) {
    $FileName = $RemoteFile.name
    try {
        if ($EnableDebugMode) { Write-Host "`n[DEBUG] --- Processing: ${FileName} ---" -ForegroundColor Cyan }
        
        $MessagesRaw = Invoke-RestMethod -Uri $RemoteFile.download_url -Headers $RequestHeaders
        $Messages = if ($MessagesRaw.PSObject.Properties.Name -contains "messages") { $MessagesRaw.messages } else { $MessagesRaw }
        if ($Messages -isnot [array]) { $Messages = @($Messages) }

        $ResolvedID = Resolve-TargetChannelID $Messages
        
        # Dual-Key Match
        $Record = $TargetCampaign.logs | Where-Object { [string]$_.channelID -eq $ResolvedID -and -not [string]::IsNullOrWhiteSpace($ResolvedID) }
        $MatchStyle = "ID Match"
        if ($null -eq $Record) {
            $Record = $TargetCampaign.logs | Where-Object { $_.fileName -ieq $FileName }
            $MatchStyle = "Filename Match"
        }

        # Narrative Filter
        $Filter = "^(0|19|Default|Reply)$"
        $MainChapterPosts = $Messages | Where-Object { 
            $TypeVal = [string]$_.type
            $IsNarrative = -not [string]::IsNullOrWhiteSpace($TypeVal) -and $TypeVal -match $Filter
            $MsgChan = Get-PropertySafe $_ "channel_id"
            # Logic: Message belongs to chapter if ID matches ResolvedID OR it has no thread metadata
            return ($IsNarrative -and ($MsgChan -eq $ResolvedID -or $null -eq $_.thread))
        }
        
        $TotalPosts = $MainChapterPosts.Count
        $LastTS = ($Messages | Sort-Object timestamp -Descending | Select-Object -First 1).timestamp

        # Thread Grouping (Exclude main channel and self-referencing loops)
        $Groups = $Messages | Where-Object { 
            $Tid = Get-PropertySafe $_.thread "id"
            $Tpid = Get-PropertySafe $_.thread "parent_id"
            -not [string]::IsNullOrWhiteSpace($Tid) -and $Tid -ne $ResolvedID -and $Tid -ne $Tpid
        } | Group-Object { [string]$_.thread.id }

        # LOG SUMMARY
        $DisplayName = if ($FileName.Length -gt 25) { $FileName.Substring(0, 22) + "..." } else { $FileName.PadRight(25) }
        Write-Host "File: ${DisplayName} | ID: $($ResolvedID.PadRight(20)) | Posts: $($TotalPosts.ToString().PadLeft(4)) | Threads: $($Groups.Count)" -ForegroundColor Gray

        if ($null -eq $Record) {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ACTION: New Record Initialized." -ForegroundColor Yellow }
            $MaxOrderVal = if ($TargetCampaign.logs.Count -gt 0) { ($TargetCampaign.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
            $Record = [PSCustomObject]@{
                title = $FileName.Split('.')[0].Replace("_", " "); channelID = [string]$ResolvedID; fileName = $FileName;
                isActive = $true; isNSFW = $false; preview = ""; order = $MaxOrderVal + 1;
                messageCount = $TotalPosts; lastMessageTimestamp = $LastTS; threads = @()
            }
            $TargetCampaign.logs += $Record
        } else {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ACTION: Merging via ${MatchStyle}: '$($Record.title)'" -ForegroundColor Yellow }
            if ([string]::IsNullOrWhiteSpace($Record.channelID)) { $Record.channelID = [string]$ResolvedID }
            if ([string]::IsNullOrWhiteSpace($Record.title)) { $Record.title = $FileName.Split('.')[0].Replace("_", " ") }
            if ($null -eq $Record.order) { 
                $InternalMax = if ($TargetCampaign.logs.Count -gt 0) { ($TargetCampaign.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
                $Record.order = $InternalMax + 1 
            }
            if ($Record.isActive -ne $false) { $Record.isActive = $true }
            $Record.fileName = $FileName
            $Record.messageCount = $TotalPosts
            $Record.lastMessageTimestamp = $LastTS
        }

        # Update Threads
        $ThreadList = New-Object System.Collections.Generic.List[PSObject]
        foreach ($G in $Groups) {
            $LookupID = [string]$G.Name
            $StoredT = $Record.threads | Where-Object { [string]$_.threadID -eq $LookupID }
            $Tally = ($G.Group | Where-Object { [string]$_.type -match $Filter }).Count
            if ($null -ne $StoredT) {
                $StoredT.messageCount = $Tally
                if ([string]::IsNullOrWhiteSpace($StoredT.displayName)) { $StoredT.displayName = $G.Group[0].thread.name }
                $ThreadList.Add($StoredT)
            } else {
                $ThreadList.Add([PSCustomObject]@{ threadID = $LookupID; displayName = $G.Group[0].thread.name; isActive = $true; isNSFW = $false; messageCount = $Tally })
            }
        }
        $Record.threads = $ThreadList.ToArray()
        if (-not [string]::IsNullOrWhiteSpace($Record.channelID)) { [void]$ProcessedIdentifiers.Add($Record.channelID) }

    } catch { 
        Write-Warning "!! Error in ${FileName}: $($_.Exception.Message)" 
    }
}

# --- 5. Orphan Deactivation ---
foreach ($LogEntry in $TargetCampaign.logs) {
    if (-not $ProcessedIdentifiers.Contains($LogEntry.channelID) -and -not [string]::IsNullOrWhiteSpace($LogEntry.channelID)) {
        if ($EnableDebugMode) { Write-Host "[DEBUG] ORPHAN: '$($LogEntry.title)' deactivated." -ForegroundColor Red }
        $LogEntry.isActive = $false
    }
}

# --- 6. Export ---
$RegistryData | ConvertTo-Json -Depth 10 | Out-File -FilePath $ManifestFilePath -Encoding UTF8 -Force
Write-Host "`n>>> Success: Hydration Complete." -ForegroundColor Green
