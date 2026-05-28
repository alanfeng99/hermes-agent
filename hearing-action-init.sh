#!/usr/bin/env bash
# Runs once at container start (via s6-overlay /etc/cont-init.d) as root,
# BEFORE `hermes gateway start` is supervised. Prepares the agent's persistent
# workspace under /opt/data (Hermes home for UID 10000) and starts a tiny HTTP
# health listener so Zeabur's port health-check passes (the gateway itself
# only opens an outbound Slack Socket Mode websocket — no inbound port).
set -euo pipefail

HERMES_DATA=/opt/data
WORKSPACE="${HERMES_DATA}/workspace/hearing-action"
CONFIG_DIR="${HERMES_DATA}/.hermes"

mkdir -p "$CONFIG_DIR" "${HERMES_DATA}/workspace"

# ── 1. Default LLM provider/model (Hermes reads from config.yaml; .env LLM_MODEL
#      is no longer honoured). Only write if missing so user edits survive.
if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
  cat > "${CONFIG_DIR}/config.yaml" <<YAML
model:
  default: ${HERMES_DEFAULT_MODEL:-minimax/MiniMax-M2.7}
YAML
fi

# ── 2. Clone (or refresh) the hearing-action source so the agent can read code.
if [ -n "${GITHUB_PAT:-}" ]; then
  REPO_URL="https://x-access-token:${GITHUB_PAT}@github.com/${HEARING_ACTION_REPO:-alanfeng99/hearing-action}.git"
  if [ -d "${WORKSPACE}/.git" ]; then
    git -C "$WORKSPACE" remote set-url origin "$REPO_URL"
    git -C "$WORKSPACE" fetch --depth 1 origin main && git -C "$WORKSPACE" reset --hard origin/main || true
  else
    git clone --depth 1 "$REPO_URL" "$WORKSPACE" || echo "[init] WARN: clone failed (continuing)"
  fi
  # Strip the token from the on-disk remote URL so an agent listing it can't
  # leak it. Re-injects it from env on every restart above.
  if [ -d "${WORKSPACE}/.git" ]; then
    git -C "$WORKSPACE" remote set-url origin \
      "https://github.com/${HEARING_ACTION_REPO:-alanfeng99/hearing-action}.git"
  fi
else
  echo "[init] GITHUB_PAT not set — skipping source clone"
fi

# ── 3. Persist a tiny pointer file so the agent can find the workspace.
echo "${WORKSPACE}" > "${HERMES_DATA}/.workspace_path"

# ── 4. Fix ownership for the hermes user (UID 10000 default).
chown -R "${HERMES_UID:-10000}:${HERMES_GID:-10000}" "$HERMES_DATA"

# ── 5. Background health listener for Zeabur's HTTP health check.
#      Port = $PORT (Zeabur convention) or 8080. Serves a static OK page.
HEALTH_PORT="${PORT:-8080}"
HEALTH_DIR=/run/hermes-health
mkdir -p "$HEALTH_DIR"
cat > "${HEALTH_DIR}/index.html" <<HTML
<!doctype html><meta charset="utf-8"><title>hermes</title>
<h1>hermes gateway</h1>
<p>OK — Slack Socket Mode is the active interface; no public API exposed.</p>
HTML
# setsid + nohup so it survives cont-init returning.
setsid nohup python3 -m http.server "$HEALTH_PORT" --directory "$HEALTH_DIR" \
  > /var/log/hermes-health.log 2>&1 < /dev/null &
disown || true
echo "[init] health listener on :${HEALTH_PORT}"

echo "[init] hearing-action init complete"
