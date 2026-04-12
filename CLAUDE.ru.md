# totp-presence — инструкции проекта

Этот файл читается Claude Code при открытии репозитория.
Описание проекта — в [README.ru.md](./README.ru.md).

---

## Для человека

**totp-presence** — механизм, который даёт AI-агенту способ
убедиться, что он говорит с настоящим владельцем. Подробности и
установка — в [README.ru.md](./README.ru.md). Можно просто сказать
агенту: *«установи мне totp-presence»*.

---

## Для AI-агента

Если человек просит установить totp-presence — следуй этой
инструкции. Правила поведения после установки описаны в
[examples/soft-prompt/prompt.md](./examples/soft-prompt/prompt.md) —
они копируются в CLAUDE.md или system prompt целевого агента.

**Перед началом предупреди человека:** установка потребует ввода
пароля sudo — ты не можешь сделать это сам. Шаги с `sudo` нужно
выполнять вместе: ты подготовишь команду, человек подтвердит и
введёт пароль.

### Шаг 1. Проверь платформу и зависимости

```sh
uname -s       # должно быть Darwin или Linux. Если нет — нужен WSL.
command -v python3   # стандартная библиотека, pip не нужен
```

Опционально: `qrencode` для QR-кода в терминале
(`brew install qrencode` на macOS, `apt install qrencode` на Linux).
Без него установщик покажет URL текстом.

### Шаг 2. Установи ядро

**Перед запуском** подготовь аутентификатор — QR появится во время
установки и его нужно будет сразу отсканировать:

- **Полноценные аутентификаторы** (Google Authenticator, Authy,
  1Password, Bitwarden) — готовы сразу, просто сканируют QR.
- **Apple Passwords на macOS** — требует запись-плейсхолдер заранее:
  Passwords → New Password → Title `totp-presence`, любой
  username/password, Website `https://totp-presence.local`.
  Сохрани. Потом при сканировании: Codes → + → Scan QR Code
  with Camera → выбрать запись.

Когда аутентификатор готов:

```sh
sudo ./core/setup.sh install
```

sudo попросит пароль один раз. Установщик:
- сгенерирует секретный ключ под root
- покажет QR-код — отсканируй аутентификатором
- пропишет sudoers-правило: sudo без пароля **только** для
  `/etc/totp-presence/verify`
- проведёт self-test — попросит свежий код

### Шаг 3. Установи интеграцию

```sh
sudo ./examples/claude-code-hook/install.sh
```

Создаёт три файла в `/etc/totp-presence/`: хук, файл сессии,
конфигурацию окна. Все принадлежат root. Напечатает JSON-сниппет
для хука — **пока не добавляй**.

### Шаг 4. Подключи MCP-сервер

Добавь запись в конфиг MCP-серверов. Есть два места:
- `~/.claude.json` — глобально для всех проектов
- `.mcp.json` в корне проекта — только для этого проекта

Формат и примеры — в
[examples/mcp-server/README.ru.md](./examples/mcp-server/README.ru.md).
sudo не нужен. После перезапуска Claude Code у агента появятся
инструменты `mcp__totp-presence__totp_verify`,
`mcp__totp-presence__totp_check_session`,
`mcp__totp-presence__totp_status`.

На macOS с Homebrew Python `pip3 install fastmcp` может отказать
с ошибкой PEP 668. Решение: `pip3 install --break-system-packages
fastmcp` или использовать `pipx install fastmcp`.

### Шаг 5. Добавь soft-prompt

Открой [examples/soft-prompt/prompt.md](./examples/soft-prompt/prompt.md),
замени `<integration>` на имя интеграции (например `claude-code`),
скопируй блок в CLAUDE.md или system prompt целевого агента.
Это даёт агенту правила: когда проверять сессию, как принимать
коды, чего не делать.

### Шаг 6 (опционально). Включи жёсткую блокировку

**Не добавляй сниппет сам — предложи человеку и объясни что
произойдёт.**

Перед настройкой:

1. **Какие инструменты защитить?** Проверь какие MCP-серверы
   и тулы доступны в текущей сессии. Составь рекомендацию —
   покажи человеку список опасных инструментов и предложи
   режим блокировки.

2. **Какой режим блокировки?** Объясни оба:

**Полная блокировка** (рекомендуется). Matcher `".*"` — каждый
вызов проходит через хук. Хук пропускает только безопасные
read-only инструменты и totp-presence MCP-тулы. Всё остальное
требует сессию.

Плюсы: новые инструменты, плагины и MCP-серверы автоматически
защищены. Не нужно помнить что добавлять. Fail-safe.

```json
{
  "matcher": ".*",
  "hooks": [
    {
      "type": "command",
      "command": "/etc/totp-presence/claude-code-guard.sh"
    }
  ]
}
```

Безопасные инструменты (пропускаются без сессии):
- Встроенные read-only: `Read`, `Glob`, `Grep`, `LS`,
  `TodoWrite`, `WebSearch`
- totp-presence MCP: `mcp__totp-presence__*`
- Каналы связи: настраиваются через `EXTRA_SAFE_TOOLS`
  в config (см. ниже)

**Выборочная блокировка.** Matcher на конкретные инструменты.
Остальные работают свободно.

Плюсы: агент реже просит код, меньше трения.
Минусы: новые инструменты не защищены автоматически.

```json
{
  "matcher": "Bash|Write|Edit|NotebookEdit|WebFetch|Agent|Task",
  "hooks": [
    {
      "type": "command",
      "command": "/etc/totp-presence/claude-code-guard.sh"
    }
  ]
}
```

Для MCP-тулов добавь их серверы в matcher:
`"Bash|Write|Edit|mcp__peekaboo__.*|mcp__computer-use__.*"`

3. **Каналы связи.** Если агент общается с человеком через
   внешний канал (Telegram, Slack), messaging-тул **обязательно**
   нужно разрешить без сессии — иначе агент не сможет попросить
   код и заблокируется навсегда. Спроси какой канал используется
   и добавь в `/etc/totp-presence/claude-code-config` (sudo):
```
EXTRA_SAFE_TOOLS=mcp__plugin_telegram_telegram__reply|mcp__plugin_telegram_telegram__react
```

4. **Куда добавить сниппет?**
   - **Проектный** `<проект>/.claude/settings.json` — только для
     этого агента.
   - **Глобальный** `~/.claude/settings.json` — для всех проектов.

Добавляется в массив `hooks.PreToolUse`. Claude Code попросит
явное подтверждение — это подтверждение должно прийти от
человека, не от тебя.

**Как отключить жёсткую блокировку:** удалить сниппет из
settings.json. Мягкий режим (MCP + soft-prompt) продолжит
работать.

### Справочные команды

| Действие | Команда |
|---|---|
| Проверить установку | `./core/setup.sh status` (без sudo) |
| Изменить окно сессии | `sudo ./examples/claude-code-hook/install.sh --window-minutes N` |
| Удалить интеграцию | `sudo ./examples/claude-code-hook/install.sh uninstall` |
| Удалить ядро | `sudo ./core/setup.sh uninstall` |

Удаление: сначала интеграция, потом ядро. Хук из
`~/.claude/settings.json` человек убирает сам — установщик
напечатает точную команду.

