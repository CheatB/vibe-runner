#!/bin/bash
# vibe-runner-check.sh — детерминистические проверки, которые Claude не может проигнорировать
#
# БЕЗОПАСНОСТЬ:
# - Sanitize всех входных данных
# - Валидация путей через realpath
# - Log rotation при > 1MB
# - Нет eval/exec, нет network calls
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="${PLUGIN_DIR}/vibe-runner.log"
MAX_LOG_SIZE=1048576  # 1MB

ACTION="${1:-}"
TARGET="${2:-}"

# === Безопасность ===

# Sanitize для путей: убираем опасные символы
sanitize_path() {
    local input="$1"
    # Только буквы, цифры, /, ., -, _, пробелы
    echo "$input" | tr -cd 'a-zA-Z0-9/._ -'
}

# Валидация пути: нет выхода за пределы
validate_path() {
    local path="$1"
    local resolved
    resolved=$(realpath -m "$path" 2>/dev/null || echo "$path")
    if [[ "$resolved" == *".."* ]]; then
        echo "SECURITY:path_traversal — подозрительный путь: $path"
        exit 1
    fi
}

# Sanitize применяем ТОЛЬКО к file paths, НЕ к commit messages
if [[ "$ACTION" == "write" ]] && [[ -n "$TARGET" ]]; then
    TARGET=$(sanitize_path "$TARGET")
    validate_path "$TARGET"
fi

# === Логирование ===

log_entry() {
    # Log rotation: если лог > MAX_LOG_SIZE — архивируем
    if [[ -f "$LOG_FILE" ]]; then
        local size
        # macOS = stat -f%z, Linux = stat -c%s
        size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ "$size" -gt "$MAX_LOG_SIZE" ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.old"
        fi
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# === Проверки ===

case $ACTION in
    write)
        # --- Re-discovery: если изменён файл в .claude/rules/ или .claude/hooks/ или CLAUDE.md ---
        if echo "$TARGET" | grep -qE '(\.claude/rules/|\.claude/hooks/|CLAUDE\.md)'; then
            log_entry "[VR:REDISCOVERY] Обнаружено изменение в $TARGET — запуск re-discovery"
            bash "$SCRIPT_DIR/vibe-runner-discover.sh" 2>/dev/null || true
            echo "REDISCOVERY:triggered — инструменты обновлены после изменения $TARGET"
        fi

        # --- TDD: при записи в src/ — тест должен существовать ---
        if echo "$TARGET" | grep -q "src/"; then
            # Формируем ожидаемый путь к тесту
            TEST_FILE=$(echo "$TARGET" | sed 's|src/|tests/test_|')
            if [[ ! -f "$TEST_FILE" ]]; then
                log_entry "[VR:CHECK] ❌ TDD нарушение: нет теста для $TARGET (ожидался $TEST_FILE)"
                echo "VIOLATION:tdd — напиши тест $TEST_FILE перед кодом"
                exit 1
            fi
            log_entry "[VR:CHECK] ✅ TDD: тест для $TARGET существует"
        fi
        ;;

    commit)
        # --- Conventional commits ---
        COMMIT_MSG="$TARGET"
        if ! echo "$COMMIT_MSG" | grep -qE '^(feat|fix|docs|style|refactor|test|chore|ci|build|perf)(\(.+\))?(!)?:'; then
            log_entry "[VR:CHECK] ❌ Conventional commit нарушение: $COMMIT_MSG"
            echo "VIOLATION:conventional_commit — используй формат: feat|fix|docs|style|refactor|test|chore|ci|build|perf: описание"
            exit 1
        fi
        log_entry "[VR:CHECK] ✅ Conventional commit: $COMMIT_MSG"
        ;;

    session_end)
        # --- Итоговая статистика ---
        if [[ -f "$LOG_FILE" ]]; then
            TOTAL=$(grep -c "\[VR\]" "$LOG_FILE" 2>/dev/null || echo 0)
            INCIDENTS=$(grep -c "\[VR:INCIDENT\]" "$LOG_FILE" 2>/dev/null || echo 0)
            VIOLATIONS=$(grep -c "\[VR:CHECK\] ❌" "$LOG_FILE" 2>/dev/null || echo 0)
            PASSES=$(grep -c "\[VR:CHECK\] ✅" "$LOG_FILE" 2>/dev/null || echo 0)
            REDISCOVERIES=$(grep -c "\[VR:REDISCOVERY\]" "$LOG_FILE" 2>/dev/null || echo 0)
            log_entry "[VR:SUMMARY] Сессия завершена | Маркеров: $TOTAL | Инцидентов: $INCIDENTS | Нарушений: $VIOLATIONS | Проверок пройдено: $PASSES | Re-discovery: $REDISCOVERIES"
            echo "SESSION_SUMMARY: markers=$TOTAL incidents=$INCIDENTS violations=$VIOLATIONS passes=$PASSES rediscoveries=$REDISCOVERIES"
        else
            echo "SESSION_SUMMARY: no log file found"
        fi
        ;;

    *)
        echo "Vibe Runner Check v1.0.0"
        echo "Использование: vibe-runner-check.sh {write|commit|session_end} [target]"
        echo ""
        echo "Команды:"
        echo "  write <path>     — проверка TDD + re-discovery при изменении rules"
        echo "  commit <msg>     — проверка conventional commits"
        echo "  session_end      — итоговая статистика compliance"
        exit 1
        ;;
esac
