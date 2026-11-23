#!/usr/bin/env bash
# Idempotently provisions a Dependency-Track team plus API key and stores the
# key in a Kubernetes secret. Works on a fresh, never-used instance: it takes
# over the default admin account (forced password change) first.
# Meant to run as a k8s init job; needs bash, curl, jq, base64 and kubectl
# (for example the alpine/k8s image).
#
# Required environment:
#   DTRACK_URL               base URL of Dependency-Track
#
# Optional environment:
#   DTRACK_ADMIN_PASSWORD    password the admin account should have. When unset,
#                            a random one is generated and kept in the secret
#                            ADMIN_SECRET_NAME (created before it is applied).
#   DTRACK_ADMIN_API_KEY     skip the admin login and use this key instead
#                            (for instances that are already set up)
#   DTRACK_ADMIN_USERNAME    admin account name                  (default: admin)
#   ADMIN_SECRET_NAME        secret for the generated password   (default: dtrack-admin-credentials)
#   TEAM_NAME                team to create                      (default: cve-reporting)
#   TEAM_PERMISSIONS         comma separated permissions         (default: VIEW_PORTFOLIO,VIEW_VULNERABILITY)
#   SECRET_NAME              secret that receives the key        (default: dtrack-<team>-api-key)
#   NAMESPACE                namespace of the secrets            (default: the pod's namespace)
#   WAIT_TIMEOUT_SECONDS     how long to wait for the API        (default: 300)
#
# The key secret holds DTRACK_URL and DTRACK_API_KEY, the variable names the
# dtrack-cve CLI reads. The pod's service account needs get/create/patch on
# secrets in NAMESPACE.

set -euo pipefail

readonly SERVICE_ACCOUNT_NAMESPACE_FILE=/var/run/secrets/kubernetes.io/serviceaccount/namespace
readonly DEFAULT_ADMIN_PASSWORD=admin
readonly PAGE_SIZE=100
readonly MAX_PAGES=1000

HTTP_STATUS=""
HTTP_BODY=""
TEAM_JSON=""
WORK_DIR=""
ADMIN_AUTH=""
ADMIN_PASSWORD=""
DEADLINE=0

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

