#!/usr/bin/env bash
# Idempotently provisions a Dependency-Track team plus API key and stores the
# key in a Kubernetes secret. Meant to run as a k8s init job; needs bash, curl,
# jq and kubectl (for example the alpine/k8s image).
#
# Required environment:
#   DTRACK_URL            base URL of Dependency-Track
#   DTRACK_ADMIN_API_KEY  API key of a team holding ACCESS_MANAGEMENT
#                         (mount it from a secret, never bake it into the image)
#
# Optional environment:
#   TEAM_NAME             team to create                      (default: cve-reporting)
#   TEAM_PERMISSIONS      comma separated permissions         (default: VIEW_PORTFOLIO,VIEW_VULNERABILITY)
#   SECRET_NAME           secret that receives the key        (default: dtrack-<team>-api-key)
#   NAMESPACE             namespace of that secret            (default: the pod's namespace)
#   WAIT_TIMEOUT_SECONDS  how long to wait for the API        (default: 300)
#
# The secret holds DTRACK_URL and DTRACK_API_KEY, the variable names the
# dtrack-cve CLI reads. The pod's service account needs get/create/patch on
# secrets in NAMESPACE.

set -euo pipefail

readonly SERVICE_ACCOUNT_NAMESPACE_FILE=/var/run/secrets/kubernetes.io/serviceaccount/namespace
readonly PAGE_SIZE=100
readonly MAX_PAGES=1000

HTTP_STATUS=""
HTTP_BODY=""
TEAM_JSON=""
WORK_DIR=""

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

cleanup() {
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

load_settings() {
  DTRACK_URL="${DTRACK_URL:-}"
  DTRACK_URL="${DTRACK_URL%/}"
  [[ -n "$DTRACK_URL" ]] || fail "DTRACK_URL is not set"
  [[ -n "${DTRACK_ADMIN_API_KEY:-}" ]] || fail "DTRACK_ADMIN_API_KEY is not set"

  TEAM_NAME="${TEAM_NAME:-cve-reporting}"
  TEAM_PERMISSIONS="${TEAM_PERMISSIONS:-VIEW_PORTFOLIO,VIEW_VULNERABILITY}"
  WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-300}"

  local default_secret_name
  default_secret_name=$(printf 'dtrack-%s-api-key' "$TEAM_NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')
  SECRET_NAME="${SECRET_NAME:-$default_secret_name}"
  [[ "$SECRET_NAME" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || fail "invalid secret name: $SECRET_NAME"

  NAMESPACE="${NAMESPACE:-}"
  if [[ -z "$NAMESPACE" && -r "$SERVICE_ACCOUNT_NAMESPACE_FILE" ]]; then
    NAMESPACE=$(<"$SERVICE_ACCOUNT_NAMESPACE_FILE")
  fi
  [[ -n "$NAMESPACE" ]] || fail "NAMESPACE is not set and no service account namespace was found"
}

# Sets HTTP_STATUS and HTTP_BODY. The API key goes to curl through stdin so it
# never shows up in a process listing.
dtrack_request() {
  local api_key=$1
  local method=$2
  local path=$3
  local body=${4:-}
  local body_file="$WORK_DIR/response.json"
  local request_file="$WORK_DIR/request.json"

  local curl_arguments=(
    --silent --show-error --max-time 30
    --request "$method"
    --output "$body_file"
    --write-out '%{http_code}'
    --header 'Accept: application/json'
    --config -
  )
  if [[ -n "$body" ]]; then
    printf '%s' "$body" >"$request_file"
    curl_arguments+=(--header 'Content-Type: application/json' --data-binary "@$request_file")
  fi

  if ! HTTP_STATUS=$(printf 'header = "X-Api-Key: %s"\n' "$api_key" | curl "${curl_arguments[@]}" "$DTRACK_URL$path"); then
    fail "request failed: $method $path"
  fi
  HTTP_BODY=$(<"$body_file")
}

wait_for_api() {
  local deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
  log "waiting for Dependency-Track at $DTRACK_URL"
  until curl --silent --fail --max-time 10 --output /dev/null "$DTRACK_URL/api/version"; do
    if ((SECONDS >= deadline)); then
      fail "Dependency-Track did not become ready within ${WAIT_TIMEOUT_SECONDS}s"
    fi
    sleep 5
  done
}

# Sets TEAM_JSON and returns 0 when a team with exactly this name exists.
find_team() {
  local name=$1
  local page=1
  local count
  TEAM_JSON=""

  while ((page <= MAX_PAGES)); do
    dtrack_request "$DTRACK_ADMIN_API_KEY" GET "/api/v1/team?pageNumber=$page&pageSize=$PAGE_SIZE"
    [[ "$HTTP_STATUS" == 200 ]] || fail "listing teams returned HTTP $HTTP_STATUS"

    TEAM_JSON=$(jq -c --arg name "$name" 'first(.[] | select(.name == $name)) // empty' <<<"$HTTP_BODY")
    if [[ -n "$TEAM_JSON" ]]; then
      return 0
    fi

    count=$(jq 'length' <<<"$HTTP_BODY")
    if ((count != PAGE_SIZE)); then
      return 1
    fi
    page=$((page + 1))
  done
  fail "more than $MAX_PAGES pages of teams"
}

ensure_team() {
  if find_team "$TEAM_NAME"; then
    log "team '$TEAM_NAME' already exists"
    return
  fi

  log "creating team '$TEAM_NAME'"
  local payload
  payload=$(jq -nc --arg name "$TEAM_NAME" '{name: $name}')
  dtrack_request "$DTRACK_ADMIN_API_KEY" PUT /api/v1/team "$payload"

  case "$HTTP_STATUS" in
    200 | 201)
      TEAM_JSON="$HTTP_BODY"
      ;;
    409)
      find_team "$TEAM_NAME" || fail "team '$TEAM_NAME' reported as existing but not found"
      ;;
    *)
      fail "creating team returned HTTP $HTTP_STATUS"
      ;;
  esac
}

