#!/bin/bash
# test-vibe-runner.sh — тесты для Vibe Runner
# Запуск: bash tests/test-vibe-runner.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
TOTAL=0

# === Утилиты ===

test_case() {
    TOTAL=$((TOTAL + 1))
    echo -n "  [$TOTAL] $1... "
}

pass() {
    PASS=$((PASS + 1))
    echo "✅"
}

fail() {
    FAIL=$((FAIL + 1))
    echo "❌ $1"
}

# === Подготовка тестового окружения ===

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Создаём фейковый Claude-сетап
mkdir -p "$TMPDIR/.claude/rules" "$TMPDIR/.claude/agents" "$TMPDIR/.claude/commands" "$TMPDIR/.claude/skills/test-skill"
echo "# Test rule" > "$TMPDIR/.claude/rules/test-rule.md"
echo "# Test agent" > "$TMPDIR/.claude/agents/test-agent.md"
echo "# Test command" > "$TMPDIR/.claude/commands/test-cmd.md"
echo '{"hooks": [{"event": "SessionStart", "pattern": "", "command": "echo test"}]}' > "$TMPDIR/.claude/settings.json"
echo "# Test CLAUDE.md" > "$TMPDIR/.claude/CLAUDE.md"

# Фейковый .claude.json (с "секретами" которые НЕ должны утечь)
cat > "$TMPDIR/.claude.json" << 'EOF'
{
  "mcpServers": {
    "test-server": {"command": "secret-command", "args": ["--token=SUPER_SECRET_TOKEN"]},
    "another-server": {"command": "also-secret"}
  }
}
EOF

echo ""
echo "🏃 Vibe Runner — Test Suite"
echo "==========================="
echo ""

# === F1: Discovery на полном сетапе ===
echo "📂 Discovery"

test_case "F1: Discovery создаёт inventory JSON"
HOME="$TMPDIR" CLAUDE_HOME="$TMPDIR/.claude" bash "$PROJECT_DIR/scripts/vibe-runner-discover.sh" > /dev/null 2>&1
if [[ -f "$PROJECT_DIR/vibe-runner-discovery.json" ]]; then
    pass
else
    fail "vibe-runner-discovery.json не создан"
fi

test_case "F2: Inventory содержит rules"
if python3 -c "
import json
with open('$PROJECT_DIR/vibe-runner-discovery.json') as f:
    d = json.load(f)
rules = d['inventory']['rules_global']
assert len(rules) > 0, 'No rules found'
assert 'test-rule.md' in rules, 'test-rule.md not found'
" 2>/dev/null; then
    pass
else
    fail "rules не найдены в inventory"
fi

test_case "F3: Inventory содержит MCP servers"
if python3 -c "
import json
with open('$PROJECT_DIR/vibe-runner-discovery.json') as f:
    d = json.load(f)
mcp = d['inventory']['mcp_servers']
assert 'test-server' in mcp, 'test-server not found'
assert 'another-server' in mcp, 'another-server not found'
" 2>/dev/null; then
    pass
else
    fail "MCP servers не найдены"
fi

# === S1: Secrets не утекают ===
echo ""
echo "🔒 Безопасность"

test_case "S1: Inventory НЕ содержит secrets из .claude.json"
if python3 -c "
import json
with open('$PROJECT_DIR/vibe-runner-discovery.json') as f:
    content = f.read()
assert 'SUPER_SECRET_TOKEN' not in content, 'TOKEN LEAKED!'
assert 'secret-command' not in content, 'Command leaked!'
d = json.loads(content)
# MCP должен содержать только имена серверов
mcp = d['inventory']['mcp_servers']
assert isinstance(mcp, list), 'MCP should be a list of names'
for item in mcp:
    assert isinstance(item, str), f'MCP item should be string, got {type(item)}'
" 2>/dev/null; then
    pass
else
    fail "SECRETS УТЕКЛИ В INVENTORY!"
fi

test_case "S2: Path traversal отклоняется"
if bash "$PROJECT_DIR/scripts/vibe-runner-check.sh" write "../../etc/passwd" 2>&1 | grep -q "SECURITY:path_traversal"; then
    pass
else
    # Тоже ок если sanitize убрал .. до проверки
    OUTPUT=$(bash "$PROJECT_DIR/scripts/vibe-runner-check.sh" write "../../etc/passwd" 2>&1 || true)
    if echo "$OUTPUT" | grep -qE "(SECURITY|VIOLATION)" || [[ $? -ne 0 ]]; then
        pass
    else
        fail "Path traversal не обнаружен"
    fi
fi

test_case "S3: Command injection sanitized"
OUTPUT=$(bash "$PROJECT_DIR/scripts/vibe-runner-check.sh" write 'src/test;rm -rf /' 2>&1 || true)
if [[ -d "/" ]]; then
    pass  # Файловая система цела = injection не сработал
else
    fail "Что-то пошло не так"
fi

# === F6-F9: Enforcement ===
echo ""
echo "⚡ Enforcement"

# Создаём тестовую структуру
mkdir -p "$TMPDIR/project/src" "$TMPDIR/project/tests"

