#!/bin/bash
# vibe-runner-discover.sh — Inventory всех 12 типов инструментов Claude Code
# Результат: vibe-runner-discovery.json
#
# БЕЗОПАСНОСТЬ:
# - Читает ТОЛЬКО имена файлов/серверов, НЕ содержимое и НЕ secrets
# - Валидирует пути через realpath (нет path traversal)
# - Не делает HTTP-запросов
# - Не использует eval/exec

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISCOVERY_FILE="${PLUGIN_DIR}/vibe-runner-discovery.json"

# === Безопасность ===

# Валидация CLAUDE_HOME: должен быть внутри $HOME
CLAUDE_HOME=$(realpath "$CLAUDE_HOME" 2>/dev/null || echo "$HOME/.claude")
if [[ "$CLAUDE_HOME" != "$HOME"* ]]; then
    echo "SECURITY_ERROR: CLAUDE_HOME ($CLAUDE_HOME) вне \$HOME" >&2
    exit 1
fi

# Проверка зависимостей
if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 обязателен для discovery" >&2
    exit 1
fi

# === Собираем данные и генерируем JSON через python3 ===
# Используем python3 для ВСЕЙ генерации JSON — это гарантирует валидность

export CLAUDE_HOME PLUGIN_DIR DISCOVERY_FILE HOME

python3 << 'PYEOF'
import json
import os
import glob
import hashlib
from pathlib import Path
from datetime import datetime

claude_home = os.environ.get("CLAUDE_HOME", os.path.expanduser("~/.claude"))
home = os.environ.get("HOME", os.path.expanduser("~"))
plugin_dir = os.environ.get("PLUGIN_DIR", ".")
discovery_file = os.environ.get("DISCOVERY_FILE", os.path.join(plugin_dir, "vibe-runner-discovery.json"))

def list_files(directory, ext="md"):
    """Список файлов с расширением в директории → список имён."""
    pattern = os.path.join(directory, f"*.{ext}")
    return sorted([os.path.basename(f) for f in glob.glob(pattern)])

def list_dirs(directory):
    """Список поддиректорий → список имён."""
    if not os.path.isdir(directory):
        return []
    return sorted([d for d in os.listdir(directory) if os.path.isdir(os.path.join(directory, d))])

def safe_json_load(filepath):
    """Безопасно загружаем JSON, при ошибке — None."""
    try:
        with open(filepath) as f:
            return json.load(f)
    except Exception:
        return None

# === 1. Rules ===
rules_global = list_files(os.path.join(claude_home, "rules"), "md")
rules_project = list_files(".claude/rules", "md")

# === 2. Hooks (из settings.json) ===
hooks = []
settings_data = safe_json_load(os.path.join(claude_home, "settings.json"))
if settings_data and isinstance(settings_data.get("hooks"), list):
    for h in settings_data["hooks"]:
        if isinstance(h, dict):
            hooks.append({
                "event": str(h.get("event", ""))[:50],
                "pattern": str(h.get("pattern", ""))[:50],
                "command": str(h.get("command", ""))[:80]
            })

# Также проверяем .claude/hooks/
project_hooks_data = safe_json_load(".claude/hooks/hooks.json")
if project_hooks_data and isinstance(project_hooks_data.get("hooks"), list):
    for h in project_hooks_data["hooks"]:
        if isinstance(h, dict):
            hooks.append({
                "event": str(h.get("event", ""))[:50],
                "pattern": str(h.get("pattern", ""))[:50],
                "command": str(h.get("command", ""))[:80]
            })

# === 3. MCP Servers ===
# ⚠️ БЕЗОПАСНОСТЬ: ТОЛЬКО ключи (имена серверов), НИКОГДА значения (содержат токены)
mcp_servers = []
claude_json = safe_json_load(os.path.join(home, ".claude.json"))
if claude_json and isinstance(claude_json.get("mcpServers"), dict):
    mcp_servers = sorted(list(claude_json["mcpServers"].keys()))
# Также .mcp.json
mcp_project = safe_json_load(".mcp.json")
if mcp_project and isinstance(mcp_project.get("mcpServers"), dict):
    mcp_servers.extend(sorted(list(mcp_project["mcpServers"].keys())))
    mcp_servers = sorted(list(set(mcp_servers)))

# === 4. Commands ===
commands_global = [os.path.splitext(f)[0] for f in list_files(os.path.join(claude_home, "commands"), "md")]
commands_project = [os.path.splitext(f)[0] for f in list_files(".claude/commands", "md")]

