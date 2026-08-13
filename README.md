# Hermes-claude

Материалы для self-hosted развёртывания [Hermes Agent](https://github.com/NousResearch/hermes-agent)
(проект Nous Research) как персонального ассистента в Telegram, плюс инструменты
для синхронизации конфигурации Claude Code между устройствами.

## ⚠️ Прочитать перед установкой

Официальный аудит безопасности hermes-agent (issue
[#7826](https://github.com/NousResearch/hermes-agent/issues/7826)) нашёл
**4 критичные и 9 высоких** уязвимости конфигурации по умолчанию:
неограниченное выполнение shell-команд от LLM, неограниченное чтение файлов
(включая SSH-ключи и credentials), обход approval-проверок в контейнерных
бэкендах, persistent prompt injection через skills.

Это значит: агент с доступом к Telegram и правами на вашем сервере — это
реальная поверхность атаки, а не просто чат-бот. Подробный чек-лист — в
[`docs/SECURITY-CHECKLIST.md`](docs/SECURITY-CHECKLIST.md). **Прочитайте его
перед запуском `scripts/install-hermes.sh`.**

Также существуют кампании малвертайзинга, маскирующиеся под установку Hermes
Agent (фейковая Google-реклама, фейковый листинг на F-Droid). Единственный
доверенный источник — `github.com/NousResearch/hermes-agent` и
`hermes-agent.nousresearch.com`. Скрипт в этом репозитории использует только
эти источники.

## Что внутри

- [`scripts/install-hermes.sh`](scripts/install-hermes.sh) — хардненая
  установка Hermes Agent + Telegram gateway на Ubuntu/Debian сервер.
- [`docs/SECURITY-CHECKLIST.md`](docs/SECURITY-CHECKLIST.md) — что проверить
  до и после установки, с привязкой к конкретным пунктам аудита.
- [`docs/CLAUDE-CODE-SYNC.md`](docs/CLAUDE-CODE-SYNC.md) — как синхронизировать
  конфигурацию Claude Code (`~/.claude`) между несколькими устройствами через
  этот же репозиторий, без утечки секретов.
- [`scripts/sync-claude-config.sh`](scripts/sync-claude-config.sh) — скрипт
  экспорта/импорта конфигурации Claude Code.

## Быстрый старт (Hermes Agent)

На сервере (138.124.24.182), под пользователем `root`, вы сами выполняете:

```bash
git clone https://github.com/sanseifaker-star/Hermes-claude.git
cd Hermes-claude
git checkout claude/hermes-self-hosted-setup-0rwu9g
sudo bash scripts/install-hermes.sh
```

Скрипт **не** выполняется автоматически откуда-либо ещё — у среды, в которой
это готовилось, нет сетевого доступа к вашему серверу (проверено: TCP/22 до
138.124.24.182 недоступен из песочницы). Запускать нужно вручную, с сервера.

Токен Telegram-бота и API-ключ модели скрипт запросит **интерактивно на
сервере** — не вставляйте их в чат с Claude и не коммитьте в git.

## Рекомендация по модели

Выбрана по умолчанию: **Anthropic Claude** (Sonnet 5 для основной работы,
можно Haiku 4.5 для дешёвых фоновых реплик). Причина: агенту с доступом к
shell/файлам и Telegram особенно важна надёжность следования
system-инструкциям и approval-флоу — у Claude это на сегодня стабильнее, чем
у DeepSeek V3/R1, которые заметно дешевле, но менее предсказуемы в
agentic tool-use сценариях именно там, где это критично для безопасности.
DeepSeek можно подключить как более дешёвый вариант для некритичных задач —
`hermes model` позволяет переключаться без переустановки.
