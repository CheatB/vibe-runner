# Политика безопасности — Vibe Runner

## Модель безопасности

Vibe Runner — плагин, который **читает** конфигурацию Claude Code пользователя. Это требует доверия, поэтому мы следуем строгим принципам.

## Принципы

### 1. Read-only по умолчанию
VR **НИКОГДА** не модифицирует файлы пользователя:
- Не трогает `rules/`, `CLAUDE.md`, `hooks/`, `settings.json`
- Пишет **ТОЛЬКО** в свои файлы: `vibe-runner.log`, `vibe-runner-discovery.json`

### 2. No secrets
Discovery читает **ТОЛЬКО имена** (файлов, серверов, ключей конфигов).
- `~/.claude.json` → только `mcpServers.keys()`, **НИКОГДА** `.values()` (содержат токены)
- `settings.json` → только `permissions`, `model` — **НИКОГДА** credentials
- Inventory JSON не содержит содержимого файлов

### 3. No network
Скрипты VR **не делают HTTP-запросов**, не отправляют данных наружу.

### 4. No eval/exec
Скрипты **не выполняют строки как код**. Весь input sanitized.

### 5. Minimal dependencies
Только то, что уже есть: `bash`, `jq`, `python3`. Нет npm/pip зависимостей.

## Защитные механизмы

| Угроза | Защита |
|---|---|
| Path traversal | `realpath` + валидация: путь не выходит за `$HOME` |
| Command injection | `sanitize()` — whitelist символов, все переменные в кавычках |
| Secrets exposure | Только `.keys()` для JSON, никогда `.values()` |
| JSON injection | `json.load()` — безопасный парсер, нет eval |
| Log overflow | Rotation при > 1MB |
| Race condition | Append-only `>>`, атомарен для строк < PIPE_BUF |

## Сообщить об уязвимости

Если вы обнаружили уязвимость:

1. **НЕ** создавайте публичный issue
2. Напишите в Telegram: [@CheatB](https://t.me/CheatB)
3. Или email: stationplaystoregb@gmail.com

Мы ответим в течение 48 часов.

## Аудит

Код открыт для аудита. Ключевые файлы для проверки:
- `scripts/vibe-runner-discover.sh` — что и как сканируется
- `scripts/vibe-runner-check.sh` — как обрабатывается input
- `hooks/hooks.json` — какие хуки установлены