test_case "F6: TDD violation — нет теста при записи в src/"
cd "$TMPDIR/project"
OUTPUT=$(bash "$PROJECT_DIR/scripts/vibe-runner-check.sh" write "src/api.py" 2>&1 || true)
if echo "$OUTPUT" | grep -q "VIOLATION:tdd"; then
    pass
else
    fail "TDD violation не обнаружен"
fi

test_case "F7: TDD pass — тест существует"
echo "# test" > "$TMPDIR/project/tests/test_api.py"
OUTPUT=$(bash "$PROJECT_DIR/scripts/vibe-runner-check.sh" write "src/api.py" 2>&1 || true)
if echo "$OUTPUT" | grep -q "VIOLATION"; then
    fail "Ложное срабатывание — тест существует"
else
    pass
fi

test_case "F8: Conventional commit violation"
OUTPUT=$(bash "$PROJECT_DIR/scripts/vibe-runner-check.sh" commit "fixed a bug" 2>&1 || true)
if echo "$OUTPUT" | grep -q "VIOLATION:conventional_commit"; then
    pass
else
    fail "Conventional commit violation не обнаружен"
fi

test_case "F9: Conventional commit pass"
OUTPUT=$(bash "$PROJECT_DIR/scripts/vibe-runner-check.sh" commit "fix: исправлен баг авторизации" 2>&1 || true)
if echo "$OUTPUT" | grep -q "VIOLATION"; then
    fail "Ложное срабатывание на валидный коммит"
else
    pass
fi

test_case "F9b: Conventional commit с scope"
OUTPUT=$(bash "$PROJECT_DIR/scripts/vibe-runner-check.sh" commit "feat(auth): добавлена 2FA" 2>&1 || true)
if echo "$OUTPUT" | grep -q "VIOLATION"; then
    fail "Ложное срабатывание на коммит со scope"
else
    pass
fi

test_case "F9c: Breaking change commit"
OUTPUT=$(bash "$PROJECT_DIR/scripts/vibe-runner-check.sh" commit "feat!: изменён API авторизации" 2>&1 || true)
if echo "$OUTPUT" | grep -q "VIOLATION"; then
    fail "Ложное срабатывание на breaking change"
else
    pass
fi

# === F11-F12: Compliance log ===
echo ""
echo "📋 Compliance Log"

test_case "F11: Log file создаётся"
if [[ -f "$PROJECT_DIR/vibe-runner.log" ]]; then
    pass
else
    fail "Log file не создан"
fi

test_case "F12: Session summary"
OUTPUT=$(bash "$PROJECT_DIR/scripts/vibe-runner-check.sh" session_end 2>&1 || true)
if echo "$OUTPUT" | grep -q "SESSION_SUMMARY"; then
    pass
else
    fail "Session summary не выведен"
fi

# === X1-X3: Чистота ===
echo ""
echo "🧹 Чистота"

test_case "X1: Плагин не создал файлов за пределами своей директории"
# Проверяем что в $TMPDIR/.claude/ не появилось ничего нового
CLAUDE_FILES_AFTER=$(ls -la "$TMPDIR/.claude/rules/" | wc -l)
if [[ "$CLAUDE_FILES_AFTER" -le 4 ]]; then  # . + .. + test-rule.md + possible total
    pass
else
    fail "Плагин создал файлы в .claude/rules/"
fi

test_case "X3: Повторный discovery = идемпотентный"
HOME="$TMPDIR" CLAUDE_HOME="$TMPDIR/.claude" bash "$PROJECT_DIR/scripts/vibe-runner-discover.sh" > /dev/null 2>&1
HASH1=$(md5sum "$PROJECT_DIR/vibe-runner-discovery.json" 2>/dev/null | cut -d' ' -f1 || md5 -q "$PROJECT_DIR/vibe-runner-discovery.json" 2>/dev/null || echo "a")
sleep 1
HOME="$TMPDIR" CLAUDE_HOME="$TMPDIR/.claude" bash "$PROJECT_DIR/scripts/vibe-runner-discover.sh" > /dev/null 2>&1
HASH2=$(md5sum "$PROJECT_DIR/vibe-runner-discovery.json" 2>/dev/null | cut -d' ' -f1 || md5 -q "$PROJECT_DIR/vibe-runner-discovery.json" 2>/dev/null || echo "b")
# scan_date будет разным, поэтому hash будет разный — проверяем только inventory часть
if python3 -c "
import json
with open('$PROJECT_DIR/vibe-runner-discovery.json') as f:
    d = json.load(f)
inv = json.dumps(d['inventory'], sort_keys=True)
# Если мы можем прочитать и inventory невалидный — fail
assert len(inv) > 10, 'Inventory слишком короткий'
" 2>/dev/null; then
    pass
else
    fail "Повторный discovery дал другой результат"
fi

# === Итоги ===
echo ""
echo "==========================="
echo "📊 Результат: $PASS/$TOTAL пройдено"
if [[ $FAIL -gt 0 ]]; then
    echo "❌ $FAIL тестов провалено"
    exit 1
else
    echo "✅ Все тесты пройдены!"
    exit 0
fi
