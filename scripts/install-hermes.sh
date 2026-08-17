#!/usr/bin/env bash
#
# Установка Hermes Agent (github.com/NousResearch/hermes-agent) как личного
# ассистента в Telegram. Ставится от root, на чистую Ubuntu 24.04 LTS.
#
# Запускать на сервере:
#   bash scripts/install-hermes.sh
#
# Учитывает грабли из docs/TROUBLESHOOTING.md — прочитайте, если что-то
# пойдёт не так.
#
set -euo pipefail

INSTALL_DOMAIN="hermes-agent.nousresearch.com"
OFFICIAL_REPO="https://github.com/NousResearch/hermes-agent"
NODE_MAJOR_OK=22

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\n\033[1;33m/!\\\033[0m %s\n' "$1"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запускать от root."

# ---------------------------------------------------------------------------
# 0. Предупреждение об источнике. Существуют кампании малвертайзинга под
#    видом установки Hermes Agent (фейковая Google-реклама с PowerShell-
#    однострочником, фейковый листинг на F-Droid). Доверенных источников два.
# ---------------------------------------------------------------------------
warn "Ставим ТОЛЬКО из официальных источников:"
warn "  репозиторий:  ${OFFICIAL_REPO}"
warn "  инсталлятор:  https://${INSTALL_DOMAIN}/install.sh"
warn "Никаких других ссылок для этого проекта не существует."
read -r -p "Продолжить? [y/N] " confirm
case "${confirm:-N}" in
  y|Y) ;;
  *) die "Отменено." ;;
esac

# ---------------------------------------------------------------------------
# 1. Версия ОС. На Ubuntu 26.04 Playwright не поддерживается, Chromium
#    ставится только через PLAYWRIGHT_HOST_PLATFORM_OVERRIDE, а Node 26
#    вешает установку на этапе распаковки.
# ---------------------------------------------------------------------------
OS_VERSION=$(. /etc/os-release && echo "${VERSION_ID:-unknown}")
log "Ubuntu ${OS_VERSION}"
if [ "$OS_VERSION" = "26.04" ]; then
  warn "Ubuntu 26.04: Playwright её официально не поддерживает."
  warn "Браузерные инструменты потребуют обходов — см. docs/TROUBLESHOOTING.md."
  warn "Рекомендуется 24.04 LTS."
  read -r -p "Всё равно продолжить? [y/N] " c2
  case "${c2:-N}" in y|Y) ;; *) die "Отменено." ;; esac
fi

# ---------------------------------------------------------------------------
# 2. Базовые зависимости. ffmpeg нужен для голосовых в Telegram — без него
#    инсталлятор Hermes просто предупреждает и идёт дальше, а голос потом
#    молча не работает.
# ---------------------------------------------------------------------------
log "Ставим базовые пакеты (curl, ripgrep, ffmpeg)."
apt-get update -y
apt-get install -y curl ripgrep ffmpeg

# ---------------------------------------------------------------------------
# 3. Файрвол: внутрь только SSH. Telegram работает исходящим long-polling,
#    входящие порты для бота не нужны.
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  log "Файрвол: разрешаем только SSH."
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp
  ufw --force enable
else
  warn "ufw не найден — настройте файрвол вручную."
fi

# ---------------------------------------------------------------------------
# 4. Собственно Hermes.
# ---------------------------------------------------------------------------
log "Ставим Hermes Agent."
curl -fsSL "https://${INSTALL_DOMAIN}/install.sh" | bash

export PATH="/usr/local/bin:${PATH}"
command -v hermes >/dev/null 2>&1 || {
  # shellcheck disable=SC1091
  [ -f /root/.bashrc ] && source /root/.bashrc || true
}

# ---------------------------------------------------------------------------
# 5. Node. Hermes держит свой Node в ~/.hermes/node. Если туда приехал 26 —
#    Playwright повиснет на "extracting archive" навсегда.
# ---------------------------------------------------------------------------
HERMES_NODE="/root/.hermes/node/bin/node"
if [ -x "$HERMES_NODE" ]; then
  NODE_VER=$("$HERMES_NODE" --version)
  NODE_MAJOR=$(echo "$NODE_VER" | sed 's/^v\([0-9]*\).*/\1/')
  log "Node у Hermes: ${NODE_VER}"
  if [ "$NODE_MAJOR" -gt "$NODE_MAJOR_OK" ]; then
    warn "Node ${NODE_MAJOR} ломает установку Chromium."
    warn "См. docs/TROUBLESHOOTING.md — раздел про подмену на Node 22."
  fi
