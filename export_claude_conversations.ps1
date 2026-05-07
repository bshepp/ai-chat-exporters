# Export Claude Code conversations to readable Markdown.
# Walks ~/.claude/projects/<encoded-path>/*.jsonl and writes
#   <OutputRoot>/<project>/claude-code/<yyyy-MM-dd>_<sessionId-short>.md
# Idempotent: skips files whose source mtime <= existing output mtime.
#
# Usage:
#   .\export_claude_conversations.ps1                    # dry run preview
#   .\export_claude_conversations.ps1 -Execute           # write files
#   .\export_claude_conversations.ps1 -Execute -Force    # rewrite all
#
# Notes:
#   - Top-level *.jsonl are main sessions (exported as full .md).
#   - <sessionId>/subagents/agent-*.jsonl are subagent transcripts,
#     exported into a sibling folder with "_subagent" suffix.

[CmdletBinding()]
param(
    [string] $ClaudeRoot = "$env:USERPROFILE\.claude\projects",
    [string] $OutputRoot = 'F:\_conversations',
    [switch] $Execute,
    [switch] $Force,
    [int]    $PreviewLimit = 5
)

$ErrorActionPreference = 'Stop'

function Get-MessagePreview {
    param($content, [int]$max = 4000)
    if ($null -eq $content) { return '' }
    if ($content -is [string]) {
        if ($content.Length -gt $max) { return $content.Substring(0, $max) + "`n... [truncated]" }
        return $content
    }
    return ''
}

function Format-ToolUse {
    param($block)
    $name = $block.name
    $inputJson = ''
    try { $inputJson = ($block.input | ConvertTo-Json -Depth 6 -Compress) } catch { $inputJson = '{}' }
    if ($inputJson.Length -gt 600) { $inputJson = $inputJson.Substring(0, 600) + '...' }
    return "**[tool_use]** ``$name``  ``$inputJson``"
}

function Format-ToolResult {
    param($block)
    $text = ''
    if ($block.content -is [string]) {
        $text = $block.content
    } elseif ($block.content -is [array]) {
        $parts = foreach ($p in $block.content) {
            if ($p.text) { $p.text } elseif ($p.type) { "[$($p.type)]" }
        }
        $text = ($parts -join "`n")
    }
    if ([string]::IsNullOrWhiteSpace($text)) { $text = '(empty result)' }
    if ($text.Length -gt 2000) { $text = $text.Substring(0, 2000) + "`n... [truncated]" }
    $isErr = if ($block.is_error) { ' (error)' } else { '' }
    return @"
<details><summary>tool_result$isErr</summary>

``````
$text
``````

</details>
"@
}

function Convert-MessageContent {
    param($message)
    $out = New-Object System.Text.StringBuilder
    if ($null -eq $message) { return '' }
    $content = $message.content
    if ($content -is [string]) {
        [void]$out.Append((Get-MessagePreview $content))
        return $out.ToString()
    }
    if ($content -isnot [array]) { return '' }
    foreach ($block in $content) {
        switch ($block.type) {
            'text' {
                [void]$out.AppendLine((Get-MessagePreview $block.text))
                [void]$out.AppendLine('')
            }
            'thinking' {
                $t = Get-MessagePreview $block.thinking 1500
                if (-not [string]::IsNullOrWhiteSpace($t)) {
                    [void]$out.AppendLine("<details><summary>thinking</summary>")
                    [void]$out.AppendLine('')
                    [void]$out.AppendLine($t)
                    [void]$out.AppendLine('')
                    [void]$out.AppendLine('</details>')
                    [void]$out.AppendLine('')
                }
            }
            'tool_use' {
                [void]$out.AppendLine((Format-ToolUse $block))
                [void]$out.AppendLine('')
            }
            'tool_result' {
                [void]$out.AppendLine((Format-ToolResult $block))
                [void]$out.AppendLine('')
            }
            default {
                [void]$out.AppendLine("*[$($block.type)]*")
            }
        }
    }
    return $out.ToString()
}

