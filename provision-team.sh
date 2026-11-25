#!/usr/bin/env bash
# Idempotently provisions a Dependency-Track team plus API key and stores the
# key in a Kubernetes secret. Works on a fresh, never-used instance: it takes
# over the default admin account first.
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
#   ADMIN_WAIT_SECONDS       how long to wait for the default
#                            admin account to appear             (default: 60)
#   LOG_LEVEL                debug (default, very verbose) or info
#
# Logging never contains passwords, tokens or API keys. Every HTTP request and
# kubectl call is logged at debug level, including status codes and response
# bodies, except bodies that carry a token or key.
#
# The key secret holds DTRACK_URL and DTRACK_API_KEY, the variable names the
# dtrack-cve CLI reads. The pod's service account needs get/create/patch on
# secrets in NAMESPACE.

set -Eeuo pipefail

readonly SERVICE_ACCOUNT_NAMESPACE_FILE=/var/run/secrets/kubernetes.io/serviceaccount/namespace
readonly DEFAULT_ADMIN_PASSWORD=admin
readonly PAGE_SIZE=100
readonly MAX_PAGES=1000
readonly BODY_LOG_LIMIT=1000

HTTP_STATUS=""
HTTP_BODY=""
TEAM_JSON=""
WORK_DIR=""
ADMIN_AUTH=""
ADMIN_PASSWORD=""
ADMIN_PASSWORD_SOURCE=""
DEFAULT_ADMIN_STATE=""
REDACT_SUCCESS_BODY=0
DEADLINE=0
LOG_LEVEL="${LOG_LEVEL:-debug}"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

info() {
  log "INFO  $*"
}

debug() {
  if [[ "$LOG_LEVEL" == debug ]]; then
    log "DEBUG $*"
  fi
  return 0
}

warn() {
  log "WARN  $*"
}

fail() {
  log "ERROR $*"
  exit 1
}

report_unexpected_failure() {
  local exit_code=$?
  log "ERROR unexpected failure (exit $exit_code) at line $1 in ${FUNCNAME[1]:-main}"
}

