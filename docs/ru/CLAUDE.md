English version: [../../CLAUDE.md](../../CLAUDE.md)

# totp-presence — инструкции проекта

Этот файл читается Claude Code при открытии репозитория.
Описание проекта — в [README.md](./README.md).

---

## Для человека

**totp-presence** — механизм, который даёт AI-агенту способ
убедиться, что он говорит с настоящим владельцем. Подробности и
установка — в [README.md](./README.md). Можно просто сказать
агенту: *«установи мне totp-presence»*.

---

## Для AI-агента

Если человек просит установить totp-presence — следуй этой
инструкции. Правила поведения после установки описаны в
[examples/soft-prompt/prompt.md](./examples/soft-prompt/prompt.md) —
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

# Шаг 3, чтобы явно зафиксировать режим блокировки (рекомендуется при переустановке):
sudo ./examples/claude-code-hook/install.sh --full-lockdown
sudo ./examples/claude-code-hook/install.sh --selective-edit-write

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
command -v python3   # достаточно стандартной библиотеки, pip не нужен
```

Если python3 не найден: на macOS установить через Xcode Command
Line Tools (`xcode-select --install`), на Linux — через системный
менеджер пакетов (`apt install python3` или аналог).

Опционально: `qrencode` для отображения QR-кода в терминале
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
- пропишет правило sudoers: sudo без пароля **только** для
  `/etc/totp-presence/verify`
- проведёт самопроверку — попросит свежий код

Если самопроверка не прошла за 3 попытки — ядро установлено, но
привязка аутентификатора может быть неправильной. Попроси человека
проверить: правильная ли запись в аутентификаторе, совпадает ли
время на телефоне. Повторная проверка:
`sudo /etc/totp-presence/verify <свежий-код>`.

### Шаг 3. Установи интеграцию

```sh
sudo ./examples/claude-code-hook/install.sh
```

Создаёт два статических файла в `/etc/totp-presence/`: hook и
конфигурацию (`claude-code-guard.sh` и `claude-code-config`, оба
принадлежат root). Файл сессии создаётся верификатором по требованию
при первом успешном TOTP-коде по адресу
`/var/run/totp-presence/<пользователь>/claude-code-session`.
Напечатает JSON-фрагмент для hook — **пока не добавляй**.

### Шаг 4. Подключи MCP-сервер

```sh
pip3 install fastmcp
```

На macOS с Homebrew Python `pip3 install fastmcp` может отказать
с ошибкой PEP 668. Решение: `pip3 install --break-system-packages
fastmcp` или `pipx install fastmcp`.

Добавь запись в конфигурацию MCP-серверов. **Спроси человека** куда
добавить — есть два места:
- `~/.claude.json` — глобально для всех проектов
- `.mcp.json` в корне проекта целевого агента — только для него

Не выбирай сам — это решение пользователя. Формат и примеры — в
[examples/mcp-server/README.md](./examples/mcp-server/README.md).
sudo не нужен. После перезапуска Claude Code у агента появятся
инструменты `mcp__totp-presence__totp_verify`,
`mcp__totp-presence__totp_check_session`,
`mcp__totp-presence__totp_status`.

### Шаг 5. Добавь soft-prompt

Открой [examples/soft-prompt/prompt.md](./examples/soft-prompt/prompt.md),
замени `<integration>` на имя интеграции (например `claude-code`).
**Спроси человека** в чей CLAUDE.md добавить блок — текущего агента
(если он и будет использовать totp-presence) или другого. Не
копируй молча в первый попавшийся файл.

Это даёт агенту правила: когда проверять сессию, как принимать
коды, чего не делать.

### Шаг 6 (опционально). Включи жёсткую блокировку

Не добавляй фрагмент сам — предложи человеку, объясни что
произойдёт, дай ему самостоятельно подтвердить правку.

**Условия:**
- MCP-сервер из шага 4 должен быть подключён, инструменты
  `mcp__totp-presence__totp_verify` должны быть видны. Без этого
  hook заблокирует агента без возможности открыть сессию.
- Если агент общается с человеком через внешний канал (Telegram,
  Slack и т. п.) — передай установщику `--messaging-tools "<имена
  инструментов через вертикальную черту>"`, чтобы инструмент обмена
  сообщениями оставался доступен без сессии. Иначе агент не сможет
  попросить код.

**Решения, которые нужно вынести человеку:**

1. **Режим блокировки.** Полная (селектор `.*`, рекомендуется —
   новые инструменты защищены автоматически) или выборочная (узкий
   селектор — меньше трения, новые инструменты не защищены).
   Зафиксируй режим явно через `--full-lockdown` или
   `--selective-edit-write`, чтобы установщик не унаследовал
   устаревшее значение `EDIT_WRITE_CONFIG_ONLY` молча.

2. **Куда добавить фрагмент.** Проектный
   `<проект>/.claude/settings.json` (только для этого агента) или
   глобальный `~/.claude/settings.json` (для всех проектов). Оба
   варианта добавляются в массив `hooks.PreToolUse`.

Формат фрагмента, содержимое селектора, список безопасных
инструментов, полная семантика `EDIT_WRITE_CONFIG_ONLY` — в
[examples/claude-code-hook/README.md](./examples/claude-code-hook/README.md).

Чтобы отключить: удалить фрагмент из `settings.json`. Мягкий
режим (MCP + soft-prompt) продолжит работать.

### Обновление уже установленного totp-presence

Если totp-presence уже установлен, и человек только что сделал
`git pull` на более новую версию, **не запускай** `install`
заново — установщик ядра перегенерирует секретный ключ и сломает
привязки аутентификаторов. Вместо этого используй путь
обновления:

```sh
sudo ./core/setup.sh update
sudo ./examples/claude-code-hook/install.sh update
```

Обе команды заменяют только установленные скрипты (`verify` и
`claude-code-guard.sh`) и файл версии ядра `VERSION`. Они
сохраняют секретный ключ, правило sudoers, все значения
конфигурации (`WINDOW_SECONDS`, `EXTRA_SAFE_TOOLS`,
`EDIT_WRITE_CONFIG_ONLY`), любую открытую сессию и привязку
аутентификатора. Счётчик неудачных попыток сбрасывается, чтобы
обновлённый верификатор начинал с чистого состояния. Повторная
привязка аутентификатора и перезапуск Claude Code не нужны.

### Удаление

Сначала интеграция, потом ядро:

```sh
sudo ./examples/claude-code-hook/install.sh uninstall
sudo ./core/setup.sh uninstall
```

Фрагмент в `~/.claude/settings.json` установщик не трогает —
печатает точную команду для ручного удаления.
