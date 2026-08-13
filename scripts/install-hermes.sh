#!/usr/bin/env bash
#
# Hardened installer for Hermes Agent (github.com/NousResearch/hermes-agent)
# as a self-hosted personal Telegram assistant.
#
# Run this yourself, on your server, as root:
#   sudo bash scripts/install-hermes.sh
#
# It does NOT run automatically from anywhere else. Read
# docs/SECURITY-CHECKLIST.md first.
#
set -euo pipefail

HERMES_USER="hermes"
INSTALL_DOMAIN="hermes-agent.nousresearch.com"
OFFICIAL_REPO="https://github.com/NousResearch/hermes-agent"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\n\033[1;33m/!\\\033[0m %s\n' "$1"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run this with sudo/root (it needs to create a system user and configure the firewall)."

command -v curl >/dev/null 2>&1 || { apt-get update -y && apt-get install -y curl; }

warn "This installs Hermes Agent ONLY from the official source: ${OFFICIAL_REPO}"
warn "and the official installer domain: https://${INSTALL_DOMAIN}/install.sh"
warn "There are known malvertising campaigns impersonating this project"
warn "(fake Google ads, fake F-Droid listing). Do not run install commands"
warn "from any other source for this project."
read -r -p "Continue with install from the official source? [y/N] " confirm
[ "${confirm:-N}" = "y" ] || [ "${confirm:-N}" = "Y" ] || die "Aborted by user."

# ---------------------------------------------------------------------------
# 1. Dedicated non-root user. The agent gets shell/file access per the
#    upstream security audit (NousResearch/hermes-agent#7826, findings
#    C1/C2) — it must not run as root, and must not be a passwordless
#    sudoer either.
# ---------------------------------------------------------------------------
if id "$HERMES_USER" >/dev/null 2>&1; then
  log "User '$HERMES_USER' already exists, reusing it."
else
  log "Creating dedicated non-root user '$HERMES_USER' (no sudo group membership)."
  adduser --disabled-password --gecos "Hermes Agent service user" "$HERMES_USER"
fi

# Give it access to docker (added below) but NOT to sudo/root.
usermod -aG docker "$HERMES_USER" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Docker, for running the agent's terminal backend containerized instead
#    of directly against the host (reduces blast radius per audit finding
#    C1/H7 — note the audit also flags that container-backend approval
#    checks are currently bypassed unconditionally (C3), so this is
#    defense-in-depth, not a full fix).
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker Engine."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
else
  log "Docker already installed."
fi

# ---------------------------------------------------------------------------
# 3. Firewall: allow inbound SSH only. Telegram gateway uses outbound
#    long-polling, so no inbound ports are required for the bot itself.
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  log "Configuring firewall (ufw): allow SSH only, deny other inbound."
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp
  ufw --force enable
else
  warn "ufw not found — skipping firewall setup. Configure one manually" \
       "(the server should not expose any inbound port besides SSH)."
fi

# ---------------------------------------------------------------------------
# 4. Install Hermes Agent itself, as the unprivileged user, from the
#    official installer only.
# ---------------------------------------------------------------------------
log "Installing Hermes Agent as user '$HERMES_USER' from https://${INSTALL_DOMAIN}/install.sh"
sudo -u "$HERMES_USER" -H bash -c "curl -fsSL https://${INSTALL_DOMAIN}/install.sh | bash"

HERMES_HOME=$(getent passwd "$HERMES_USER" | cut -d: -f6)
REPO_CHECKOUT="${HERMES_HOME}/.hermes/hermes-agent"

if [ -d "$REPO_CHECKOUT/.git" ]; then
  PINNED_COMMIT=$(sudo -u "$HERMES_USER" git -C "$REPO_CHECKOUT" rev-parse HEAD)
  log "Installed hermes-agent at commit: ${PINNED_COMMIT}"
  echo "$PINNED_COMMIT" | sudo -u "$HERMES_USER" tee "${HERMES_HOME}/.hermes/INSTALLED_COMMIT" >/dev/null
  warn "Record this commit. Review the diff before ever running 'hermes update' (audit finding H9)."
fi

# ---------------------------------------------------------------------------
# 5. Show the REAL current CLI help so you can verify exact flag names for
#    the audit-relevant settings before relying on them. Flag names may
#    have changed since the audit (v0.8.0) — do not trust anyone's memory
#    of them, including this script's, verify on your installed version.
# ---------------------------------------------------------------------------
log "Below is the live --help output from your installed version."
log "Cross-check it against docs/SECURITY-CHECKLIST.md before proceeding."
sudo -u "$HERMES_USER" -H bash -lc "hermes --help" || true
echo
sudo -u "$HERMES_USER" -H bash -lc "hermes config --help" || true

cat <<'EOF'

===============================================================================
NEXT STEPS — run these yourself, interactively, as the 'hermes' user:

    sudo -iu hermes

Then, on this server (never paste tokens/API keys into a chat with Claude):

  1. hermes setup            # or: hermes model  — pick your model provider
                              # (recommended: Anthropic Claude — enter your
                              #  Anthropic API key when prompted)

  2. hermes gateway setup    # configure the Telegram bot:
                              #  - paste your @BotFather token when asked
                              #  - enable DM pairing / restrict to your own
                              #    Telegram user ID — do NOT leave it open
                              #    to arbitrary users

  3. Before starting, go through docs/SECURITY-CHECKLIST.md "During install"
     section and verify (using the --help output above) that:
       - YOLO / skip-approval mode is OFF
       - smart/auto-approval is OFF (approvals require your confirmation)
       - a write-safe-root / sandbox path is configured, not full filesystem
         access
       - the terminal backend is Docker/Singularity/Modal, not 'local',
         if you want the container isolation layer

  4. hermes gateway start    # or install as a systemd service (see below)
                              # so it survives reboots/SSH disconnects

Optional systemd service (run as root), so the gateway persists and runs
as the unprivileged 'hermes' user:

    cat > /etc/systemd/system/hermes-gateway.service <<'UNIT'
    [Unit]
    Description=Hermes Agent Telegram Gateway
    After=network-online.target docker.service
    Wants=network-online.target

    [Service]
    Type=simple
    User=hermes
    Group=hermes
    WorkingDirectory=/home/hermes
    ExecStart=/home/hermes/.local/bin/hermes gateway start
    Restart=on-failure
    RestartSec=5
    NoNewPrivileges=true
    ProtectSystem=strict
    ProtectHome=read-only
    ReadWritePaths=/home/hermes/.hermes
    MemoryMax=2G

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable --now hermes-gateway

(Adjust ExecStart path if 'which hermes' as the hermes user shows a
different location.)
===============================================================================
EOF
