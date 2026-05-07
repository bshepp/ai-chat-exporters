# Export Cursor chat conversations to readable Markdown.
#
# Reads per-workspace state.vscdb (composer.composerData -> allComposers list)
# and joins with global state.vscdb cursorDiskKV table where actual messages
# live as composerData:<id> + bubbleId:<composerId>:<bubbleId> rows.
#
# Output: <OutputRoot>/<project>/cursor/<yyyy-MM-dd>_<sid8>.md
#
# Usage:
#   .\export_cursor_conversations.ps1                  # preview
#   .\export_cursor_conversations.ps1 -Execute
#   .\export_cursor_conversations.ps1 -Execute -Force

[CmdletBinding()]
param(
    [string] $WorkspaceRoot = "$env:APPDATA\Cursor\User\workspaceStorage",
    [string] $GlobalDb      = "$env:APPDATA\Cursor\User\globalStorage\state.vscdb",
    [string] $OutputRoot    = 'F:\_conversations',
    [switch] $Execute,
    [switch] $Force,
    [switch] $IncludeOrphans,   # also export composers not referenced by any workspace
    [int]    $PreviewLimit = 5,
    [int]    $MinBubbles   = 2  # skip empty/trivial sessions
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web
Import-Module PSSQLite -ErrorAction Stop

function ConvertTo-StringValue {
    param($v)
    if ($null -eq $v) { return '' }
    if ($v -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($v) }
    return [string]$v
}

function Get-ProjectFromWorkspaceJson {
    param([string]$WsJsonPath)
    if (-not (Test-Path $WsJsonPath)) { return $null }
    try { $j = Get-Content $WsJsonPath -Raw | ConvertFrom-Json } catch { return $null }
    $uri = $j.folder
    if (-not $uri) { $uri = $j.workspace }
    if (-not $uri) { return $null }
    $decoded = [System.Web.HttpUtility]::UrlDecode($uri) -replace '^file:///', ''
    $name = Split-Path -Leaf ($decoded.TrimEnd('/'))
    if (-not $name) { $name = '_unknown' }
    return [pscustomobject]@{ Name = $name; Folder = $decoded }
}

function Format-Trunc {
    param([string]$s, [int]$max = 8000)
    if ($null -eq $s) { return '' }
    if ($s.Length -gt $max) { return $s.Substring(0, $max) + "`n... [truncated]" }
    return $s
}

function Get-BubbleText {
    param($b)
    # Prefer 'text' field; fallback to richText extraction
    if ($b.text -and $b.text.Trim().Length -gt 0) { return $b.text }
    if ($b.richText) {
        try {
            $rt = $b.richText | ConvertFrom-Json
            $sb = New-Object System.Text.StringBuilder
            function Walk-Node($n, $sb) {
                if ($null -eq $n) { return }
                if ($n.type -eq 'text' -and $n.text) { [void]$sb.Append($n.text) }
                if ($n.children) { foreach ($c in $n.children) { Walk-Node $c $sb } }
            }
            Walk-Node $rt.root $sb
            return $sb.ToString()
        } catch { return '' }
    }
    return ''
}

function Format-AssistantBubble {
    param($b)
    $sb = New-Object System.Text.StringBuilder

    # Thinking blocks
    if ($b.allThinkingBlocks -and $b.allThinkingBlocks.Count -gt 0) {
        foreach ($t in $b.allThinkingBlocks) {
            $tt = if ($t.text) { $t.text } elseif ($t -is [string]) { $t } else { '' }
            if ($tt) {
                [void]$sb.AppendLine('<details><summary>thinking</summary>')
                [void]$sb.AppendLine('')
                [void]$sb.AppendLine((Format-Trunc $tt 2000))
                [void]$sb.AppendLine('')
                [void]$sb.AppendLine('</details>')
                [void]$sb.AppendLine('')
            }
        }
    }

    # Main text
    $txt = Get-BubbleText $b
    if ($txt) {
        [void]$sb.AppendLine((Format-Trunc $txt 10000))
        [void]$sb.AppendLine('')
    }

    # Tool calls (toolResults / toolFormerName etc.)
    if ($b.toolResults -and $b.toolResults.Count -gt 0) {
        foreach ($tr in $b.toolResults) {
            $name = if ($tr.toolName) { $tr.toolName } elseif ($tr.name) { $tr.name } else { 'tool' }
            [void]$sb.AppendLine("**[$name]**")
            [void]$sb.AppendLine('')
        }
    }

    return $sb.ToString()
}

function Convert-CursorComposer {
    param(
        $CompMeta,        # {composerId, name, createdAt, lastUpdatedAt}
        $GlobalConn,      # SQLite connection
        [string]$Project
    )

    $cid = $CompMeta.composerId
    if (-not $cid) { return $null }

    # Fetch composerData from global
    $cdRow = Invoke-SqliteQuery -SQLiteConnection $GlobalConn -Query "SELECT value FROM cursorDiskKV WHERE key=@k" -SqlParameters @{k="composerData:$cid"}
    if (-not $cdRow) { return $null }
    $cdJson = ConvertTo-StringValue $cdRow.value
    try { $cd = $cdJson | ConvertFrom-Json } catch { return $null }

    $headers = $cd.fullConversationHeadersOnly
    if (-not $headers -or $headers.Count -lt $MinBubbles) { return $null }

    # Fetch all bubbles for this composer in one query
    $bubbles = @{}
    $bRows = Invoke-SqliteQuery -SQLiteConnection $GlobalConn -Query "SELECT key, value FROM cursorDiskKV WHERE key LIKE @p" -SqlParameters @{p="bubbleId:$cid`:%"}
    foreach ($r in $bRows) {
        $bid = ($r.key -split ':')[2]
        $bv  = ConvertTo-StringValue $r.value
        try { $bubbles[$bid] = $bv | ConvertFrom-Json } catch { }
    }
    if ($bubbles.Count -eq 0) { return $null }

    # Determine timestamps
    $createdMs = if ($cd.createdAt) { [int64]$cd.createdAt } elseif ($CompMeta.createdAt) { [int64]$CompMeta.createdAt } else { 0 }
    $lastMs    = if ($cd.lastUpdatedAt) { [int64]$cd.lastUpdatedAt } elseif ($CompMeta.lastUpdatedAt) { [int64]$CompMeta.lastUpdatedAt } else { 0 }
    $createdDt = $null; $createdStr = ''; $lastStr = ''
    if ($createdMs -gt 0) {
        try { $createdDt = [DateTimeOffset]::FromUnixTimeMilliseconds($createdMs).LocalDateTime; $createdStr = $createdDt.ToString('yyyy-MM-dd HH:mm:ss') } catch {}
    }
    if ($lastMs -gt 0) {
        try { $lastStr = [DateTimeOffset]::FromUnixTimeMilliseconds($lastMs).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss') } catch {}
    }

    $name  = if ($cd.name) { $cd.name } elseif ($CompMeta.name) { $CompMeta.name } else { '(untitled)' }
    $model = if ($cd.modelConfig -and $cd.modelConfig.modelName) { $cd.modelConfig.modelName } else { '' }
    $mode  = if ($cd.unifiedMode) { $cd.unifiedMode } else { '' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# Cursor session - $Project")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- **title:** $name")
    [void]$sb.AppendLine("- **composer:** ``$cid``")
    if ($createdStr) { [void]$sb.AppendLine("- **started:** $createdStr") }
    if ($lastStr)    { [void]$sb.AppendLine("- **last msg:** $lastStr") }
    [void]$sb.AppendLine("- **bubbles:** $($headers.Count)")
    if ($model) { [void]$sb.AppendLine("- **model:** $model") }
    if ($mode)  { [void]$sb.AppendLine("- **mode:** $mode") }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine('')

    $rendered = 0
    foreach ($h in $headers) {
        $b = $bubbles[$h.bubbleId]
        if (-not $b) { continue }
        if ($h.type -eq 1) {
            $txt = Get-BubbleText $b
            if (-not $txt) { continue }
            [void]$sb.AppendLine('## User')
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine((Format-Trunc $txt 8000))
            [void]$sb.AppendLine('')
            $rendered++
        } elseif ($h.type -eq 2) {
            $body = Format-AssistantBubble $b
            if ([string]::IsNullOrWhiteSpace($body)) { continue }
            [void]$sb.AppendLine('## Assistant')
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine($body)
            [void]$sb.AppendLine('')
            $rendered++
        }
    }

    if ($rendered -lt $MinBubbles) { return $null }

    $datePart = if ($createdDt) { $createdDt.ToString('yyyy-MM-dd') } else { 'undated' }
    $sidShort = $cid.Substring(0, [Math]::Min(8, $cid.Length))

    return [pscustomobject]@{
        Project     = $Project
        ComposerId  = $cid
        DatePart    = $datePart
        SidShort    = $sidShort
        Markdown    = $sb.ToString()
        LastUpdated = if ($lastMs -gt 0) { [DateTimeOffset]::FromUnixTimeMilliseconds($lastMs).LocalDateTime } else { Get-Date }
    }
}

function Get-OutPath {
    param($info)
    $proj = ($info.Project -replace '[\\/:*?"<>|]', '_')
    $name = "$($info.DatePart)_$($info.SidShort).md"
    return Join-Path (Join-Path (Join-Path $OutputRoot $proj) 'cursor') $name
}

# ---- main ----

if (-not (Test-Path $WorkspaceRoot)) { throw "Workspace root not found: $WorkspaceRoot" }
if (-not (Test-Path $GlobalDb))      { throw "Global DB not found: $GlobalDb" }

$mode = if ($Execute) { 'EXECUTE' } else { 'PREVIEW' }
Write-Host "Workspace root: $WorkspaceRoot"
Write-Host "Global DB:      $GlobalDb"
Write-Host "Output root:    $OutputRoot"
Write-Host "Mode:           $mode"
Write-Host ''

# Open one global connection (read-only)
$globalConn = New-SQLiteConnection -DataSource $GlobalDb -ReadOnly

# Step 1: walk workspaces, build composerId -> project map
$compToProject = @{}
$wsCount = 0; $wsWithComposers = 0
foreach ($wsDir in Get-ChildItem $WorkspaceRoot -Directory) {
    $wsCount++
    $proj = Get-ProjectFromWorkspaceJson (Join-Path $wsDir.FullName 'workspace.json')
    if (-not $proj) { continue }
    $wsDb = Join-Path $wsDir.FullName 'state.vscdb'
    if (-not (Test-Path $wsDb)) { continue }
    try {
        $row = Invoke-SqliteQuery -DataSource $wsDb -Query "SELECT value FROM ItemTable WHERE key='composer.composerData'"
    } catch { continue }
    if (-not $row) { continue }
    $val = ConvertTo-StringValue $row.value
    try { $cd = $val | ConvertFrom-Json } catch { continue }
    if (-not $cd.allComposers -or $cd.allComposers.Count -eq 0) { continue }
    $wsWithComposers++
    foreach ($c in $cd.allComposers) {
        if ($c.composerId) {
            # First workspace wins (composers usually live in one workspace)
            if (-not $compToProject.ContainsKey($c.composerId)) {
                $compToProject[$c.composerId] = [pscustomobject]@{
                    Project = $proj.Name
                    Meta    = $c
                }
            }
        }
    }
}
Write-Host "Workspaces scanned:        $wsCount"
Write-Host "Workspaces with composers: $wsWithComposers"
Write-Host "Mapped composers:          $($compToProject.Count)"

# Step 2: collect orphans (in global but not in any workspace)
if ($IncludeOrphans) {
    $allCompKeys = Invoke-SqliteQuery -SQLiteConnection $globalConn -Query "SELECT key FROM cursorDiskKV WHERE key LIKE 'composerData:%'"
    $orphanCount = 0
    foreach ($r in $allCompKeys) {
        $cid = $r.key.Substring('composerData:'.Length)
        if (-not $compToProject.ContainsKey($cid)) {
            $compToProject[$cid] = [pscustomobject]@{
                Project = '_orphan'
                Meta    = [pscustomobject]@{ composerId = $cid }
            }
            $orphanCount++
        }
    }
    Write-Host "Orphan composers added:    $orphanCount"
}

# Step 3: render plan
$plan = @()
$idx = 0; $total = $compToProject.Count
foreach ($cid in $compToProject.Keys) {
    $idx++
    if ($idx % 50 -eq 0) { Write-Host "  scanned $idx / $total..." }
    $entry = $compToProject[$cid]
    $info = Convert-CursorComposer -CompMeta $entry.Meta -GlobalConn $globalConn -Project $entry.Project
    if (-not $info) { continue }
    $out = Get-OutPath $info
    $plan += [pscustomobject]@{
        Output      = $out
        Project     = $info.Project
        Info        = $info
        SrcMTime    = $info.LastUpdated
    }
}

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
    }
    $globalConn.Close()
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
Write-Host "Written: $written, Skipped: $skipped"
$globalConn.Close()
