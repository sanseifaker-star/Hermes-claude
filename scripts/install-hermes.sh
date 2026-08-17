#!/usr/bin/env bash
#
# Установка Hermes Agent (github.com/NousResearch/hermes-agent) как личного
# ассистента в Telegram. От root, на чистую Ubuntu 24.04 LTS.
#
#   bash scripts/install-hermes.sh
#
# Скрипт использует ШТАТНЫЕ механизмы Hermes (hermes gateway install), а не
# самодельный системный юнит — самодельный конфликтует с родным
# пользовательским и устраивает respawn storm. См. docs/TROUBLESHOOTING.md.
#
set -euo pipefail

INSTALL_URL="https://hermes-agent.nousresearch.com/install.sh"
INSTALL_URL_ALT="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"
OFFICIAL_REPO="https://github.com/NousResearch/hermes-agent"
NODE_MAJOR_OK=22

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\n\033[1;33m/!\\\033[0m %s\n' "$1"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запускать от root."

# ---------------------------------------------------------------------------
# 0. Источник. Существуют кампании малвертайзинга под видом установки Hermes
#    (фейковая Google-реклама, фейковый листинг на F-Droid). Доверенных
#    источников два, оба ведут в репозиторий NousResearch.
# ---------------------------------------------------------------------------
warn "Ставим ТОЛЬКО из официальных источников:"
warn "  репозиторий: ${OFFICIAL_REPO}"
warn "  инсталлятор: ${INSTALL_URL}"
read -r -p "Продолжить? [y/N] " confirm
case "${confirm:-N}" in y|Y) ;; *) die "Отменено." ;; esac

# ---------------------------------------------------------------------------
# 1. Версия ОС. На 26.04 Playwright не поддерживается, Node 26 вешает
#    установку Chromium. 24.04 LTS работает без обходов.
# ---------------------------------------------------------------------------
OS_VERSION=$(. /etc/os-release && echo "${VERSION_ID:-unknown}")
log "Ubuntu ${OS_VERSION}"
if [ "$OS_VERSION" = "26.04" ]; then
  warn "На 26.04 браузерные инструменты требуют обходов — см. docs/TROUBLESHOOTING.md"
  read -r -p "Всё равно продолжить? [y/N] " c2
  case "${c2:-N}" in y|Y) ;; *) die "Отменено." ;; esac
fi

# ---------------------------------------------------------------------------
# 2. Зависимости. Инсталлятор Hermes ставит их сам, но ffmpeg при неудаче
#    только предупреждает — и голосовые в Telegram потом молча не работают.
# ---------------------------------------------------------------------------
log "Базовые пакеты."
apt-get update -y
apt-get install -y curl ripgrep ffmpeg

# ---------------------------------------------------------------------------
# 3. Файрвол: внутрь только SSH. Telegram работает исходящим long-polling.
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  log "Файрвол: только SSH."
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp
  ufw --force enable
else
  warn "ufw не найден — настройте файрвол вручную."
fi

# ---------------------------------------------------------------------------
# 4. Hermes.
# ---------------------------------------------------------------------------
log "Ставим Hermes Agent."
if ! curl -fsSL "$INSTALL_URL" | bash; then
  warn "Основной инсталлятор недоступен, пробуем зеркало на GitHub."
  curl -fsSL "$INSTALL_URL_ALT" | bash
fi

# shellcheck disable=SC1091
[ -f /root/.bashrc ] && source /root/.bashrc 2>/dev/null || true
export PATH="/usr/local/bin:/root/.local/bin:${PATH}"

command -v hermes >/dev/null 2>&1 || die "Команда hermes не найдена. Проверьте PATH и /root/.bashrc"

log "Штатная самодиагностика:"
hermes doctor || warn "hermes doctor вернул ошибки — разберите их до настройки."