fi

# ---------------------------------------------------------------------------
# 6. Пользовательский systemd-юнит. Hermes ставит свой в ~/.config/systemd/
#    user/. Если поверх завести системный с тем же именем, они начнут делить
#    блокировку шлюза и устроят respawn storm, который не виден ни в
#    /etc/systemd/system/, ни в дереве процессов.
# ---------------------------------------------------------------------------
log "Проверяем пользовательский systemd-юнит."
if systemctl --user list-unit-files 2>/dev/null | grep -q hermes-gateway; then
  warn "Hermes завёл свой пользовательский юнит hermes-gateway.service."
  warn "Он будет конфликтовать с системным. Гасим его."
  systemctl --user stop hermes-gateway 2>/dev/null || true
  systemctl --user disable hermes-gateway 2>/dev/null || true
  log "Пользовательский юнит отключён."
else
  log "Пользовательского юнита нет — конфликта не будет."
fi

# ---------------------------------------------------------------------------
# 7. Системный юнит. Флаг --replace обязателен: без него, если экземпляр уже
#    запущен, gateway run выходит с кодом 1 и systemd уходит в цикл.
# ---------------------------------------------------------------------------
UNIT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hermes-config/hermes-gateway.service"
if [ -f "$UNIT_SRC" ]; then
  log "Ставим системный юнит."
  cp "$UNIT_SRC" /etc/systemd/system/hermes-gateway.service
  systemctl daemon-reload
  systemctl enable hermes-gateway
  log "Юнит установлен и включён (запустим после настройки модели)."
else
  warn "Юнит не найден: ${UNIT_SRC} — поставьте вручную."
fi

# ---------------------------------------------------------------------------
# 8. Персона.
# ---------------------------------------------------------------------------
SOUL_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hermes-config/SOUL.md"
if [ -f "$SOUL_SRC" ]; then
  log "Кладём персону в /root/.hermes/SOUL.md"
  mkdir -p /root/.hermes
  cp "$SOUL_SRC" /root/.hermes/SOUL.md
fi

# ---------------------------------------------------------------------------
# 9. Фиксируем коммит — чтобы не обновляться вслепую.
# ---------------------------------------------------------------------------
for d in /root/.hermes/hermes-agent /usr/local/lib/hermes-agent; do
  if [ -d "$d/.git" ]; then
    C=$(git -C "$d" rev-parse HEAD 2>/dev/null || true)
    [ -n "$C" ] && { echo "$C" > /root/.hermes/INSTALLED_COMMIT; log "Коммит: ${C}"; }
  fi
done

cat <<'EOF'

===============================================================================
ДАЛЬШЕ — вручную:

  1. Провайдер модели. СНАЧАЛА проверьте, что он умеет tool-calling:

       ./scripts/check-tools-support.sh <base_url> <model> <api_key>

     Без tools агент не сможет ни писать файлы, ни выполнять команды — и
     при этом будет уверенно рапортовать об успехе. Это не теория, мы на
     это уже наступили.

  2. hermes model        — выбрать провайдера и модель
  3. hermes gateway setup — токен бота от @BotFather, привязка к вашему
                            Telegram ID (DM pairing). Не оставляйте бота
                            открытым для всех: у него root на этой машине.

  4. Запуск:
       systemctl start hermes-gateway
       systemctl status hermes-gateway --no-pager

  5. Боевая проверка, что руки работают. Напишите боту в Telegram:
       запиши строку TEST-1 в /root/.hermes/probe.txt
     Затем на сервере:
       cat /root/.hermes/probe.txt
     Пусто — значит tools не работают, возвращайтесь к пункту 1.

ПОМНИТЕ: агент работает от root и принимает команды из Telegram. Кто
получит доступ к боту — получит сервер. Держите DM pairing включённым.
===============================================================================
EOF