cleanup() {
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

step() {
  info "== $* =="
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "required command not found: $1"
  fi
  debug "found command $1 at $(command -v "$1")"
}

is_valid_resource_name() {
  [[ "$1" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]
}

single_line() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | cut -c1-"$BODY_LOG_LIMIT"
}

load_settings() {
  if [[ "$LOG_LEVEL" != debug && "$LOG_LEVEL" != info ]]; then
    fail "LOG_LEVEL must be debug or info, got '$LOG_LEVEL'"
  fi

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
  ADMIN_WAIT_SECONDS="${ADMIN_WAIT_SECONDS:-60}"

  local default_secret_name
  default_secret_name=$(printf 'dtrack-%s-api-key' "$TEAM_NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')
  SECRET_NAME="${SECRET_NAME:-$default_secret_name}"
  is_valid_resource_name "$SECRET_NAME" || fail "invalid secret name: $SECRET_NAME"

  NAMESPACE="${NAMESPACE:-}"
  if [[ -z "$NAMESPACE" && -r "$SERVICE_ACCOUNT_NAMESPACE_FILE" ]]; then
    NAMESPACE=$(<"$SERVICE_ACCOUNT_NAMESPACE_FILE")
    debug "namespace taken from $SERVICE_ACCOUNT_NAMESPACE_FILE"
  fi
  [[ -n "$NAMESPACE" ]] || fail "NAMESPACE is not set and no service account namespace was found"

  if [[ -n "$DTRACK_ADMIN_API_KEY" ]]; then
    ADMIN_PASSWORD_SOURCE="api key override (no admin login)"
  elif [[ -n "$DTRACK_ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD_SOURCE="DTRACK_ADMIN_PASSWORD"
  else
    ADMIN_PASSWORD_SOURCE="secret $ADMIN_SECRET_NAME, generated on a fresh instance"
  fi
}

log_settings() {
  info "dtrack url:           $DTRACK_URL"
  info "admin user:           $DTRACK_ADMIN_USERNAME"
  info "admin credentials:    $ADMIN_PASSWORD_SOURCE"
  info "admin secret:         $NAMESPACE/$ADMIN_SECRET_NAME"
  info "team:                 $TEAM_NAME"
  info "team permissions:     $TEAM_PERMISSIONS"
  info "api key secret:       $NAMESPACE/$SECRET_NAME"
  info "wait timeout:         ${WAIT_TIMEOUT_SECONDS}s (admin account: ${ADMIN_WAIT_SECONDS}s)"
  info "log level:            $LOG_LEVEL"
}

log_environment() {
  debug "bash $BASH_VERSION"
  debug "$(curl --version | head -n1)"
  debug "$(jq --version)"
  debug "$(kubectl version --client 2>&1 | head -n1 || true)"
  debug "working as: $(id -un 2>/dev/null || echo unknown), host $(hostname 2>/dev/null || echo unknown)"
}

# Missing permissions are the most common reason for a failing init job, so
# they are reported up front. The result is only informational.
check_kubernetes_access() {
  local verb
  local answer
  for verb in get create patch; do
    answer=$(kubectl --namespace "$NAMESPACE" auth can-i "$verb" secrets 2>&1 || true)
    debug "kubectl auth can-i $verb secrets in $NAMESPACE: $(single_line "$answer")"
    if [[ "$answer" != yes ]]; then
      warn "the service account may not be allowed to $verb secrets in $NAMESPACE"
    fi
  done
}

kube() {
  debug "kubectl $*"
  kubectl "$@"
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

# Sets HTTP_STATUS and HTTP_BODY. A 2xx body is not logged when the caller set
# REDACT_SUCCESS_BODY=1 (tokens, API keys); error bodies are always logged.
send_request() {
  local method=$1
  local path=$2
  local config=$3
  local body=${4:-}
  local body_file="$WORK_DIR/response.body"
  local request_file="$WORK_DIR/request.body"
  local error_file="$WORK_DIR/curl.error"
  local redact=$REDACT_SUCCESS_BODY
  REDACT_SUCCESS_BODY=0

  local curl_arguments=(
    --silent --show-error --max-time 30
    --request "$method"
    --output "$body_file"
    --write-out '%{http_code}\t%{content_type}\t%{time_total}\t%{size_download}'
    --header 'Accept: */*'
    --config -
  )
  if [[ -n "$body" ]]; then
    printf '%s' "$body" >"$request_file"
    curl_arguments+=(--header 'Content-Type: application/json' --data-binary "@$request_file")
    debug "   request body: $(single_line "$body")"
  fi

  debug "-> $method $DTRACK_URL$path"
  local result
  if ! result=$(printf '%s\n' "$config" | curl "${curl_arguments[@]}" "$DTRACK_URL$path" 2>"$error_file"); then
    fail "request failed: $method $path: $(single_line "$(<"$error_file")")"
  fi

  local content_type time_total size
  IFS=$'\t' read -r HTTP_STATUS content_type time_total size <<<"$result"
  HTTP_BODY=$(<"$body_file")

  debug "<- HTTP $HTTP_STATUS, content-type '${content_type:-none}', $size bytes in ${time_total}s"
  if [[ "$redact" == 1 && "$HTTP_STATUS" == 2* ]]; then
    debug "   response body hidden (contains a credential)"
  else
    debug "   response body: $(single_line "$HTTP_BODY")"
  fi
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
    debug "   authentication: ${auth%%:*} header (value hidden)"
  else
    debug "   authentication: none"
  fi
  send_request "$method" "$path" "$config" "$body"
}

# POSTs url-encoded fields (name=value) without authentication. Only the field
# names are logged.
dtrack_form_request() {
  local path=$1
  shift
  local config=""
  local field
  local names=()
  for field in "$@"; do
    config+="data-urlencode = \"$(curl_config_escape "$field")\""$'\n'
    names+=("${field%%=*}")
  done
  debug "   form fields: ${names[*]} (values hidden)"
  send_request POST "$path" "$config"
}

wait_for_api() {
  DEADLINE=$((SECONDS + WAIT_TIMEOUT_SECONDS))
  info "waiting for Dependency-Track at $DTRACK_URL (up to ${WAIT_TIMEOUT_SECONDS}s)"
  local attempt=1
  local status
  local last_problem="no attempt made"
  while :; do
    if status=$(curl --silent --show-error --max-time 10 --output "$WORK_DIR/version.body" \
      --write-out '%{http_code}' "$DTRACK_URL/api/version" 2>"$WORK_DIR/curl.error"); then
      debug "attempt $attempt: GET /api/version -> HTTP $status"
      if [[ "$status" == 200 ]]; then
        info "Dependency-Track is up: $(single_line "$(<"$WORK_DIR/version.body")")"
        return
      fi
      last_problem="HTTP $status: $(single_line "$(<"$WORK_DIR/version.body")")"
    else
      last_problem="curl failed: $(single_line "$(<"$WORK_DIR/curl.error")")"
      debug "attempt $attempt: $last_problem"
    fi

    if ((SECONDS >= DEADLINE)); then
      fail "Dependency-Track did not become ready within ${WAIT_TIMEOUT_SECONDS}s, last problem: $last_problem"
    fi
    attempt=$((attempt + 1))
    sleep 5
  done
}

read_secret_field() {
  local name=$1
  local field=$2
  local value
  debug "reading field $field of secret $NAMESPACE/$name"
  value=$(kube --namespace "$NAMESPACE" get secret "$name" --ignore-not-found \
    --output "jsonpath={.data.$field}" | base64 -d)
  if [[ -n "$value" ]]; then
    debug "secret $NAMESPACE/$name has $field (${#value} characters)"
  else
    debug "secret $NAMESPACE/$name has no $field"
  fi
  printf '%s' "$value"
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
    }' | kube create --filename - >/dev/null
}

# Leaves HTTP_STATUS and HTTP_BODY (the JWT on success) of the last attempt.
admin_login() {
  local password=$1
  while :; do
    REDACT_SUCCESS_BODY=1
    dtrack_form_request /api/v1/user/login "username=$DTRACK_ADMIN_USERNAME" "password=$password"
    if ((10#$HTTP_STATUS < 500)); then
      return
    fi
    if ((SECONDS >= DEADLINE)); then
      fail "login kept failing with HTTP $HTTP_STATUS: $(single_line "$HTTP_BODY")"
    fi
    warn "login returned HTTP $HTTP_STATUS, retrying in 5s"
    sleep 5
  done
}

# Sets DEFAULT_ADMIN_STATE by trying the default password:
#   force_change  401 FORCE_PASSWORD_CHANGE, the expected state of a fresh install
#   open          200, default password works without a forced change
#   rejected      401 INVALID_CREDENTIALS, the account has another password
#   unexpected    anything else
# INVALID_CREDENTIALS is retried for ADMIN_WAIT_SECONDS, because a fresh
# instance may not have created the admin account yet.
classify_default_admin() {
  if [[ -n "$DEFAULT_ADMIN_STATE" ]]; then
    debug "default admin state already known: $DEFAULT_ADMIN_STATE"
    return
  fi

  info "probing the default admin login to find out whether this instance is fresh"
  local admin_deadline=$((SECONDS + ADMIN_WAIT_SECONDS))
  local attempt=1
  while :; do
    admin_login "$DEFAULT_ADMIN_PASSWORD"
    debug "default admin probe $attempt: HTTP $HTTP_STATUS, body '$(single_line "$HTTP_BODY")'"

    case "$HTTP_STATUS" in
      200)
        DEFAULT_ADMIN_STATE=open
        warn "the default admin password works without a forced change"
        return
        ;;
      401)
        if [[ "$HTTP_BODY" == *FORCE_PASSWORD_CHANGE* ]]; then
          DEFAULT_ADMIN_STATE=force_change
          info "default admin demands a password change: fresh instance"
          return
        fi
        if ((SECONDS >= admin_deadline)); then
          DEFAULT_ADMIN_STATE=rejected
          info "default admin password is rejected (body '$(single_line "$HTTP_BODY")')"
          return
        fi
        info "default admin password rejected, the account may not exist yet; retrying in 5s"
        ;;
      *)
        DEFAULT_ADMIN_STATE=unexpected
        warn "unexpected answer to the default admin login: HTTP $HTTP_STATUS, body '$(single_line "$HTTP_BODY")'"
        return
        ;;
    esac
    attempt=$((attempt + 1))
    sleep 5
  done
}

describe_admin_state_failure() {
  case "$DEFAULT_ADMIN_STATE" in
    rejected)
      printf 'the default admin password is rejected (HTTP %s, %s), so this instance was already set up' \
        "$HTTP_STATUS" "$(single_line "$HTTP_BODY")"
      ;;
    *)
      printf 'unexpected answer to the default admin login: HTTP %s, %s' \
        "$HTTP_STATUS" "$(single_line "$HTTP_BODY")"
      ;;
  esac
}

# The generated password is stored before Dependency-Track is changed, so a
# crash in between never leaves an admin account nobody knows the password of.
resolve_admin_password() {
  if [[ -n "$DTRACK_ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD="$DTRACK_ADMIN_PASSWORD"
    info "using the admin password from DTRACK_ADMIN_PASSWORD"
    return
  fi

  ADMIN_PASSWORD=$(read_secret_field "$ADMIN_SECRET_NAME" password)
  if [[ -n "$ADMIN_PASSWORD" ]]; then
    info "using the admin password stored in secret $NAMESPACE/$ADMIN_SECRET_NAME"
    return
  fi

  info "no admin password configured or stored"
  classify_default_admin
  if [[ "$DEFAULT_ADMIN_STATE" != force_change && "$DEFAULT_ADMIN_STATE" != open ]]; then
    fail "Dependency-Track is not in a fresh state and no admin credentials were given: $(describe_admin_state_failure). Set DTRACK_ADMIN_PASSWORD or DTRACK_ADMIN_API_KEY"
  fi

  info "fresh instance: generating an admin password and storing it in secret $NAMESPACE/$ADMIN_SECRET_NAME"
  local generated
  generated=$(generate_password)
  [[ ${#generated} -eq 32 ]] || fail "could not generate a password"

  if create_admin_secret "$generated"; then
    ADMIN_PASSWORD="$generated"
    info "stored the generated admin password"
    return
  fi

  warn "creating the admin secret failed, checking whether another run created it"
  ADMIN_PASSWORD=$(read_secret_field "$ADMIN_SECRET_NAME" password)
  [[ -n "$ADMIN_PASSWORD" ]] || fail "could not create secret $NAMESPACE/$ADMIN_SECRET_NAME"
}

take_over_default_admin() {
  classify_default_admin
  if [[ "$DEFAULT_ADMIN_STATE" != force_change && "$DEFAULT_ADMIN_STATE" != open ]]; then
    fail "admin login failed: the configured password is rejected and $(describe_admin_state_failure)"
  fi

  info "changing the default admin password"
  dtrack_form_request /api/v1/user/forceChangePassword \
    "username=$DTRACK_ADMIN_USERNAME" \
    "password=$DEFAULT_ADMIN_PASSWORD" \
    "newPassword=$ADMIN_PASSWORD" \
    "confirmPassword=$ADMIN_PASSWORD"
  if [[ "$HTTP_STATUS" != 200 ]]; then
    fail "changing the admin password returned HTTP $HTTP_STATUS: $(single_line "$HTTP_BODY") (check the password policy)"
  fi
  info "admin password changed"

  admin_login "$ADMIN_PASSWORD"
  if [[ "$HTTP_STATUS" != 200 ]]; then
    fail "login after the password change returned HTTP $HTTP_STATUS: $(single_line "$HTTP_BODY")"
  fi
}

open_admin_session() {
  if [[ -n "$DTRACK_ADMIN_API_KEY" ]]; then
    ADMIN_AUTH="X-Api-Key: $DTRACK_ADMIN_API_KEY"
    info "using the admin API key from DTRACK_ADMIN_API_KEY"
    return
  fi

  resolve_admin_password
  info "logging in as '$DTRACK_ADMIN_USERNAME'"
  admin_login "$ADMIN_PASSWORD"
  if [[ "$HTTP_STATUS" != 200 ]]; then
    info "login with the admin password was rejected (HTTP $HTTP_STATUS, '$(single_line "$HTTP_BODY")')"
    take_over_default_admin
  fi

  [[ -n "$HTTP_BODY" ]] || fail "login returned an empty token"
  ADMIN_AUTH="Authorization: Bearer $HTTP_BODY"
  info "logged in as '$DTRACK_ADMIN_USERNAME'"
}

# Sets TEAM_JSON and returns 0 when a team with exactly this name exists.
find_team() {
  local name=$1
  local page=1
  local count
  TEAM_JSON=""

  while ((page <= MAX_PAGES)); do
    debug "listing teams, page $page"
    dtrack_request "$ADMIN_AUTH" GET "/api/v1/team?pageNumber=$page&pageSize=$PAGE_SIZE"
    [[ "$HTTP_STATUS" == 200 ]] || fail "listing teams returned HTTP $HTTP_STATUS: $(single_line "$HTTP_BODY")"

    count=$(jq 'length' <<<"$HTTP_BODY")
    debug "page $page holds $count teams: $(jq -r '[.[].name] | join(", ")' <<<"$HTTP_BODY")"

    TEAM_JSON=$(jq -c --arg name "$name" 'first(.[] | select(.name == $name)) // empty' <<<"$HTTP_BODY")
    if [[ -n "$TEAM_JSON" ]]; then
      return 0
    fi

    if ((count != PAGE_SIZE)); then
      return 1
    fi
    page=$((page + 1))
  done
  fail "more than $MAX_PAGES pages of teams"
}

ensure_team() {
  if find_team "$TEAM_NAME"; then
    info "team '$TEAM_NAME' already exists (uuid $(jq -r '.uuid' <<<"$TEAM_JSON"))"
    return
  fi

  info "creating team '$TEAM_NAME'"
  local payload
  payload=$(jq -nc --arg name "$TEAM_NAME" '{name: $name}')
  dtrack_request "$ADMIN_AUTH" PUT /api/v1/team "$payload"

  case "$HTTP_STATUS" in
    200 | 201)
      TEAM_JSON="$HTTP_BODY"
      info "created team '$TEAM_NAME' (uuid $(jq -r '.uuid' <<<"$TEAM_JSON"))"
      ;;
    409)
      info "team '$TEAM_NAME' was created in the meantime, looking it up"
      find_team "$TEAM_NAME" || fail "team '$TEAM_NAME' reported as existing but not found"
      ;;
    *)
      fail "creating team returned HTTP $HTTP_STATUS: $(single_line "$HTTP_BODY")"
      ;;
  esac
}

ensure_permissions() {
  local team_uuid
  team_uuid=$(jq -r '.uuid' <<<"$TEAM_JSON")
  [[ -n "$team_uuid" && "$team_uuid" != null ]] || fail "team response has no uuid"
  debug "permissions of the team right now: $(jq -r '[.permissions[]?.name] | join(", ")' <<<"$TEAM_JSON")"

  local permission
  local permissions
  IFS=',' read -r -a permissions <<<"$TEAM_PERMISSIONS"
  for permission in "${permissions[@]}"; do
    permission="${permission//[[:space:]]/}"
    [[ -n "$permission" ]] || continue
    [[ "$permission" =~ ^[A-Z_]+$ ]] || fail "invalid permission name: $permission"

    if jq -e --arg permission "$permission" '[.permissions[]?.name] | index($permission) != null' <<<"$TEAM_JSON" >/dev/null; then
      debug "team already has $permission"
      continue
    fi

    info "granting $permission to '$TEAM_NAME'"
    dtrack_request "$ADMIN_AUTH" POST "/api/v1/permission/$permission/team/$team_uuid"
    case "$HTTP_STATUS" in
      200 | 304) ;;
      *) fail "granting $permission returned HTTP $HTTP_STATUS: $(single_line "$HTTP_BODY")" ;;
    esac
  done
}

# Returns 0 when the key works for this team. An unreachable validation
# endpoint is not treated as a revoked key.
stored_key_is_valid() {
  local api_key=$1
  debug "checking whether the stored API key still works"
  dtrack_request "X-Api-Key: $api_key" GET /api/v1/team/self

  case "$HTTP_STATUS" in
    200)
      local owner
      owner=$(jq -r '.name // empty' <<<"$HTTP_BODY")
      if [[ "$owner" != "$TEAM_NAME" ]]; then
        info "stored key belongs to team '$owner', not '$TEAM_NAME'"
        return 1
      fi
      debug "stored key belongs to team '$owner'"
      return 0
      ;;
    401 | 403)
      info "stored key was rejected by Dependency-Track"
      return 1
      ;;
    404)
      warn "/api/v1/team/self is not available, trusting the stored key"
      return 0
      ;;
    *)
      fail "validating the stored key returned HTTP $HTTP_STATUS: $(single_line "$HTTP_BODY")"
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
    }' | kube apply --filename - >/dev/null
}

