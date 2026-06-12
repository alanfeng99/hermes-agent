#!/command/with-contenv bash
# Runs once at container start (via s6-overlay /etc/cont-init.d) as root,
# BEFORE `hermes gateway run` is supervised. Prepares the agent's persistent
# workspace under /opt/data and starts a Caddy reverse-proxy on $PORT that
# fronts the Hermes dashboard (s6 `dashboard` service on 0.0.0.0:9119, per
# HERMES_DASHBOARD_HOST/_PORT) with HTTP basic auth. Since v0.16.0 the
# dashboard refuses non-loopback binds unless an auth provider is configured
# or HERMES_DASHBOARD_INSECURE=true is set — we set the latter because Caddy
# is the auth gate. /health on the public port returns OK without auth so
# Zeabur's port health-check passes.
set -euo pipefail

HERMES_DATA=/opt/data
WORKSPACE="${HERMES_DATA}/workspace/hearing-action"

mkdir -p "${HERMES_DATA}/workspace"

# ── 1. Default LLM model
# Hermes resolves config at $HERMES_HOME/config.yaml (= /opt/data/config.yaml
# in the container) — NOT /opt/data/.hermes/config.yaml. Seed only when
# missing so the persistent-volume copy is never clobbered.
if [ ! -f "${HERMES_DATA}/config.yaml" ]; then
  cat > "${HERMES_DATA}/config.yaml" <<YAML
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

# Always-fresh ops cheat sheet (DB + Zeabur log access patterns). The agent
# self-discovers tools via this file, so the user does not have to re-explain.
if [ -d "$WORKSPACE" ] && [ -f /opt/hermes/hermes-context.md ]; then
  install -m 0644 -o "${HERMES_UID:-10000}" -g "${HERMES_GID:-10000}" \
    /opt/hermes/hermes-context.md "${WORKSPACE}/AGENTS.md"
  install -m 0644 -o "${HERMES_UID:-10000}" -g "${HERMES_GID:-10000}" \
    /opt/hermes/hermes-context.md "${HERMES_DATA}/AGENTS.md"
fi
# Trust workspace dir for any user — repo is hermes-owned but root exec contexts
# also need to git-inspect it (cont-init runs as root) without dubious-ownership warns.
git config --system --add safe.directory "$WORKSPACE" 2>/dev/null || true

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
        reverse_proxy 127.0.0.1:9119 {
            header_up Host 127.0.0.1:9119
        }
    }
}
CADDY

setsid nohup caddy run --config /etc/caddy/Caddyfile --adapter caddyfile \
  > /var/log/hermes-caddy.log 2>&1 < /dev/null &
disown || true
echo "[init] Caddy on :${PORT} → 127.0.0.1:9119 (basic auth gate, /health bypasses)"

echo "[init] hearing-action init complete"
