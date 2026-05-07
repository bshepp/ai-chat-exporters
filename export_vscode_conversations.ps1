# Export VS Code Copilot Chat conversations to readable Markdown.
#
# Walks %APPDATA%\Code\User\workspaceStorage\<hash>\chatSessions\*.json
# and writes:  <OutputRoot>/<project>/vscode-copilot/<yyyy-MM-dd>_<sid8>.md
#
# Workspace name resolved from <hash>/workspace.json -> "folder" URI.
# Idempotent: skips files whose source mtime <= existing output mtime
# unless -Force.
#
# Usage:
#   .\export_vscode_conversations.ps1                  # preview
#   .\export_vscode_conversations.ps1 -Execute
#   .\export_vscode_conversations.ps1 -Execute -Force

[CmdletBinding()]
param(
    [string] $StorageRoot = "$env:APPDATA\Code\User\workspaceStorage",
    [string] $OutputRoot  = 'F:\_conversations',
    [switch] $Execute,
    [switch] $Force,
    [int]    $PreviewLimit = 5,
    [int]    $MinRequests = 1   # skip empty sessions
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web

function Get-ProjectFromWorkspaceJson {
    param([string]$WsJsonPath)
    if (-not (Test-Path $WsJsonPath)) { return $null }
    try {
        $j = Get-Content $WsJsonPath -Raw | ConvertFrom-Json
    } catch { return $null }
    $uri = $j.folder
    if (-not $uri) { $uri = $j.workspace }
    if (-not $uri) { return $null }
    # decode percent escapes; take last path segment
    $decoded = [System.Web.HttpUtility]::UrlDecode($uri)
    $decoded = $decoded -replace '^file:///', ''
    $name = Split-Path -Leaf ($decoded.TrimEnd('/'))
    if (-not $name) { $name = '_unknown' }
    return [pscustomobject]@{ Name = $name; Folder = $decoded }
}

function Format-VsTruncate {
    param([string]$s, [int]$max = 4000)
    if ($null -eq $s) { return '' }
    if ($s.Length -gt $max) { return $s.Substring(0, $max) + "`n... [truncated]" }
    return $s
}

function Format-VsToolInvocation {
    param($block)
    $msg = $null
    if ($block.pastTenseMessage -and $block.pastTenseMessage.value) {
        $msg = $block.pastTenseMessage.value
    } elseif ($block.invocationMessage -and $block.invocationMessage.value) {
        $msg = $block.invocationMessage.value
    } else {
        $msg = '(tool)'
    }
    $tool = if ($block.toolId) { $block.toolId } else { 'tool' }
    return "**[$tool]** $msg"
}

function Convert-VsResponse {
    param($response)
    $sb = New-Object System.Text.StringBuilder
    if (-not $response) { return '' }
    foreach ($block in $response) {
        # Markdown chunk: kind missing/empty, has 'value' string
        if (-not $block.kind) {
            if ($block.value -is [string]) {
                [void]$sb.AppendLine((Format-VsTruncate $block.value 8000))
                [void]$sb.AppendLine('')
            }
            continue
        }
        switch ($block.kind) {
            'thinking' {
                $t = Format-VsTruncate $block.value 1500
                if (-not [string]::IsNullOrWhiteSpace($t)) {
                    [void]$sb.AppendLine('<details><summary>thinking</summary>')
                    [void]$sb.AppendLine('')
                    [void]$sb.AppendLine($t)
                    [void]$sb.AppendLine('')
                    [void]$sb.AppendLine('</details>')
                    [void]$sb.AppendLine('')
                }
            }
            'toolInvocationSerialized' {
                [void]$sb.AppendLine((Format-VsToolInvocation $block))
                [void]$sb.AppendLine('')
            }
            # skipped: prepareToolInvocation, mcpServersStarting,
            # inlineReference, codeCitations, etc.
            default { }
        }
    }
    return $sb.ToString()
}

function Convert-VsSession {
    param([string]$Path, [string]$Project)

    try {
        $j = Get-Content $Path -Raw | ConvertFrom-Json
    } catch { return $null }

    if (-not $j.requests -or $j.requests.Count -lt $MinRequests) { return $null }

    $sid       = $j.sessionId
    $created   = $j.creationDate
    $lastMsg   = $j.lastMessageDate

    # creationDate / lastMessageDate are Unix epoch milliseconds
    $createdStr = ''
    $lastMsgStr = ''
    $createdDt  = $null
    if ($created -is [int64] -or $created -is [double] -or $created -is [int]) {
        try {
            $createdDt  = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$created).LocalDateTime
            $createdStr = $createdDt.ToString('yyyy-MM-dd HH:mm:ss')
        } catch {}
    } elseif ($created) { $createdStr = "$created" }
    if ($lastMsg -is [int64] -or $lastMsg -is [double] -or $lastMsg -is [int]) {
        try { $lastMsgStr = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$lastMsg).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss') } catch {}
    } elseif ($lastMsg) { $lastMsgStr = "$lastMsg" }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# VS Code Copilot session - $Project")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- **session:** ``$sid``")
    if ($createdStr) { [void]$sb.AppendLine("- **started:** $createdStr") }
    if ($lastMsgStr) { [void]$sb.AppendLine("- **last msg:** $lastMsgStr") }
    [void]$sb.AppendLine("- **requests:** $($j.requests.Count)")
    [void]$sb.AppendLine("- **source:** ``$Path``")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine('')

    foreach ($r in $j.requests) {
        $userText = $null
        if ($r.message -and $r.message.text) { $userText = $r.message.text }
        if ($userText) {
            [void]$sb.AppendLine('## User')
            $tsStr = ''
            if ($r.timestamp -is [int64] -or $r.timestamp -is [double] -or $r.timestamp -is [int]) {
                try { $tsStr = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$r.timestamp).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss') } catch {}
            } elseif ($r.timestamp) { $tsStr = "$($r.timestamp)" }
            if ($tsStr) { [void]$sb.AppendLine("*$tsStr*"); [void]$sb.AppendLine('') }
            [void]$sb.AppendLine((Format-VsTruncate $userText 8000))
            [void]$sb.AppendLine('')
        }

        $body = Convert-VsResponse $r.response
        if (-not [string]::IsNullOrWhiteSpace($body)) {
            [void]$sb.AppendLine('## Assistant')
            $model = if ($r.modelId) { $r.modelId } else { '' }
            if ($model) { [void]$sb.AppendLine("*$model*"); [void]$sb.AppendLine('') }
            [void]$sb.AppendLine($body)
            [void]$sb.AppendLine('')
        }
    }

    # Date for filename
    $datePart = 'undated'
    if ($createdDt) {
        $datePart = $createdDt.ToString('yyyy-MM-dd')
    }
    $sidShort = if ($sid) { $sid.Substring(0, [Math]::Min(8, $sid.Length)) } else { 'nosess' }

    return [pscustomobject]@{
        Project   = $Project
        SessionId = $sid
        DatePart  = $datePart
        SidShort  = $sidShort
        Markdown  = $sb.ToString()
    }
}