revoke_key() {
  local identifier=$1
  info "removing the unused API key again"
  dtrack_request "$ADMIN_AUTH" DELETE "/api/v1/team/key/$identifier"
  if [[ "$HTTP_STATUS" != 204 && "$HTTP_STATUS" != 200 ]]; then
    warn "could not remove the unused API key (HTTP $HTTP_STATUS)"
  fi
}

create_key_and_store() {
  local team_uuid
  team_uuid=$(jq -r '.uuid' <<<"$TEAM_JSON")

  info "creating an API key for '$TEAM_NAME'"
  REDACT_SUCCESS_BODY=1
  dtrack_request "$ADMIN_AUTH" PUT "/api/v1/team/$team_uuid/key"
  case "$HTTP_STATUS" in
    200 | 201) ;;
    *) fail "creating API key returned HTTP $HTTP_STATUS: $(single_line "$HTTP_BODY")" ;;
  esac

  local api_key
  local identifier
  api_key=$(jq -r '.key // empty' <<<"$HTTP_BODY")
  identifier=$(jq -r '.publicId // .key // empty' <<<"$HTTP_BODY")
  debug "key response fields: $(jq -r 'keys | join(", ")' <<<"$HTTP_BODY"), public id '$(jq -r '.publicId // "none"' <<<"$HTTP_BODY")'"
  [[ -n "$api_key" ]] || fail "API key response contains no 'key' field"

  if ! write_secret "$api_key"; then
    revoke_key "$identifier"
    fail "could not write secret $NAMESPACE/$SECRET_NAME"
  fi
  info "stored the API key in secret $NAMESPACE/$SECRET_NAME"
}

main() {
  trap 'report_unexpected_failure $LINENO' ERR
  trap cleanup EXIT

  step "preparing"
  require_command curl
  require_command jq
  require_command kubectl
  require_command base64
  WORK_DIR=$(mktemp -d)
  debug "work directory $WORK_DIR"
  load_settings
  log_settings
  log_environment
  check_kubernetes_access

  step "1/5 waiting for the API"
  wait_for_api

  step "2/5 admin session"
  open_admin_session

  step "3/5 team"
  ensure_team

  step "4/5 permissions"
  ensure_permissions

  step "5/5 API key"
  local existing_key
  existing_key=$(read_secret_field "$SECRET_NAME" DTRACK_API_KEY)
  if [[ -n "$existing_key" ]] && stored_key_is_valid "$existing_key"; then
    info "secret $NAMESPACE/$SECRET_NAME already holds a working key, nothing to do"
    return
  fi

  create_key_and_store
  info "done"
}

main "$@"
