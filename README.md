# 🏃 Vibe Runner

**Enforcement-плагин для Claude Code.** Не создаёт новых сущностей — читает существующие rules, hooks, CLAUDE.md и добавляет слой принуждения.

## Проблема

Claude Code **знает** твои правила (загружает из `rules/` и `CLAUDE.md`), но **не всегда им следует**:

```
— Ты руководствуешься моим фреймворком?
— Да, всё загружено через CLAUDE.md и rules/
— Ты всегда строго его придерживаешься?
— Честно — нет, не всегда строго
```

Rules и CLAUDE.md — это рекомендации. Vibe Runner превращает их в принуждение.

## Как работает

```
Сейчас:   rules/ + CLAUDE.md → Claude читает → Claude "забывает" → нарушение
С VR:     rules/ + CLAUDE.md → Claude читает → hooks ПРОВЕРЯЮТ → нарушение БЛОКИРУЕТСЯ
                                              → meta-rule КОРРЕКТИРУЕТ
                                              → compliance log ФИКСИРУЕТ
```

Три механизма:
1. **Hooks** — детерминистические bash-проверки, которые Claude не может проигнорировать
2. **Meta-rule** — правило самокоррекции: нарушил → остановись → исправь → залогируй
3. **Compliance log** — прозрачность: что соблюдено, что нарушено

## Установка

```bash
claude plugin add github:CheatB/vibe-runner
```

Всё. VR автоматически просканирует твой сетап при следующем запуске.

## Что внутри

```
vibe-runner/
├── .claude-plugin/
│   └── plugin.json              # манифест плагина
├── rules/
│   └── vibe-runner.md           # meta-rule: самокоррекция + compliance
├── hooks/
│   └── hooks.json               # определения хуков
├── scripts/
│   ├── vibe-runner-discover.sh  # сканирование 12 типов инструментов
│   └── vibe-runner-check.sh     # детерминистические проверки
├── tests/
│   └── test-vibe-runner.sh      # тесты
├── SECURITY.md
├── LICENSE
└── README.md
```

**4 рабочих файла.** Ничего лишнего.

## Discovery

При первом запуске VR сканирует **все 12 типов инструментов** Claude Code:

| # | Тип | Где ищет |
|---|---|---|
| 1 | Rules | `~/.claude/rules/`, `.claude/rules/` |
| 2 | Hooks | `settings.json`, `.claude/hooks/` |
| 3 | MCP Servers | `~/.claude.json`, `.mcp.json` |
| 4 | Commands | `~/.claude/commands/`, `.claude/commands/` |
| 5 | Skills | `~/.claude/skills/`, `.claude/skills/` |
| 6 | Plugins | установленные плагины |
| 7 | Subagents | `~/.claude/agents/`, `.claude/agents/` |
| 8 | LSP Servers | `.lsp.json` |
| 9 | Auto Memory | `~/.claude/projects/<hash>/memory/` |
| 10 | CLAUDE.md | `./CLAUDE.md`, `.claude/CLAUDE.md`, `~/.claude/CLAUDE.md` |
| 11 | AGENTS.md | корень проекта |
| 12 | settings.json | глобальный / проектный |

Результат → `vibe-runner-discovery.json`. Claude читает его и формирует понимание твоего процесса.

## Enforcement

### TDD

Если ты пишешь в `src/` — VR проверяет, что тест уже существует:

```
[VR:CHECK] ❌ TDD нарушение: нет теста для src/api.py (ожидался tests/test_api.py)
VIOLATION:tdd — напиши тест tests/test_api.py перед кодом
```

### Conventional Commits

```
[VR:CHECK] ❌ Conventional commit нарушение: fixed a bug
VIOLATION:conventional_commit — используй формат: feat|fix|docs|...: описание
```

### Re-discovery

Изменил `rules/` или `CLAUDE.md` во время сессии? VR автоматически пересканирует и обновит inventory.

## Compliance маркеры

После каждого значимого действия Claude выводит:

```
[VR] Write src/api.py | TDD ✅ | Anti-Mirage ✅ | Security ✅
[VR] git commit | Conventional ✅ | Self-review ✅
[VR:INCIDENT] TDD ❌ → написал код без теста → откатил → написал тест → продолжил
```

Всё дублируется в `vibe-runner.log`. В конце сессии — summary:

```
SESSION_SUMMARY: markers=12 incidents=1 violations=0 passes=8
```

## Безопасность

VR читает файлы пользователя — это ответственность. Полная модель безопасности в [SECURITY.md](SECURITY.md).

Ключевое:
- **Read-only** — никогда не модифицирует файлы пользователя
- **No secrets** — из `~/.claude.json` читает только имена серверов, не токены
- **No network** — не отправляет данных наружу
- **No eval** — не выполняет строки как код
- **Minimal deps** — только bash, jq, python3

## Тесты

```bash
bash tests/test-vibe-runner.sh
```

Покрывает: discovery, безопасность (secrets, path traversal, injection), enforcement (TDD, conventional commits), compliance log.

## Требования

- Claude Code (текущая версия)
- bash, jq, python3 (уже есть в системе)
- macOS или Linux

## Лицензия

MIT — [LICENSE](LICENSE)

## Автор

[@CheatB](https://t.me/not_just_a_human) — вайбкодер, менеджер в IT, строю продукты с помощью нейросетей.

Больше про вайбкодинг: [stackovervibe.ru](https://stackovervibe.ru)
