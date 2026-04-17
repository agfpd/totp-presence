English version: [PRIOR_ART.md](./PRIOR_ART.md)

# Prior art

На апрель 2026 мы не обнаружили публичного описания именно этой
схемы — TOTP-кода от человека, трактуемого как независимый от
канала сигнал идентичности, который ограничивает использование
инструментов агентом. Если вы знаете о таком описании — заведите
issue; сравнение ниже стоит расширить, а не отстаивать заявку.
Смежные работы, которые существуют:

## [IBM + Auth0 + Yubico, RSAC 2026](https://www.ibm.com/new/announcements/securing-agentic-ai-why-automation-still-needs-human-oversight)

«Human-in-the-Loop authorization framework» для агентного ИИ. Та же
основная идея: криптографическое доказательство присутствия человека
перед высокорисковыми действиями агента. Подход корпоративного
класса — watsonx.ai + CIBA + аппаратный ключ YubiKey, подтверждение
на каждое действие. `totp-presence` решает ту же задачу для
индивидуальных разработчиков: ни одной внешней зависимости, любой
агент, любой MCP-клиент.

## [Checkmarx Zero, 2025](https://checkmarx.com/zero-post/turning-ai-safeguards-into-weapons-with-hitl-dialog-forging/)

«Lies-in-the-Loop / HITL Dialog Forging» формулирует проблему,
утверждает «no silver bullet», решения не предлагает. Этот
репозиторий — один из возможных ответов.

## 1Password + Browserbase, Authn8, open2fa и т. п.

TOTP в *обратном* направлении: агенты доказывают себя сервисам.
Здесь — наоборот: человек доказывает себя агенту.
