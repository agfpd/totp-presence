English version: [CLAUDE.md](./CLAUDE.md)

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
[examples/soft-prompt/prompt.ru.md](./examples/soft-prompt/prompt.ru.md) —
они копируются в CLAUDE.md или system prompt агента.

**Перед началом предупреди человека.** Ты не можешь выполнять
sudo-команды сам — для них нужен пароль, который вводит только
человек. Объясни заранее какие команды понадобятся:

**Обязательные sudo-команды:**
```sh
# Шаг 2 — установка ядра (генерация ключа, sudoers, self-test)
sudo ./core/setup.sh install

# Шаг 3 — установка интеграции (хук, файл сессии, конфигурация)
sudo ./examples/claude-code-hook/install.sh
```

**Опциональные sudo-команды (зависят от настройки):**
```sh
# Шаг 3, если нужно другое окно сессии (по умолчанию 25 мин):
sudo ./examples/claude-code-hook/install.sh --window-minutes 15

# Шаг 6, если агент работает через Telegram/Slack:
sudo ./examples/claude-code-hook/install.sh --messaging-tools "mcp__plugin_telegram_telegram__reply|mcp__plugin_telegram_telegram__react|mcp__plugin_telegram_telegram__edit_message|mcp__plugin_telegram_telegram__download_attachment"
```

**Что потребуется от человека помимо пароля:**
- Шаг 2: отсканировать QR-код аутентификатором (появится в
  терминале) и ввести 6-значный код для проверки.
- Шаг 6 (опционально): подтвердить правку `settings.json`
  когда Claude Code спросит.

Аутентификатор должен быть готов до шага 2 — QR нужно сканировать
сразу. Если человек хочет жёсткую блокировку (шаг 6) — сначала
нужно завершить шаги 1-5 и перезапустить Claude Code.

### Шаг 1. Проверь платформу и зависимости

```sh
uname -s       # должно быть Darwin или Linux. Если нет — нужен WSL.
command -v python3   # стандартная библиотека, pip не нужен
```

Если python3 не найден: на macOS установить через Xcode Command
Line Tools (`xcode-select --install`), на Linux — через пакетный
менеджер (`apt install python3` или аналог).

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

Если self-test не пройден за 3 попытки — ядро установлено, но
привязка аутентификатора может быть неправильной. Попроси человека
проверить: правильная ли запись в аутентификаторе, совпадает ли
время на телефоне. Повторная проверка:
`sudo /etc/totp-presence/verify <свежий-код>`.

### Шаг 3. Установи интеграцию

```sh
sudo ./examples/claude-code-hook/install.sh
```

Создаёт три файла в `/etc/totp-presence/`: хук, файл сессии,
конфигурацию. Все принадлежат root. Напечатает JSON-сниппет
для хука — **пока не добавляй**.

### Шаг 4. Подключи MCP-сервер

```sh
pip3 install fastmcp
```

На macOS с Homebrew Python `pip3 install fastmcp` может отказать
с ошибкой PEP 668. Решение: `pip3 install --break-system-packages
fastmcp` или `pipx install fastmcp`.

Добавь запись в конфиг MCP-серверов. **Спроси человека** куда
добавить — есть два места:
- `~/.claude.json` — глобально для всех проектов
- `.mcp.json` в корне проекта целевого агента — только для него

Не выбирай сам — это решение пользователя. Формат и примеры — в
[examples/mcp-server/README.ru.md](./examples/mcp-server/README.ru.md).
sudo не нужен. После перезапуска Claude Code у агента появятся
инструменты `mcp__totp-presence__totp_verify`,
`mcp__totp-presence__totp_check_session`,
`mcp__totp-presence__totp_status`.

### Шаг 5. Добавь soft-prompt

Открой [examples/soft-prompt/prompt.ru.md](./examples/soft-prompt/prompt.ru.md),
замени `<integration>` на имя интеграции (например `claude-code`).
**Спроси человека** в чей CLAUDE.md добавить блок — текущего агента
(если он и будет использовать totp-presence) или другого. Не
копируй молча в первый попавшийся файл.

Это даёт агенту правила: когда проверять сессию, как принимать
коды, чего не делать.

### Шаг 6 (опционально). Включи жёсткую блокировку

**Не добавляй сниппет сам — предложи человеку и объясни что
произойдёт.**

**Важно:** MCP-сервер из шага 4 должен быть подключён и работать
до включения хука. Проверь что инструменты
`mcp__totp-presence__totp_verify` доступны. Если хук активен,
а MCP-сервер не загружен — агент заблокирован без возможности
открыть сессию.

Перед настройкой:

1. **Какие инструменты защитить?** Проверь какие MCP-серверы
   и инструменты доступны в текущей сессии. Составь рекомендацию —
   покажи человеку список и предложи режим блокировки.

2. **Какой режим блокировки?** Объясни оба:

**Полная блокировка** (рекомендуется). Matcher `".*"` — каждый
вызов проходит через хук. Хук пропускает только безопасные
read-only инструменты и MCP-инструменты totp-presence. Всё
остальное требует сессию. Новые инструменты, плагины и MCP-серверы
автоматически защищены.

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
  `TodoWrite`, `WebSearch`, `ToolSearch`
- MCP-инструменты totp-presence: `mcp__totp-presence__*`
- Каналы связи: настраиваются через `EXTRA_SAFE_TOOLS`
  в конфигурации (см. ниже)

**Выборочная блокировка.** Matcher на конкретные инструменты.
Остальные работают свободно. Агент реже просит код, но новые
инструменты не защищены автоматически.

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

Для MCP-инструментов добавить их серверы в matcher:
`"Bash|Write|Edit|mcp__peekaboo__.*|mcp__computer-use__.*"`

3. **Каналы связи.** Если агент общается с человеком через
   внешний канал (Telegram, Slack), messaging-инструмент
   **обязательно** нужно разрешить без сессии — иначе агент не
   сможет попросить код и заблокируется. Спроси какой канал
   используется и задай при установке:
```sh
sudo ./examples/claude-code-hook/install.sh --messaging-tools "mcp__plugin_telegram_telegram__reply|mcp__plugin_telegram_telegram__react|mcp__plugin_telegram_telegram__edit_message|mcp__plugin_telegram_telegram__download_attachment"
```
   Или вручную в `/etc/totp-presence/claude-code-config` (sudo):
```
EXTRA_SAFE_TOOLS=mcp__plugin_telegram_telegram__reply|mcp__plugin_telegram_telegram__react|mcp__plugin_telegram_telegram__edit_message|mcp__plugin_telegram_telegram__download_attachment
```

4. **Куда добавить сниппет? Спроси человека.**
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
| Настроить messaging | `sudo ./examples/claude-code-hook/install.sh --messaging-tools "tool1\|tool2"` |
| Удалить интеграцию | `sudo ./examples/claude-code-hook/install.sh uninstall` |
| Удалить ядро | `sudo ./core/setup.sh uninstall` |

Удаление: сначала интеграция, потом ядро. Хук из
`~/.claude/settings.json` человек убирает сам — установщик
напечатает точную команду.