# === 5. Skills ===
skills_global = list_dirs(os.path.join(claude_home, "skills"))
skills_project = list_dirs(".claude/skills")

# === 6. Plugins ===
plugins = []
plugins_cache = os.path.join(claude_home, "plugins", "cache")
if os.path.isdir(plugins_cache):
    plugins = list_dirs(plugins_cache)

# === 7. Subagents ===
subagents_global = [os.path.splitext(f)[0] for f in list_files(os.path.join(claude_home, "agents"), "md")]
subagents_project = [os.path.splitext(f)[0] for f in list_files(".claude/agents", "md")]

# === 8. LSP Servers ===
lsp_servers = []
lsp_data = safe_json_load(".lsp.json")
if lsp_data and isinstance(lsp_data.get("servers"), dict):
    lsp_servers = sorted(list(lsp_data["servers"].keys()))

# === 9. Auto Memory ===
memory_exists = False
memory_files = []
try:
    project_hash = hashlib.md5(os.getcwd().encode()).hexdigest()
    memory_dir = os.path.join(claude_home, "projects", project_hash, "memory")
    if os.path.isdir(memory_dir):
        memory_exists = True
        memory_files = list_files(memory_dir, "md")
except Exception:
    pass

# === 10. CLAUDE.md ===
claude_md_global = os.path.isfile(os.path.join(claude_home, "CLAUDE.md"))
claude_md_project = os.path.isfile("CLAUDE.md") or os.path.isfile(".claude/CLAUDE.md")

# === 11. AGENTS.md ===
agents_md = os.path.isfile("AGENTS.md")

# === 12. settings.json (безопасные ключи) ===
settings_safe = {}
if settings_data:
    if "permissions" in settings_data:
        settings_safe["permissions"] = settings_data["permissions"]
    if "model" in settings_data:
        settings_safe["model"] = settings_data["model"]

# === Проект ===
project_exists = os.path.isdir(".claude") or os.path.isfile("CLAUDE.md")
stack = "unknown"
if os.path.isfile("pyproject.toml") or os.path.isfile("requirements.txt") or os.path.isfile("setup.py"):
    stack = "python"
elif os.path.isfile("package.json"):
    stack = "node"
elif os.path.isfile("go.mod"):
    stack = "go"
elif os.path.isfile("Cargo.toml"):
    stack = "rust"

has_tests = any(os.path.isdir(d) for d in ["tests", "__tests__", "test", "spec"])
has_specs = any(os.path.isdir(d) for d in ["specs", "spec", "docs/specs"])

# === Собираем inventory ===
inventory = {
    "rules_global": rules_global,
    "rules_project": rules_project,
    "hooks": hooks,
    "mcp_servers": mcp_servers,
    "commands_global": commands_global,
    "commands_project": commands_project,
    "skills_global": skills_global,
    "skills_project": skills_project,
    "plugins": plugins,
    "subagents_global": subagents_global,
    "subagents_project": subagents_project,
    "lsp_servers": lsp_servers,
    "auto_memory": {"exists": memory_exists, "files": memory_files},
    "claude_md": {"global": claude_md_global, "project": claude_md_project},
    "agents_md": agents_md,
    "settings": settings_safe
}

result = {
    "vibe_runner_version": "1.0.0",
    "scan_date": datetime.now().isoformat(),
    "claude_home": claude_home,
    "inventory": inventory,
    "project": {
        "exists": project_exists,
        "stack": stack,
        "has_tests": has_tests,
        "has_specs": has_specs
    }
}

# Записываем
with open(discovery_file, "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

# Summary
total = 0
parts = []
for key in ["rules_global", "rules_project", "hooks", "mcp_servers", "commands_global",
            "commands_project", "skills_global", "skills_project", "plugins",
            "subagents_global", "subagents_project", "lsp_servers"]:
    val = inventory.get(key, [])
    if isinstance(val, list):
        count = len(val)
        total += count
        if count > 0:
            parts.append(f"{key}: {count}")

if inventory.get("auto_memory", {}).get("exists"):
    parts.append("auto_memory: yes")
if inventory.get("claude_md", {}).get("global") or inventory.get("claude_md", {}).get("project"):
    parts.append("CLAUDE.md: yes")
if inventory.get("agents_md"):
    parts.append("AGENTS.md: yes")

print(f"DISCOVERY_COMPLETE: {total} инструментов | {' | '.join(parts)}")
PYEOF