function Convert-Jsonl {
    param([string]$Path)

    $lines = Get-Content -LiteralPath $Path
    if (-not $lines) { return $null }

    $records = foreach ($l in $lines) {
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        try { $l | ConvertFrom-Json } catch { continue }
    }
    if (-not $records) { return $null }

    # Metadata: first record with cwd / sessionId / gitBranch
    $meta = $records | Where-Object { $_.cwd } | Select-Object -First 1
    $cwd        = if ($meta) { $meta.cwd } else { '(unknown)' }
    $sessionId  = if ($meta -and $meta.sessionId) { $meta.sessionId } else { ($records | Where-Object { $_.sessionId } | Select-Object -First 1).sessionId }
    $gitBranch  = if ($meta -and $meta.gitBranch) { $meta.gitBranch } else { '' }
    $firstTs    = ($records | Where-Object { $_.timestamp } | Select-Object -First 1).timestamp
    $lastTs     = ($records | Where-Object { $_.timestamp } | Select-Object -Last 1).timestamp

    $project = if ($cwd -ne '(unknown)') { Split-Path -Leaf $cwd } else { '_unknown' }
    if (-not $project) { $project = '_unknown' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# Claude Code session - $project")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- **cwd:** ``$cwd``")
    [void]$sb.AppendLine("- **session:** ``$sessionId``")
    if ($gitBranch) { [void]$sb.AppendLine("- **git branch:** ``$gitBranch``") }
    if ($firstTs)   { [void]$sb.AppendLine("- **started:** $firstTs") }
    if ($lastTs)    { [void]$sb.AppendLine("- **ended:**   $lastTs") }
    [void]$sb.AppendLine("- **source:** ``$Path``")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine('')

    foreach ($r in $records) {
        switch ($r.type) {
            'user' {
                $body = Convert-MessageContent $r.message
                if (-not [string]::IsNullOrWhiteSpace($body)) {
                    [void]$sb.AppendLine('## User')
                    if ($r.timestamp) { [void]$sb.AppendLine("*$($r.timestamp)*"); [void]$sb.AppendLine('') }
                    [void]$sb.AppendLine($body)
                    [void]$sb.AppendLine('')
                }
            }
            'assistant' {
                $body = Convert-MessageContent $r.message
                if (-not [string]::IsNullOrWhiteSpace($body)) {
                    [void]$sb.AppendLine('## Assistant')
                    if ($r.timestamp) { [void]$sb.AppendLine("*$($r.timestamp)*"); [void]$sb.AppendLine('') }
                    [void]$sb.AppendLine($body)
                    [void]$sb.AppendLine('')
                }
            }
            'summary' {
                if ($r.summary) {
                    [void]$sb.AppendLine('## (summary)')
                    [void]$sb.AppendLine($r.summary)
                    [void]$sb.AppendLine('')
                }
            }
            default {
                # Skip permission-mode, attachment, file-history-snapshot, last-prompt etc.
            }
        }
    }

    return [pscustomobject]@{
        Project   = $project
        SessionId = $sessionId
        Cwd       = $cwd
        FirstTs   = $firstTs
        Markdown  = $sb.ToString()
    }
}

function Get-OutPath {
    param($info, [string]$Subkind = 'claude-code', [string]$Suffix = '')
    $proj = ($info.Project -replace '[\\/:*?"<>|]', '_')
    $datePart = if ($info.FirstTs) {
        try { ([datetime]$info.FirstTs).ToString('yyyy-MM-dd') } catch { 'undated' }
    } else { 'undated' }
    $sidShort = if ($info.SessionId) { $info.SessionId.Substring(0, [Math]::Min(8, $info.SessionId.Length)) } else { 'nosess' }
    $name = "${datePart}_${sidShort}${Suffix}.md"
    return Join-Path (Join-Path (Join-Path $OutputRoot $proj) $Subkind) $name
}

# ---- main ----

if (-not (Test-Path $ClaudeRoot)) { throw "Claude root not found: $ClaudeRoot" }

$mainFiles = @()
foreach ($d in Get-ChildItem $ClaudeRoot -Directory) {
    $mainFiles += Get-ChildItem $d.FullName -Filter '*.jsonl' -File
}
$subFiles = Get-ChildItem $ClaudeRoot -Filter 'agent-*.jsonl' -Recurse -File

Write-Host "Main session files:    $($mainFiles.Count)"
Write-Host "Subagent transcripts:  $($subFiles.Count)"
Write-Host "Output root:           $OutputRoot"
$mode = if ($Execute) { 'EXECUTE' } else { 'PREVIEW' }
Write-Host "Mode:                  $mode"
Write-Host ""

$plan = @()

foreach ($f in $mainFiles) {
    $info = Convert-Jsonl -Path $f.FullName
    if (-not $info) { continue }
    $out = Get-OutPath -info $info -Subkind 'claude-code'
    $plan += [pscustomobject]@{
        Source = $f.FullName
        Output = $out
        Project = $info.Project
        Kind = 'main'
        Info = $info
        SrcMTime = $f.LastWriteTime
    }
}

foreach ($f in $subFiles) {
    $info = Convert-Jsonl -Path $f.FullName
    if (-not $info) { continue }
    # subagent file name carries an agent-* hash
    $agentTag = [IO.Path]::GetFileNameWithoutExtension($f.Name) -replace '^agent-', ''
    $suffix = "_subagent-$($agentTag.Substring(0, [Math]::Min(12, $agentTag.Length)))"
    $out = Get-OutPath -info $info -Subkind 'claude-code/_subagents' -Suffix $suffix
    $plan += [pscustomobject]@{
        Source = $f.FullName
        Output = $out
        Project = $info.Project
        Kind = 'subagent'
        Info = $info
        SrcMTime = $f.LastWriteTime
    }
}

# Group by project for preview
$plan | Group-Object Project | Sort-Object Count -Descending | ForEach-Object {
    $mains = ($_.Group | Where-Object Kind -eq 'main').Count
    $subs  = ($_.Group | Where-Object Kind -eq 'subagent').Count
    "{0,-40} main={1,3}  subagents={2,4}" -f $_.Name, $mains, $subs
} | Select-Object -First 25

Write-Host ""
Write-Host "Total planned outputs: $($plan.Count)"

if (-not $Execute) {
    Write-Host ""
    Write-Host "(Preview only. Re-run with -Execute to write files.)"
    Write-Host "Sample of first $PreviewLimit outputs:"
    $plan | Select-Object -First $PreviewLimit | ForEach-Object {
        Write-Host "  $($_.Output)  <- $($_.Source)"
    }
    return
}

# Execute
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

Write-Host ""
Write-Host "Written: $written"
Write-Host "Skipped (up to date): $skipped"
