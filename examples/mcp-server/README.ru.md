# mcp-server — MCP-интеграция для totp-presence

MCP-сервер (Model Context Protocol), который даёт агенту инструменты
для проверки идентичности владельца и управления сессией. В отличие от
хука, агент сам решает когда вызвать проверку — проактивно, до
действия, а не реактивно по отказу.

Работает в любом MCP-клиенте: Claude Code, Claude Desktop, Cursor,
Continue — всё, что умеет запускать stdio MCP-сервер.

## Три инструмента

### `totp_verify(code, integration)`

Верификация кода и открытие сессии. Агент получает код от владельца
и вызывает:

Запрос: `totp_verify("847291", "claude-code")`

Ответ при успехе:
```json
{
  "valid": true,
  "session_opened": true,
  "integration": "claude-code",
  "window_seconds": 1500,
  "opened_at": 1775914871,
  "expires_at": 1775916371
}
```

При неверном коде или блокировке — возвращает ошибку с описанием.
При блокировке (5 подряд неверных кодов, 5 минут ожидания) в тексте
ошибки будет время до разблокировки. Повторять не нужно.

### `totp_check_session(integration)`

Неинвазивная проверка — открыта ли сессия:

```json
// сессия открыта
{ "open": true, "expires_in_seconds": 1266 }

// сессия просрочена
{ "open": false, "reason": "session expired" }
```

Позволяет агенту узнать состояние до действия, не дожидаясь отказа
от хука.

### `totp_status()`

Диагностика — что установлено, какие интеграции видны:

```json
{
  "core_installed": true,
  "integrations": [
    { "integration": "claude-code", "open": true, ... }
  ]
}
```

## Зачем это поверх хука

Хук — жёсткий блок: агент узнаёт о проблеме только когда
споткнулся. MCP-инструменты добавляют проактивный слой: агент
проверяет сессию заранее, принимает решения на основе
структурированного контекста (окно, возраст, время до истечения).

Особенно ценно когда:
- Действие формально не защищено хуком, но агент считает его важным.
- Клиент не поддерживает хуки (Claude Desktop, Cursor, Continue).

## Установка

### Требования

1. Ядро: `sudo ./core/setup.sh install`
2. Хотя бы одна интеграция с файлами сессии (например
   `sudo ./examples/claude-code-hook/install.sh` создаёт
   `claude-code-session` и `claude-code-config`)
3. Python 3.10+ и FastMCP:
   ```sh
   pip3 install fastmcp
   ```

### Подключение к MCP-клиенту

MCP-сервер — stdio-процесс. Добавляется записью в конфиг клиента.

**Claude Code** (`~/.claude.json`):
```json
{
  "mcpServers": {
    "totp-presence": {
      "command": "python3",
      "args": ["/absolute/path/to/examples/mcp-server/server.py"]
    }
  }
}
```

После перезапуска появятся инструменты:
`mcp__totp-presence__totp_verify`,
`mcp__totp-presence__totp_check_session`,
`mcp__totp-presence__totp_status`.

**Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json` на macOS) — тот же формат `mcpServers`.

**Cursor / Continue / другие** — у каждого свой способ регистрации
MCP-сервера, команда и аргументы те же.

## Именование интеграций

Имя интеграции — короткая строка вида `[a-z0-9][a-z0-9-]{0,63}`.
Соответствует префиксу файлов в `/etc/totp-presence/`:

| Имя | Файл сессии | Файл конфигурации |
|---|---|---|
| `claude-code` | `claude-code-session` | `claude-code-config` |
| `aider` | `aider-session` | `aider-config` |

Имена с `..`, `/`, заглавными буквами отклоняются сервером. Ядро
дополнительно валидирует путь на своей стороне — двойная защита от
path traversal.

## Почему sudo без пароля

Сервер запускается под обычным пользователем. При вызове verify
использует `sudo -n` (не спрашивай пароль; если NOPASSWD не
настроен — сразу ошибка). Sudoers-правило ядра разрешает
беспарольный sudo только для `/etc/totp-presence/verify`.

## Что сервер НЕ делает

- **Не читает секретный ключ** — он root:600, доступен только ядру.
- **Не пишет сессию напрямую** — только через ядро при верном коде.
- **Не создаёт интеграции** — если сессия не существует, вернёт ошибку.
- **Не устанавливает себя** в конфиги клиентов — добавляется вручную.

## Troubleshooting

**`sudo: a password is required`** — sudoers-правило не установлено.
Проверь: `./core/setup.sh status`.

**`integration 'X' is not installed`** — нет файла
`/etc/totp-presence/X-session`. Вызови `totp_status` чтобы увидеть
доступные интеграции.

**`fastmcp package not installed`** — `pip3 install fastmcp`. Если
Python через pyenv/conda, убедись что MCP-клиент запускает нужный
python — при необходимости укажи полный путь в `"command"`.

## Статус

Референсная реализация. Обкатано в Claude Code. О проблемах с
другими клиентами — issues.