ensure_permissions() {
  local team_uuid
  team_uuid=$(jq -r '.uuid' <<<"$TEAM_JSON")
  [[ -n "$team_uuid" && "$team_uuid" != null ]] || fail "team response has no uuid"

  local permission
  local permissions
  IFS=',' read -r -a permissions <<<"$TEAM_PERMISSIONS"
  for permission in "${permissions[@]}"; do
    permission="${permission//[[:space:]]/}"
    [[ -n "$permission" ]] || continue
    [[ "$permission" =~ ^[A-Z_]+$ ]] || fail "invalid permission name: $permission"

    if jq -e --arg permission "$permission" '[.permissions[]?.name] | index($permission) != null' <<<"$TEAM_JSON" >/dev/null; then
      continue
    fi

    log "granting $permission to '$TEAM_NAME'"
    dtrack_request "$DTRACK_ADMIN_API_KEY" POST "/api/v1/permission/$permission/team/$team_uuid"
    case "$HTTP_STATUS" in
      200 | 304) ;;
      *) fail "granting $permission returned HTTP $HTTP_STATUS" ;;
    esac
  done
}

stored_api_key() {
  kubectl --namespace "$NAMESPACE" get secret "$SECRET_NAME" --ignore-not-found \
    --output 'jsonpath={.data.DTRACK_API_KEY}' | base64 -d
}

# Returns 0 when the key works for this team. An unreachable validation
# endpoint is not treated as a revoked key.
stored_key_is_valid() {
  local api_key=$1
  dtrack_request "$api_key" GET /api/v1/team/self

  case "$HTTP_STATUS" in
    200)
      local owner
      owner=$(jq -r '.name // empty' <<<"$HTTP_BODY")
      if [[ "$owner" != "$TEAM_NAME" ]]; then
        log "stored key belongs to team '$owner', not '$TEAM_NAME'"
        return 1
      fi
      return 0
      ;;
    401 | 403)
      log "stored key was rejected by Dependency-Track"
      return 1
      ;;
    404)
      log "warning: /api/v1/team/self not available, trusting the stored key"
      return 0
      ;;
    *)
      fail "validating the stored key returned HTTP $HTTP_STATUS"
      ;;
  esac
}

write_secret() {
  local api_key=$1
  NEW_API_KEY="$api_key" jq -n \
    --arg name "$SECRET_NAME" \
    --arg namespace "$NAMESPACE" \
    --arg team "$TEAM_NAME" \
    --arg url "$DTRACK_URL" \
    '{
      apiVersion: "v1",
      kind: "Secret",
      metadata: {
        name: $name,
        namespace: $namespace,
        labels: {"app.kubernetes.io/managed-by": "dtrack-team-provisioner"},
        annotations: {"dtrack/team": $team}
      },
      type: "Opaque",
      stringData: {DTRACK_URL: $url, DTRACK_API_KEY: env.NEW_API_KEY}
    }' | kubectl apply --filename - >/dev/null
}

revoke_key() {
  local identifier=$1
  log "removing the unused API key again"
  dtrack_request "$DTRACK_ADMIN_API_KEY" DELETE "/api/v1/team/key/$identifier"
  if [[ "$HTTP_STATUS" != 204 && "$HTTP_STATUS" != 200 ]]; then
    log "warning: could not remove the unused API key (HTTP $HTTP_STATUS)"
  fi
}

create_key_and_store() {
  local team_uuid
  team_uuid=$(jq -r '.uuid' <<<"$TEAM_JSON")

  log "creating API key for '$TEAM_NAME'"
  dtrack_request "$DTRACK_ADMIN_API_KEY" PUT "/api/v1/team/$team_uuid/key"
  case "$HTTP_STATUS" in
    200 | 201) ;;
    *) fail "creating API key returned HTTP $HTTP_STATUS" ;;
  esac

  local api_key
  local identifier
  api_key=$(jq -r '.key // empty' <<<"$HTTP_BODY")
  identifier=$(jq -r '.publicId // .key // empty' <<<"$HTTP_BODY")
  [[ -n "$api_key" ]] || fail "API key response contains no key"

  if ! write_secret "$api_key"; then
    revoke_key "$identifier"
    fail "could not write secret $NAMESPACE/$SECRET_NAME"
  fi
  log "stored API key in secret $NAMESPACE/$SECRET_NAME"
}

main() {
  require_command curl
  require_command jq
  require_command kubectl
  require_command base64

  WORK_DIR=$(mktemp -d)
  trap cleanup EXIT

  load_settings
  wait_for_api
  ensure_team
  ensure_permissions

  local existing_key
  existing_key=$(stored_api_key)
  if [[ -n "$existing_key" ]] && stored_key_is_valid "$existing_key"; then
    log "secret $NAMESPACE/$SECRET_NAME already holds a working key, nothing to do"
    return
  fi

  create_key_and_store
}

main "$@"
