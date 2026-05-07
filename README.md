# ai-chat-exporters

PowerShell scripts to export local AI chat conversations from **Claude Code**,
**VS Code Copilot Chat**, and **Cursor** to readable Markdown, organized by
project.

Born from wanting to uninstall Cursor without losing 500+ chat sessions buried
in a 14 GB SQLite blob store with no export UI. Now keeps a tidy local archive
across all three tools.

## Output layout

```
<OutputRoot>/
  <project-name>/
    claude-code/      <yyyy-MM-dd>_<sessionId8>.md
    vscode-copilot/   <yyyy-MM-dd>_<sessionId8>.md
    cursor/           <yyyy-MM-dd>_<composerId8>.md
  _orphan/cursor/     # Cursor composers no longer linked to any workspace
  _subagents/         # Claude Code subagent transcripts
```

Default `OutputRoot` is `F:\_conversations` — override with `-OutputRoot`.

All scripts are idempotent: re-runs skip files whose source hasn't changed.
Use `-Force` to overwrite.

## Requirements

- Windows + PowerShell 5.1+
- For Cursor: [`PSSQLite`](https://www.powershellgallery.com/packages/PSSQLite)
  module (`Install-Module PSSQLite -Scope CurrentUser`)

## Usage

Each script supports a dry-run preview by default; pass `-Execute` to write.

### Claude Code

Reads `~/.claude/projects/<encoded-path>/*.jsonl` (main sessions and
subagent transcripts).

```powershell
.\export_claude_conversations.ps1                  # preview
.\export_claude_conversations.ps1 -Execute
.\export_claude_conversations.ps1 -Execute -Force  # rewrite all
```

### VS Code Copilot Chat

Reads `%APPDATA%\Code\User\workspaceStorage\<hash>\chatSessions\*.json`.
Project name is resolved from each workspace's `workspace.json` `folder` URI.

```powershell
.\export_vscode_conversations.ps1 -Execute
```

The legacy `memento/interactive-session` key is **not** exported — it only
contains chat input box history, not real conversations.

### Cursor

Reads each workspace's `state.vscdb` (`composer.composerData → allComposers`)
and joins with the global `state.vscdb` `cursorDiskKV` table where actual
messages live as `composerData:<id>` and `bubbleId:<composerId>:<bubbleId>`
rows. Handles both plain `text` bubbles and Cursor's Lexical-editor
`richText` JSON tree.

```powershell
.\export_cursor_conversations.ps1 -Execute                  # workspace-mapped only
.\export_cursor_conversations.ps1 -Execute -IncludeOrphans  # also dump composers
                                                            # not referenced by
                                                            # any current workspace
```

`-MinBubbles 2` (default) skips empty/trivial sessions; lower it to keep
single-message drafts.

## Notes / gotchas

- Cursor stores byte arrays for BLOB columns — the script decodes them as
  UTF-8 before JSON parsing.
- Cursor's `richText` is Lexical editor JSON; a small recursive walker
  reconstructs the plain text when the `text` field is empty.
- Claude Code subagent sessions live under `<sessionId>/subagents/` and
  are written into a `_subagents` sibling folder.
- Project names are inferred from on-disk paths; orphan Cursor composers
  with no workspace pointer fall back to `_orphan/cursor/`.

## License

MIT