is_valid_resource_name() {
  [[ "$1" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]
}

load_settings() {
  DTRACK_URL="${DTRACK_URL:-}"
  DTRACK_URL="${DTRACK_URL%/}"
  [[ -n "$DTRACK_URL" ]] || fail "DTRACK_URL is not set"

  DTRACK_ADMIN_USERNAME="${DTRACK_ADMIN_USERNAME:-admin}"
  DTRACK_ADMIN_PASSWORD="${DTRACK_ADMIN_PASSWORD:-}"
  DTRACK_ADMIN_API_KEY="${DTRACK_ADMIN_API_KEY:-}"
  if [[ -n "$DTRACK_ADMIN_PASSWORD" && "$DTRACK_ADMIN_PASSWORD" == "$DEFAULT_ADMIN_PASSWORD" ]]; then
    fail "DTRACK_ADMIN_PASSWORD must not be the default password"
  fi

  ADMIN_SECRET_NAME="${ADMIN_SECRET_NAME:-dtrack-admin-credentials}"
  is_valid_resource_name "$ADMIN_SECRET_NAME" || fail "invalid secret name: $ADMIN_SECRET_NAME"

  TEAM_NAME="${TEAM_NAME:-cve-reporting}"
  TEAM_PERMISSIONS="${TEAM_PERMISSIONS:-VIEW_PORTFOLIO,VIEW_VULNERABILITY}"
  WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-300}"

  local default_secret_name
  default_secret_name=$(printf 'dtrack-%s-api-key' "$TEAM_NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')
  SECRET_NAME="${SECRET_NAME:-$default_secret_name}"
  is_valid_resource_name "$SECRET_NAME" || fail "invalid secret name: $SECRET_NAME"

  NAMESPACE="${NAMESPACE:-}"
  if [[ -z "$NAMESPACE" && -r "$SERVICE_ACCOUNT_NAMESPACE_FILE" ]]; then
    NAMESPACE=$(<"$SERVICE_ACCOUNT_NAMESPACE_FILE")
  fi
  [[ -n "$NAMESPACE" ]] || fail "NAMESPACE is not set and no service account namespace was found"
}

# Secrets go into curl's config on stdin so they never show up in a process
# listing. Values are quoted for curl's config syntax.
curl_config_escape() {
  local value=$1
  [[ "$value" != *$'\n'* ]] || fail "values containing a newline are not supported"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}

# Sets HTTP_STATUS and HTTP_BODY.
send_request() {
  local method=$1
  local path=$2
  local config=$3
  local body=${4:-}
  local body_file="$WORK_DIR/response.body"
  local request_file="$WORK_DIR/request.body"

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

  if ! HTTP_STATUS=$(printf '%s\n' "$config" | curl "${curl_arguments[@]}" "$DTRACK_URL$path"); then
    fail "request failed: $method $path"
  fi
  HTTP_BODY=$(<"$body_file")
}

# auth is a full header such as "X-Api-Key: ..." or empty for none.
dtrack_request() {
  local auth=$1
  local method=$2
  local path=$3
  local body=${4:-}
  local config=""
  if [[ -n "$auth" ]]; then
    config="header = \"$(curl_config_escape "$auth")\""
  fi
  send_request "$method" "$path" "$config" "$body"
}

# POSTs url-encoded fields (name=value) without authentication.
dtrack_form_request() {
  local path=$1
  shift
  local config=""
  local field
  for field in "$@"; do
    config+="data-urlencode = \"$(curl_config_escape "$field")\""$'\n'
  done
  send_request POST "$path" "$config"
}

wait_for_api() {
  DEADLINE=$((SECONDS + WAIT_TIMEOUT_SECONDS))
  log "waiting for Dependency-Track at $DTRACK_URL"
  until curl --silent --fail --max-time 10 --output /dev/null "$DTRACK_URL/api/version"; do
    if ((SECONDS >= DEADLINE)); then
      fail "Dependency-Track did not become ready within ${WAIT_TIMEOUT_SECONDS}s"
    fi
    sleep 5
  done
}

read_secret_field() {
  local name=$1
  local field=$2
  kubectl --namespace "$NAMESPACE" get secret "$name" --ignore-not-found \
    --output "jsonpath={.data.$field}" | base64 -d
}

generate_password() {
  head -c 256 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | cut -c1-32
}

create_admin_secret() {
  local password=$1
  ADMIN_PASSWORD_VALUE="$password" jq -n \
    --arg name "$ADMIN_SECRET_NAME" \
    --arg namespace "$NAMESPACE" \
    --arg username "$DTRACK_ADMIN_USERNAME" \
    '{
      apiVersion: "v1",
      kind: "Secret",
      metadata: {
        name: $name,
        namespace: $namespace,
        labels: {"app.kubernetes.io/managed-by": "dtrack-team-provisioner"}
      },
      type: "Opaque",
      stringData: {username: $username, password: env.ADMIN_PASSWORD_VALUE}
    }' | kubectl create --filename - >/dev/null
}

