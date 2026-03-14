# .github/workflows/scripts/manifest-gen.ps1
param (
    [string]$CampaignId = "",
    [switch]$DebugLog = $false,
    [switch]$ForceUpdate = $false
)

function Write-DebugHost { param($msg); if ($DebugLog) { Write-Host "DEBUG: $msg" -ForegroundColor Cyan } }

$manifestPath = "assets/campaign-registry.json"
if (-not (Test-Path $manifestPath)) { Write-Error "Registry not found."; exit 1 }

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

$campaignKeys = $manifest.campaigns.PSObject.Properties.Name
if ($CampaignId) { $campaignKeys = $campaignKeys | Where-Object { $_ -eq $CampaignId } }

foreach ($campaignKey in $campaignKeys) {
    $camp = $manifest.campaigns.$campaignKey
    Write-Host "--- Hydrating: $($camp.name) ($campaignKey) ---"
    
    $processedFiles = @()
    $newLogList = @() 
    
    $persistMap = @{}
    if ($camp.logs) { foreach($l in $camp.logs) { $persistMap[$l.fileName] = $l } }

    $apiUrl = "https://api.github.com/repos/$($camp.repository)/contents/$($camp.dataPath)$($camp.paths.json)?ref=$($camp.branch)"
    try { $files = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers @{"Accept"="application/vnd.github.v3+json"} } catch { continue }

    foreach ($f in $files | Where-Object { $_.name -like "*.json" }) {
        Write-Host "  > Processing File: $($f.name)"
        $processedFiles += $f.name
        
        $msgList = @(); $resolvedID = ""; $foundThreads = @();

        try {
            # Invoke-RestMethod handles the download and initial JSON conversion
            $rawJson = Invoke-RestMethod -Uri $f.download_url
            
            # Determine if the JSON is a wrapper object or a direct array
            if ($rawJson.PSObject.Properties.Name -contains 'messages') {
                $msgList = $rawJson.messages
            } else {
                # If it's a top-level array, PowerShell casts it as an Object[]
                $msgList = $rawJson
            }
        } catch { 
            Write-Warning "    ! Download/Parse failed for $($f.name)"
            continue 
        }

        if ($null -eq $msgList -or $msgList.Count -eq 0) { continue }

        # 1. RESOLVE CHAPTER ID
        foreach ($m in $msgList) {
            $currentChannelID = if ($m.channel_id) { [string]$m.channel_id } else { "" }
            $currentParentID = if ($m.thread -and $m.thread.parent_id) { [string]$m.thread.parent_id } else { "" }
            
            if ($currentParentID -and $currentParentID.Length -gt 10) { 
                $resolvedID = $currentParentID
                break 
            }
            elseif ($currentChannelID -and $currentChannelID.Length -gt 10) { 
                $resolvedID = $currentChannelID
                break 
            }
        }

        # 2. RESOLVE THREADS
        $threadGroups = $msgList | Where-Object { $_.thread -and $_.thread.id -and [string]$_.thread.id -ne $resolvedID } | Group-Object { [string]$_.thread.id }
        foreach ($g in $threadGroups) {
            $foundThreads += [PSCustomObject]@{
                threadID = [string]$g.Name
                displayName = [string]$g.Group[0].thread.name
                isActive = $true
                isNSFW = $false
                messageCount = $g.Count
            }
            if ($DebugLog) { Write-DebugHost "    [Thread Found] ID: $($g.Name) | Name: $($g.Group[0].thread.name) | Count: $($g.Count)" }
        }

        # 3. SMART REBUILD
        $oldRecord = $persistMap[$f.name]
        
        # Valid message types: 0 (Default), 18 (Thread Start), 19 (Reply)
        $validTypes = @(0, 18, 19, "Default", "Reply", "ThreadCreated")
        $newCount = ($msgList | Where-Object { $validTypes -contains $_.type }).Count

        $sorted = $msgList | Sort-Object timestamp
        $newTs = if ($sorted) { [string]$sorted[-1].timestamp } else { "" }
        $orderVal = if ($f.name -match '(\d+)') { [int]$matches[1] } else { 0 }

        if ($DebugLog) {
            Write-DebugHost "    [ID Update] '$($oldRecord.channelID)' -> '$resolvedID'"
            Write-DebugHost "    [Count Update] $($oldRecord.messageCount) -> $newCount"
            Write-DebugHost "    [Order] $orderVal"
            Write-DebugHost "    [Threads] Found $($foundThreads.Count) active threads."
        }

        $newLogList += [PSCustomObject]@{
            title = if ($oldRecord.title) { $oldRecord.title } else { ($f.name -replace '\.json$', '' -replace '_', ' ').ToUpper() }
            channelID = [string]$resolvedID
            fileName = [string]$f.name
            isActive = $true
            isNSFW = if ($null -ne $oldRecord.isNSFW) { $oldRecord.isNSFW } else { $false }
            preview = if ($oldRecord.preview) { $oldRecord.preview } else { "" }
            order = $orderVal
            messageCount = [int]$newCount
            lastMessageTimestamp = $newTs
            threads = $foundThreads
        }
    }

    foreach ($oldKey in $persistMap.Keys) {
        if ($processedFiles -notcontains $oldKey) {
            $orphan = $persistMap[$oldKey]
            $orphan.isActive = $false
            $newLogList += $orphan
        }
    }

    $camp.logs = $newLogList
}

$manifest | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding UTF8
Write-Host "--- Hydration Complete ---"
