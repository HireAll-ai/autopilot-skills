#!/usr/bin/env bash
# Deploy the current branch to a preview environment and print PREVIEW_URL.
# Platforms: coolify (Hetzner) | do (DigitalOcean App Platform).
set -euo pipefail
[[ -f factory/config.env ]] && source factory/config.env || true

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git push -u origin "$BRANCH"

case "${FACTORY_PREVIEW_PLATFORM:-coolify}" in
  local)
    # Pilot mode: run the dev server on this machine, no deploy platform needed.
    : "${FACTORY_DEV_CMD:?set FACTORY_DEV_CMD in factory/config.env}"
    PORT="${FACTORY_PREVIEW_PORT:-3100}"
    # Namespace artifacts per run when fabro provides the id (spec key decision 5).
    ARTIFACTS_DIR="factory-artifacts${FABRO_RUN_ID:+/$FABRO_RUN_ID}"
    mkdir -p "$ARTIFACTS_DIR"
    (nohup bash -c "$FACTORY_DEV_CMD" >"$ARTIFACTS_DIR/dev-server.log" 2>&1 &)
    for _ in $(seq 1 60); do
      curl -fsS "http://127.0.0.1:$PORT" >/dev/null 2>&1 && break
      sleep 1
    done
    curl -fsS "http://127.0.0.1:$PORT" >/dev/null
    PREVIEW_URL="http://127.0.0.1:$PORT"
    ;;
  coolify)
    # Requires: COOLIFY_URL, COOLIFY_TOKEN, COOLIFY_APP_UUID, PREVIEW_DOMAIN (wildcard)
    : "${COOLIFY_URL:?set COOLIFY_URL}" "${COOLIFY_TOKEN:?set COOLIFY_TOKEN}" "${COOLIFY_APP_UUID:?set COOLIFY_APP_UUID}"
    curl -fsS -X POST "$COOLIFY_URL/api/v1/deploy?uuid=$COOLIFY_APP_UUID&branch=$BRANCH" \
      -H "Authorization: Bearer $COOLIFY_TOKEN"
    SLUG="$(echo "$BRANCH" | tr '/_' '--' | tr '[:upper:]' '[:lower:]')"
    PREVIEW_URL="https://${SLUG}.${PREVIEW_DOMAIN:?set PREVIEW_DOMAIN}"
    ;;
  do)
    # TODO: create/update a per-branch app via `doctl apps create --spec` or the
    # digital-ocean-apps MCP tools; parse the live_url from the app info.
    echo "DigitalOcean preview hook not wired yet" >&2
    exit 1
    ;;
  *)
    echo "Unknown FACTORY_PREVIEW_PLATFORM: ${FACTORY_PREVIEW_PLATFORM}" >&2
    exit 1
    ;;
esac

echo "PREVIEW_URL=$PREVIEW_URL" | tee factory-preview.env