# The generated password is stored before Dependency-Track is changed, so a
# crash in between never leaves an admin account nobody knows the password of.
resolve_admin_password() {
  if [[ -n "$DTRACK_ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD="$DTRACK_ADMIN_PASSWORD"
    return
  fi

  ADMIN_PASSWORD=$(read_secret_field "$ADMIN_SECRET_NAME" password)
  if [[ -n "$ADMIN_PASSWORD" ]]; then
    return
  fi

  admin_login "$DEFAULT_ADMIN_PASSWORD"
  if [[ "$HTTP_STATUS" != 401 || "$HTTP_BODY" != *FORCE_PASSWORD_CHANGE* ]]; then
    fail "Dependency-Track is already initialized and no admin credentials were given; set DTRACK_ADMIN_PASSWORD or DTRACK_ADMIN_API_KEY"
  fi

  log "fresh instance, generating admin password and storing it in secret $NAMESPACE/$ADMIN_SECRET_NAME"
  local generated
  generated=$(generate_password)
  [[ ${#generated} -eq 32 ]] || fail "could not generate a password"

  if create_admin_secret "$generated"; then
    ADMIN_PASSWORD="$generated"
    return
  fi

  ADMIN_PASSWORD=$(read_secret_field "$ADMIN_SECRET_NAME" password)
  [[ -n "$ADMIN_PASSWORD" ]] || fail "could not create secret $NAMESPACE/$ADMIN_SECRET_NAME"
}

# Leaves HTTP_STATUS and HTTP_BODY (the JWT on success) of the last attempt.
admin_login() {
  local password=$1
  while :; do
    dtrack_form_request /api/v1/user/login "username=$DTRACK_ADMIN_USERNAME" "password=$password"
    if ((HTTP_STATUS < 500)); then
      return
    fi
    if ((SECONDS >= DEADLINE)); then
      fail "login kept failing with HTTP $HTTP_STATUS"
    fi
    sleep 5
  done
}

use_login_token() {
  [[ -n "$HTTP_BODY" ]] || fail "login returned an empty token"
  ADMIN_AUTH="Authorization: Bearer $HTTP_BODY"
}

take_over_default_admin() {
  admin_login "$DEFAULT_ADMIN_PASSWORD"
  case "$HTTP_STATUS" in
    401)
      if [[ "$HTTP_BODY" != *FORCE_PASSWORD_CHANGE* ]]; then
        fail "admin login failed: neither the configured nor the default password works"
      fi
      ;;
    200)
      fail "the default admin password is active without a forced change; set the admin password manually first"
      ;;
    *)
      fail "login with the default admin password returned HTTP $HTTP_STATUS"
      ;;
  esac

  log "changing the default admin password"
  dtrack_form_request /api/v1/user/forceChangePassword \
    "username=$DTRACK_ADMIN_USERNAME" \
    "password=$DEFAULT_ADMIN_PASSWORD" \
    "newPassword=$ADMIN_PASSWORD" \
    "confirmPassword=$ADMIN_PASSWORD"
  [[ "$HTTP_STATUS" == 200 ]] || fail "changing the admin password returned HTTP $HTTP_STATUS (check the password policy)"

  admin_login "$ADMIN_PASSWORD"
  [[ "$HTTP_STATUS" == 200 ]] || fail "login after the password change returned HTTP $HTTP_STATUS"
}

open_admin_session() {
  if [[ -n "$DTRACK_ADMIN_API_KEY" ]]; then
    ADMIN_AUTH="X-Api-Key: $DTRACK_ADMIN_API_KEY"
    return
  fi

  resolve_admin_password
  admin_login "$ADMIN_PASSWORD"
  if [[ "$HTTP_STATUS" != 200 ]]; then
    take_over_default_admin
  fi
  use_login_token
}

# Sets TEAM_JSON and returns 0 when a team with exactly this name exists.
find_team() {
  local name=$1
  local page=1
  local count
  TEAM_JSON=""

  while ((page <= MAX_PAGES)); do
    dtrack_request "$ADMIN_AUTH" GET "/api/v1/team?pageNumber=$page&pageSize=$PAGE_SIZE"
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
  dtrack_request "$ADMIN_AUTH" PUT /api/v1/team "$payload"

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
    dtrack_request "$ADMIN_AUTH" POST "/api/v1/permission/$permission/team/$team_uuid"
    case "$HTTP_STATUS" in
      200 | 304) ;;
      *) fail "granting $permission returned HTTP $HTTP_STATUS" ;;
    esac
  done
}

# Returns 0 when the key works for this team. An unreachable validation
# endpoint is not treated as a revoked key.
stored_key_is_valid() {
  local api_key=$1
  dtrack_request "X-Api-Key: $api_key" GET /api/v1/team/self

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
  dtrack_request "$ADMIN_AUTH" DELETE "/api/v1/team/key/$identifier"
  if [[ "$HTTP_STATUS" != 204 && "$HTTP_STATUS" != 200 ]]; then
    log "warning: could not remove the unused API key (HTTP $HTTP_STATUS)"
  fi
}

create_key_and_store() {
  local team_uuid
  team_uuid=$(jq -r '.uuid' <<<"$TEAM_JSON")

  log "creating API key for '$TEAM_NAME'"
  dtrack_request "$ADMIN_AUTH" PUT "/api/v1/team/$team_uuid/key"
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
  open_admin_session
  ensure_team
  ensure_permissions

  local existing_key
  existing_key=$(read_secret_field "$SECRET_NAME" DTRACK_API_KEY)
  if [[ -n "$existing_key" ]] && stored_key_is_valid "$existing_key"; then
    log "secret $NAMESPACE/$SECRET_NAME already holds a working key, nothing to do"
    return
  fi

  create_key_and_store
}

main "$@"