function Get-VsOutPath {
    param($info)
    $proj = ($info.Project -replace '[\\/:*?"<>|]', '_')
    $name = "$($info.DatePart)_$($info.SidShort).md"
    return Join-Path (Join-Path (Join-Path $OutputRoot $proj) 'vscode-copilot') $name
}

# ---- main ----

if (-not (Test-Path $StorageRoot)) { throw "Storage root not found: $StorageRoot" }

$mode = if ($Execute) { 'EXECUTE' } else { 'PREVIEW' }
Write-Host "Storage root:  $StorageRoot"
Write-Host "Output root:   $OutputRoot"
Write-Host "Mode:          $mode"
Write-Host ''

$plan = @()
$noProject = 0
$noSessions = 0

foreach ($wsDir in Get-ChildItem $StorageRoot -Directory) {
    $proj = Get-ProjectFromWorkspaceJson (Join-Path $wsDir.FullName 'workspace.json')
    if (-not $proj) { $noProject++; continue }

    $csDir = Join-Path $wsDir.FullName 'chatSessions'
    if (-not (Test-Path $csDir)) { $noSessions++; continue }

    foreach ($f in Get-ChildItem $csDir -File -Filter '*.json') {
        $info = Convert-VsSession -Path $f.FullName -Project $proj.Name
        if (-not $info) { continue }
        $out = Get-VsOutPath $info
        $plan += [pscustomobject]@{
            Source = $f.FullName
            Output = $out
            Project = $info.Project
            Info = $info
            SrcMTime = $f.LastWriteTime
        }
    }
}

Write-Host "Workspaces with no project URI: $noProject"
Write-Host "Workspaces with no chatSessions dir: $noSessions"
Write-Host ''
Write-Host "Per-project session counts:"
$plan | Group-Object Project | Sort-Object Count -Descending | ForEach-Object {
    "{0,-40} {1,4}" -f $_.Name, $_.Count
} | Select-Object -First 30

Write-Host ''
Write-Host "Total planned outputs: $($plan.Count)"

if (-not $Execute) {
    Write-Host ''
    Write-Host "(Preview only. Re-run with -Execute to write files.)"
    Write-Host "Sample of first $PreviewLimit outputs:"
    $plan | Select-Object -First $PreviewLimit | ForEach-Object {
        Write-Host "  $($_.Output)"
        Write-Host "    <- $($_.Source)"
    }
    return
}

$written = 0; $skipped = 0
foreach ($p in $plan) {
    $dir = Split-Path -Parent $p.Output
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $needWrite = $true
    if ((-not $Force) -and (Test-Path $p.Output)) {
        $existing = (Get-Item $p.Output).LastWriteTime
        if ($p.SrcMTime -le $existing) { $needWrite = $false }
    }

    if ($needWrite) {
        Set-Content -LiteralPath $p.Output -Value $p.Info.Markdown -Encoding UTF8
        $written++
    } else {
        $skipped++
    }
}

Write-Host ''
Write-Host "Written: $written"
Write-Host "Skipped (up to date): $skipped"
