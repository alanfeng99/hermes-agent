#!/command/with-contenv bash
# Runs once at container start (via s6-overlay /etc/cont-init.d) as root,
# BEFORE `hermes gateway run` is supervised. Prepares the agent's persistent
# workspace under /opt/data and starts a Caddy reverse-proxy on $PORT that
# fronts the Hermes dashboard (bound to 127.0.0.1:9119) with HTTP basic auth.
# /health on the public port returns OK without auth so Zeabur's port
# health-check passes.
set -euo pipefail

HERMES_DATA=/opt/data
WORKSPACE="${HERMES_DATA}/workspace/hearing-action"
CONFIG_DIR="${HERMES_DATA}/.hermes"

mkdir -p "$CONFIG_DIR" "${HERMES_DATA}/workspace"

# ── 1. Default LLM model
if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
  cat > "${CONFIG_DIR}/config.yaml" <<YAML
model:
  default: ${HERMES_DEFAULT_MODEL:-minimax/MiniMax-M2.7}
YAML
fi

# ── 2. Clone (or refresh) source so the agent can read code.
if [ -n "${GITHUB_PAT:-}" ]; then
  REPO_URL="https://x-access-token:${GITHUB_PAT}@github.com/${HEARING_ACTION_REPO:-alanfeng99/hearing-action}.git"
  if [ -d "${WORKSPACE}/.git" ]; then
    git -C "$WORKSPACE" remote set-url origin "$REPO_URL"
    git -C "$WORKSPACE" fetch --depth 1 origin main && git -C "$WORKSPACE" reset --hard origin/main || true
  else
    git clone --depth 1 "$REPO_URL" "$WORKSPACE" || echo "[init] WARN: clone failed (continuing)"
  fi
  if [ -d "${WORKSPACE}/.git" ]; then
    git -C "$WORKSPACE" remote set-url origin \
      "https://github.com/${HEARING_ACTION_REPO:-alanfeng99/hearing-action}.git"
  fi
else
  echo "[init] GITHUB_PAT not set — skipping source clone"
fi

echo "${WORKSPACE}" > "${HERMES_DATA}/.workspace_path"
chown -R "${HERMES_UID:-10000}:${HERMES_GID:-10000}" "$HERMES_DATA"

# ── 3. Caddy reverse proxy w/ basic auth in front of Hermes dashboard.
PORT="${PORT:-8080}"
DASHBOARD_USER="${DASHBOARD_USER:-admin}"

# Fail-closed when the bcrypt hash is missing — generate a denies-all
# placeholder so Caddy starts but auth never succeeds.
if [ -z "${DASHBOARD_PASS_BCRYPT:-}" ]; then
  echo "[init] WARN: DASHBOARD_PASS_BCRYPT unset — dashboard will deny all logins"
  DASHBOARD_PASS_BCRYPT='$2y$12$XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
fi

mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<CADDY
{
    auto_https off
    admin off
}
:${PORT} {
    @health path /health /up
    handle @health {
        respond "OK" 200
    }
    handle {
        basicauth {
            ${DASHBOARD_USER} ${DASHBOARD_PASS_BCRYPT}
        }
        reverse_proxy 127.0.0.1:9119
    }
}
CADDY

setsid nohup caddy run --config /etc/caddy/Caddyfile --adapter caddyfile \
  > /var/log/hermes-caddy.log 2>&1 < /dev/null &
disown || true
echo "[init] Caddy on :${PORT} → 127.0.0.1:9119 (basic auth gate, /health bypasses)"

echo "[init] hearing-action init complete"
