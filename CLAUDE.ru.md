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

```sh
sudo ./core/setup.sh install
```

sudo попросит пароль один раз. Установщик:
- сгенерирует секретный ключ под root
- покажет `otpauth://` URL и QR-код (если есть `qrencode`)
- пропишет sudoers-правило: sudo без пароля **только** для
  `/etc/totp-presence/verify`
- проведёт self-test — попросит свежий код

Помоги человеку привязать аутентификатор:
- **Полноценные аутентификаторы** (Google Authenticator, Authy,
  1Password, Bitwarden) — просто сканируют QR.
- **Apple Passwords на macOS** — требует запись-плейсхолдер:
  Passwords → New Password → Title `totp-presence`, любой
  username/password, Website `https://totp-presence.local`.
  Потом Codes → + → Scan QR Code with Camera → выбрать запись.

### Шаг 3. Установи интеграцию

```sh
sudo ./examples/claude-code-hook/install.sh
```

Создаёт три файла в `/etc/totp-presence/`: хук, файл сессии,
конфигурацию окна. Все принадлежат root. Напечатает JSON-сниппет
для хука — **пока не добавляй**.

### Шаг 4. Подключи MCP-сервер

Добавь запись в `~/.claude.json` — формат и путь описаны в
[examples/mcp-server/README.ru.md](./examples/mcp-server/README.ru.md).
sudo не нужен. После перезапуска Claude Code у агента появятся
инструменты `mcp__totp-presence__totp_verify`,
`mcp__totp-presence__totp_check_session`,
`mcp__totp-presence__totp_status`.

### Шаг 5. Добавь soft-prompt

Открой [examples/soft-prompt/prompt.md](./examples/soft-prompt/prompt.md),
замени `<integration>` на имя интеграции (например `claude-code`),
скопируй блок в CLAUDE.md или system prompt целевого агента.
Это даёт агенту правила: когда проверять сессию, как принимать
коды, чего не делать.

### Шаг 6 (опционально). Включи жёсткую блокировку

Добавь JSON-сниппет из шага 3 в `~/.claude/settings.json`.
Claude Code попросит явное подтверждение от человека — это
подтверждение должно прийти от него, не от тебя.

После этого хук блокирует все инструменты кроме read-only
(`Read`, `Glob`, `Grep`, `LS`, `TodoWrite`, `WebSearch`) до
открытой сессии. Новые инструменты автоматически попадают под
защиту.

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

