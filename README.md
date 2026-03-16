# Vibe Runner 2.0

> Universal enforcement plugin for Claude Code. Reads your existing rules, hooks, CLAUDE.md and adds deterministic checks that Claude cannot ignore.

## What's New in v2.0

**Framework-agnostic enforcement.** Works with any development process — Vibe Framework, corporate standards, or custom rules. No longer limited to basic TDD + conventional commits.

### ✅ Built-in Checks

| Check | What it does | Default |
|-------|--------------|---------|
| **TDD** | Blocks code in src/ without tests in tests/ | ON |
| **File Size** | Blocks files >N lines (configurable limit) | ON (300) |
| **Secrets** | Blocks hardcoded tokens, API keys, passwords | ON |
| **Design Tokens** | Blocks hardcoded colors in UI files | OFF |
| **Env in Code** | Blocks passwords/secrets outside .env | ON |
| **Conventional Commits** | Blocks invalid commit messages | ON |
| **No .env Commit** | Blocks .env files in staging | ON |
| **Diff Size** | Warns on large diffs (>N lines) | ON (500) |

### 🔧 Custom Checks

Define your own rules via `vibe-runner.config.json`:

```json
{
  "custom_checks": [
    {
      "name": "no-print-logging",
      "on": "write",
      "pattern": "*.py", 
      "grep": "\\bprint\\(",
      "exclude_grep": "vr-ignore",
      "severity": "block",
      "message": "Use logging.getLogger() instead of print()"
    }
  ]
}
```

**Supported custom check types:**
- `grep` — block if pattern found
- `must_contain` — warn if pattern NOT found  
- `function_length` — limit function size
- `file_exists` — require specific files
- Commit hooks: `grep_staged`, `grep_message`

### 📋 Phase Control (Optional)

For frameworks with development phases (like Vibe Framework):

```json
{
  "phases": {
    "enabled": true,
    "definitions": [
      {"id": "spec", "artifact": "specs/*.md", "artifact_min_size": 500},
      {"id": "build", "artifact": "src/*"}
    ],
    "gates": [
      {"from": "spec", "to": "build", "require_artifact": true}
    ]
  }
}
```

Blocks writing to `src/` until spec artifact is complete.

## Installation

1. **Install the plugin:**
   ```bash
   claude plugin add ./vibe-runner
   ```

2. **Works immediately** with defaults (TDD + secrets + conventional commits)

3. **Optional:** Create `vibe-runner.config.json` for customization

## Configuration

### Minimal Setup
No config file needed. Works out-of-the-box with sensible defaults.

### Custom Configuration
Create `vibe-runner.config.json` in your project root:

```json
{
  "checks": {
    "file-size": {"enabled": true, "limit": 200},
    "tdd": {"enabled": true, "src": "app/", "tests": "spec/"},
    "design-tokens": {"enabled": true}
  },
  "custom_checks": [
    {
      "name": "no-console-log",
      "on": "write",
      "pattern": "*.js|*.ts",
      "grep": "console\\.log\\(",
      "severity": "warn",
      "message": "Use a proper logger"
    }
  ]
}
```

**Pre-made templates:**
- `templates/minimal.json` — Default settings
- `templates/corporate.json` — Corporate standards (Jira commits, stricter limits)  
- `templates/vibe-framework.json` — Full Vibe Framework setup with phases

## How It Works

1. **Discovery** — Scans your `.claude/` directory for rules, hooks, agents, skills
2. **Enforcement** — Hooks into Claude Code's file write/commit operations  
3. **Blocking** — Returns `exit 1` to prevent action when rules violated
4. **Logging** — Records all violations and passes in `vibe-runner.log`

**Hook events:**
- `SessionStart` → Discovery scan
- `PostToolUse(Write|Edit)` → File checks  
- `PreToolUse(Bash: git commit)` → Commit checks
- `Stop` → Session summary

## Examples

### Corporate Team
```json
{
  "checks": {
    "file-size": {"limit": 200},
    "conventional-commits": {"pattern": "^[A-Z]+-[0-9]+: .+"}
  },
  "custom_checks": [
    {
      "name": "require-error-handling",
      "pattern": "src/api/*.py",
      "must_contain": "try:|except:",
      "severity": "warn"
    }
  ]
}
```

### UI Project with Design System
```json
{
  "checks": {
    "design-tokens": {"enabled": true},
    "tdd": {"enabled": false}
  },
  "custom_checks": [
    {
      "name": "no-inline-styles",  
      "pattern": "*.tsx|*.jsx",
      "grep": "style=\\{\\{",
      "severity": "block"
    }
  ]
}
```

### Vibe Framework Project
Use `templates/vibe-framework.json` for full phase control with gates, subagent tracking, and framework-specific custom checks.

## Escape Hatch

Add `# vr-ignore` to any line to exclude it from custom checks:
```python
print("debug info")  # vr-ignore
```

## Security

- **Read-only** — Never modifies your files
- **No secrets** — Discovery excludes token values
- **No network** — All checks run locally
- **Path validation** — Prevents traversal attacks
- **No code execution** — Uses regex/glob patterns only

## Troubleshooting

**"Custom check not triggering"**
- Check pattern matches your file: `*.py` vs `src/**/*.py`
- Verify regex syntax in `grep`/`must_contain`
- Use `vr-ignore` comment to test

**"Phase blocked unexpectedly"**  
- Check `vibe-runner-state.json` for current phase
- Verify artifact completeness (size + required sections)
- Set `phases: null` to disable

**"Too many false positives"**
- Change `severity` from `block` to `warn`
- Add `exclude_grep: "vr-ignore"` pattern
- Adjust thresholds (`limit`, `warn`)

## Migration from v1.0

v2.0 is **backward compatible**. Existing projects continue working with the same TDD + conventional commits enforcement.

**New features:**
- Custom checks replace meta-rule enforcement  
- Phase control for structured workflows
- Granular configuration per check type
- Templates for common setups

## Development

**Test suite:**
```bash
bash tests/test-vibe-runner.sh
```

**Security audit:**  
All paths validated, no eval/exec, stderr handling, log rotation.

## License

MIT