# ---------------------------------------------------------------------------
# 5. Node. Hermes держит свой в ~/.hermes/node. Node 26 вешает установку
#    Chromium на "extracting archive" навсегда.
# ---------------------------------------------------------------------------
HERMES_NODE="/root/.hermes/node/bin/node"
if [ -x "$HERMES_NODE" ]; then
  NODE_VER=$("$HERMES_NODE" --version)
  NODE_MAJOR=$(echo "$NODE_VER" | sed 's/^v\([0-9]*\).*/\1/')
  log "Node у Hermes: ${NODE_VER}"
  [ "$NODE_MAJOR" -gt "$NODE_MAJOR_OK" ] && \
    warn "Node ${NODE_MAJOR} ломает установку Chromium — см. docs/TROUBLESHOOTING.md"
fi

# ---------------------------------------------------------------------------
# 6. Персона.
# ---------------------------------------------------------------------------
SOUL_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hermes-config/SOUL.md"
if [ -f "$SOUL_SRC" ]; then
  log "Кладём персону в /root/.hermes/SOUL.md"
  mkdir -p /root/.hermes
  cp "$SOUL_SRC" /root/.hermes/SOUL.md
fi

# ---------------------------------------------------------------------------
# 7. Безопасные дефолты. Ключи взяты из документации, а не угаданы.
#    approvals.mode=manual — агент спрашивает перед опасными командами.
#    smart отдаёт решение вспомогательной LLM, off (YOLO) снимает проверки.
#    Агент работает от root и принимает команды из Telegram, так что manual.
# ---------------------------------------------------------------------------
log "Ставим approvals.mode=manual."
hermes config set approvals.mode manual || warn "Не удалось выставить approvals.mode — сделайте вручную."

# ---------------------------------------------------------------------------
# 8. Автозапуск. hermes gateway install ставит ШТАТНЫЙ пользовательский
#    сервис. Пользовательские юниты не стартуют без входа пользователя в
#    систему — поэтому включаем lingering. Это правильная замена
#    самодельному системному юниту, который конфликтует с этим.
# ---------------------------------------------------------------------------
log "Включаем lingering, чтобы сервис переживал перезагрузку."
loginctl enable-linger root || warn "loginctl enable-linger не сработал — сервис не переживёт reboot."

cat <<'EOF'

===============================================================================
ДАЛЬШЕ — вручную. Порядок важен.

  1. ПРОВЕРЬТЕ ПРОВАЙДЕРА ДО НАСТРОЙКИ:

       ./scripts/check-tools-support.sh <base_url> <model> <api_key>

     Без tool-calling агент не сможет ни писать файлы, ни выполнять
     команды — и будет уверенно рапортовать об успехе. Мы на это наступили.
     Требование к модели: контекст от 64K токенов.

  2. Модель:
       hermes model
     Ключи ложатся в ~/.hermes/.env, настройки — в ~/.hermes/config.yaml.

  3. Telegram:
       hermes gateway setup
     Токен от @BotFather, свой numeric ID от @userinfobot.
     ОБЯЗАТЕЛЬНО allowlist в ~/.hermes/.env:
       TELEGRAM_ALLOWED_USERS=ВАШ_ID
     Никогда не ставьте GATEWAY_ALLOW_ALL_USERS=true — у бота root.

  4. Сервис (штатный способ, НЕ самодельный системный юнит):
       hermes gateway install
       hermes gateway start
       hermes gateway status
     Логи:
       journalctl --user -u hermes-gateway -f

  5. Боевая проверка, что руки работают. В Telegram:
       запиши строку TEST-1 в /root/.hermes/probe.txt
     На сервере:
       cat /root/.hermes/probe.txt
     Пусто — tools не работают, возвращайтесь к пункту 1.

  6. Проактивность (то, ради чего всё затевалось):
       /sethome            — в Telegram, задать канал для проактивных сообщений
       hermes cron create "0 9 * * 1-5" "..."
     Cron-задачи стартуют в СВЕЖЕЙ сессии и не знают текущий разговор —
     промпт должен быть самодостаточным.

ПОМНИТЕ: агент работает от root и принимает команды из Telegram. Кто получит
доступ к боту — получит сервер. TELEGRAM_ALLOWED_USERS обязателен.
===============================================================================
EOF
