#!/usr/bin/env bash
#
# concert_mongodb_setup.sh
#
# Loads the MongoDB sovereign-compliance content into IBM Concert, end to end:
#   1. Catalog                   (MongoDB Catalog)
#   2. Catalog mapping           (MongoDB -> ISCF control mapping)
#   3. Software component file   (compliance_component_definition)
#   4. Validation component file (compliance_component_definition)
#   5. Compliance profile        (linked to an application release)
# and then checks that everything is present in Concert.
#
# Requirements: bash, curl, jq, python3
#
# Authentication is by Concert API key. Username/password login is no longer
# supported by Concert (the login endpoint returns HTTP 410), so the script ASKS
# for an API key when it runs (input is hidden). Create one in the Concert UI.
# To run without a prompt: export CONCERT_API_KEY=<key>
# Nothing is stored in the script.
# The Concert URL is taken from the standard OpenShift route
# (oc get route concert -n concert), so run it where you are logged in with `oc`.
# If oc is not available, export CONCERT_URL or the script will ask for it.
#
# Optional environment variables (defaults in brackets):
#   CONCERT_INSTANCE_ID  [0000-0000-0000-0000]
#   FILES_DIR            folder holding the four JSON files [folder of this script]
#   CATALOG_FILE         [mongodb-catalog.json]
#   MAPPING_FILE         [mongodb-iscf-mapping.json]
#   SOFTWARE_FILE        [component-software-mongodb.json]
#   VALIDATION_FILE      [component-validation-mongodb.json]
#   CATALOG_NAME         [MongoDB Catalog]  must match the title inside the catalog file
#   APP_PREFIX           [production_]  the profile is linked to the application whose name starts
#                                       with this (created when the cluster is imported)
#   PROFILE_TITLE        [MongoDB Sovereign Profile]  letters, digits, space - _ . only, max 128
#   PROFILE_DESCRIPTION  [MongoDB sovereign compliance profile]
#   PROFILE_VERSION      [1.0.0]
#   UPLOAD_RETRIES       [6]   attempts per component upload
#   UPLOAD_WAIT          [10]  seconds between attempts
#
# Usage:
#   ./concert_mongodb_setup.sh
#
# Safe to re-run: an existing catalog, mapping or profile is detected and skipped.

set -uo pipefail

# ---------- settings ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IID="${CONCERT_INSTANCE_ID:-0000-0000-0000-0000}"
FILES_DIR="${FILES_DIR:-$SCRIPT_DIR}"
CATALOG_FILE="${CATALOG_FILE:-mongodb-catalog.json}"
MAPPING_FILE="${MAPPING_FILE:-mongodb-iscf-mapping.json}"
SOFTWARE_FILE="${SOFTWARE_FILE:-component-software-mongodb.json}"
VALIDATION_FILE="${VALIDATION_FILE:-component-validation-mongodb.json}"
CATALOG_NAME="${CATALOG_NAME:-MongoDB Catalog}"
APP_PREFIX="${APP_PREFIX:-production_}"
PROFILE_TITLE="${PROFILE_TITLE:-MongoDB Sovereign Profile}"
PROFILE_DESCRIPTION="${PROFILE_DESCRIPTION:-MongoDB sovereign compliance profile}"
PROFILE_VERSION="${PROFILE_VERSION:-1.0.0}"
UPLOAD_RETRIES="${UPLOAD_RETRIES:-6}"
UPLOAD_WAIT="${UPLOAD_WAIT:-10}"

log()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    [ok]   %s\n' "$*"; }
skip() { printf '    [skip] %s\n' "$*"; }
die()  { printf '\n[FAILED] %s\n' "$*" >&2; exit 1; }

# ---------- pre-checks ----------
for tool in curl jq python3; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but not installed"
done

for f in "$CATALOG_FILE" "$MAPPING_FILE" "$SOFTWARE_FILE" "$VALIDATION_FILE"; do
  [ -f "$FILES_DIR/$f" ] || die "file not found: $FILES_DIR/$f"
  jq -e . "$FILES_DIR/$f" >/dev/null 2>&1 || die "not valid JSON: $FILES_DIR/$f"
done

if ! printf '%s' "$PROFILE_TITLE" | grep -Eq '^[a-zA-Z0-9 _.-]+$' \
   || ! printf '%s' "$PROFILE_DESCRIPTION" | grep -Eq '^[a-zA-Z0-9 _.-]+$' \
   || [ "${#PROFILE_TITLE}" -gt 128 ] || [ "${#PROFILE_DESCRIPTION}" -gt 128 ]; then
  die "profile title/description: only letters, digits, space, - _ . allowed, max 128 chars"
fi

# ---------- Concert URL (standard route: "concert" in namespace "concert") ----------
H="${CONCERT_URL:-}"
if [ -z "$H" ] && command -v oc >/dev/null 2>&1; then
  ROUTE_HOST=$(oc get route concert -n concert -o jsonpath='{.spec.host}' 2>/dev/null)
  [ -n "$ROUTE_HOST" ] && H="https://$ROUTE_HOST"
fi
if [ -z "$H" ]; then
  read -r -p "Concert URL (e.g. https://concert-concert.apps.<cluster>.<domain>): " H
fi
H="${H%/}"
[ -n "$H" ] || die "Concert URL is required"

# ---------- ask for the API key ----------
if [ -z "${CONCERT_API_KEY:-}" ]; then
  read -r -s -p "Concert API key: " CONCERT_API_KEY; echo
fi
[ -n "$CONCERT_API_KEY" ] || die "an API key is required (create one in the Concert UI)"

cd "$FILES_DIR" || die "cannot cd to $FILES_DIR"

# ---------- helpers ----------
fetch_catalogs() {   # prints the catalog list as a JSON array
  curl -sk "$H/concert/compliance/api/v1/fetch_all_catalogs" "${AUTH[@]}" \
    | jq -c 'if type=="array" then . else (.data // []) end' 2>/dev/null
}

catalog_field() {    # $1 = jq expression applied to the matching catalog
  fetch_catalogs | jq -r --arg t "$CATALOG_NAME" \
    "[.[] | select(.title==\$t)][0] | $1 // empty" 2>/dev/null
}

http_call() {        # runs curl, sets HTTP_CODE and BODY
  local out
  out=$(curl -sk -w '\n%{http_code}' "$@") || { HTTP_CODE=000; BODY="curl failed"; return; }
  HTTP_CODE=$(printf '%s' "$out" | tail -n1)
  BODY=$(printf '%s' "$out" | sed '$d')
}

is_2xx() { [[ "$1" =~ ^2[0-9][0-9]$ ]]; }

mapping_present() {
  curl -sk "$H/concert/compliance/api/v1/fetch_all_mapped_catalogs" "${AUTH[@]}" | grep -qF "$CATALOG_NAME"
}

find_profile_uuid() {
  curl -sk -G "$H/concert/compliance/api/v1/profiles" "${AUTH[@]}" \
    --data-urlencode "fetch_all=true" --data-urlencode "search=$PROFILE_TITLE" \
    | jq -r --arg t "$PROFILE_TITLE" \
        '[.. | objects | select(.title? == $t and has("uuid"))][0].uuid // empty' 2>/dev/null
}

# ---------- 0. authenticate ----------
KEY="$CONCERT_API_KEY"
unset CONCERT_API_KEY
AUTH=(-H "Authorization: C_API_KEY $KEY" -H "InstanceId: $IID")
log "Checking the API key against $H"
KEY_CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
  "$H/concert/compliance/api/v1/catalogs?page_number=1&page_size=1" "${AUTH[@]}")
[ "$KEY_CODE" = "200" ] || die "API key rejected (HTTP $KEY_CODE) - check the key and the URL"
ok "API key accepted"

# ---------- 1. catalog ----------
log "1/5 Catalog: $CATALOG_NAME"
CID=$(catalog_field '.uuid')
if [ -n "$CID" ]; then
  skip "catalog already exists (uuid $CID)"
else
  http_call -X POST "$H/concert/compliance/api/v1/catalogs" "${AUTH[@]}" \
    -H 'Content-Type: application/json' -d @"$CATALOG_FILE"
  is_2xx "$HTTP_CODE" || die "catalog upload failed (HTTP $HTTP_CODE): $BODY"
  CID=$(catalog_field '.uuid')
  [ -n "$CID" ] || die "catalog uploaded but '$CATALOG_NAME' not found afterwards - does CATALOG_NAME match the title in $CATALOG_FILE?"
  ok "catalog created (uuid $CID)"
fi
ok "catalog has $(catalog_field '.controls | length') controls"

# ---------- 2. mapping ----------
log "2/5 Catalog mapping: $MAPPING_FILE"
if mapping_present; then
  skip "a mapping for '$CATALOG_NAME' already exists"
else
  http_call -X POST "$H/concert/ingestion/api/v1/upload_files" "${AUTH[@]}" \
    -F data_type=compliance_catalog_mapping -F "filename=@$MAPPING_FILE"
  is_2xx "$HTTP_CODE" || die "mapping upload failed (HTTP $HTTP_CODE): $BODY"
  ok "mapping uploaded (HTTP $HTTP_CODE)"
fi

# ---------- 3 + 4. component definitions (software first, then validation) ----------
META=$(jq -nc --arg n "$CATALOG_NAME" --arg id "$CID" '{catalog_name:$n,catalog_id:$id}')

upload_component() {   # $1 = file, $2 = label
  local attempt=1
  while :; do
    http_call -X POST "$H/concert/ingestion/api/v1/upload_files" "${AUTH[@]}" \
      -F data_type=compliance_component_definition -F "metadata=$META" -F "filename=@$1"
    if is_2xx "$HTTP_CODE" && ! printf '%s' "$BODY" | grep -q 'ERR_'; then
      ok "$2 uploaded (HTTP $HTTP_CODE)"
      return 0
    fi
    [ "$attempt" -lt "$UPLOAD_RETRIES" ] \
      || die "$2 upload failed after $attempt attempts (HTTP $HTTP_CODE): $BODY"
    printf '    [retry] %s not accepted (HTTP %s) - waiting %ss (%s/%s)\n' \
      "$2" "$HTTP_CODE" "$UPLOAD_WAIT" "$attempt" "$UPLOAD_RETRIES"
    sleep "$UPLOAD_WAIT"
    attempt=$((attempt + 1))
  done
}

log "3/5 Software component definition: $SOFTWARE_FILE"
upload_component "$SOFTWARE_FILE" "software component"

log "4/5 Validation component definition: $VALIDATION_FILE"
# The validation file refers to the software component, so it must be uploaded second.
upload_component "$VALIDATION_FILE" "validation component"

# ---------- 5. profile ----------
log "5/5 Profile: $PROFILE_TITLE"
PID=$(find_profile_uuid)
if [ -n "$PID" ]; then
  skip "profile already exists (uuid $PID)"
else
  # Importing a cluster creates an application named "<APP_PREFIX>..." (default "production_...").
  APPS=$(curl -sk "$H/concert/core/api/v2/applications" "${AUTH[@]}" \
    | jq -r --arg p "$APP_PREFIX" '
        [.. | objects | select((.name? | type) == "string" and (.name | startswith($p)) and has("id"))]
        | unique_by(.id) | .[] | "\(.id)\t\(.name)"' 2>/dev/null)
  NAPPS=$(printf '%s\n' "$APPS" | grep -c .)
  [ "$NAPPS" -gt 0 ] || die "no application named '${APP_PREFIX}*' found in Concert - import the cluster first, or set APP_PREFIX"

  if [ "$NAPPS" -eq 1 ]; then
    APP=$(printf '%s' "$APPS" | cut -f1); APP_NAME=$(printf '%s' "$APPS" | cut -f2)
  else
    echo "    Several applications match '${APP_PREFIX}*':"
    printf '%s\n' "$APPS" | awk -F'\t' '{printf "      %d) %s\n", NR, $2}'
    read -r -p "    Pick the application to link the profile to [1-$NAPPS]: " CHOICE
    [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "$NAPPS" ] || die "invalid choice '$CHOICE'"
    LINE=$(printf '%s\n' "$APPS" | sed -n "${CHOICE}p")
    APP=$(printf '%s' "$LINE" | cut -f1); APP_NAME=$(printf '%s' "$LINE" | cut -f2)
  fi
  ok "using application '$APP_NAME' ($APP)"

  REL=$(curl -sk "$H/concert/core/api/v2/applications/$APP/versions" "${AUTH[@]}" \
    | jq -r '[.. | objects | (.application_release_id // .id)? | select(type=="string")][0] // empty' 2>/dev/null)
  [ -n "$REL" ] || die "no release/version found for application '$APP_NAME'"

  CTRLS=$(catalog_field '[.controls[].uuid]')
  [ -n "$CTRLS" ] && [ "$(printf '%s' "$CTRLS" | jq 'length')" -gt 0 ] \
    || die "catalog '$CATALOG_NAME' has no controls to put in the profile"

  PID=$(python3 -c 'import uuid;print(uuid.uuid4())')
  PROFILE_JSON=$(jq -nc --arg id "$PID" --arg cid "$CID" --arg rel "$REL" \
      --arg t "$PROFILE_TITLE" --arg d "$PROFILE_DESCRIPTION" --arg v "$PROFILE_VERSION" \
      --argjson c "$CTRLS" '{
        uuid:$id, title:$t, description:$d, version:$v, allow_manual_assessment:true,
        controls:[{catalog_id:$cid, control_ids:$c}],
        application_releases_ids:[$rel]}')
  http_call -X POST "$H/concert/compliance/api/v1/profiles" "${AUTH[@]}" \
    -H 'Content-Type: application/json' -d "$PROFILE_JSON"
  is_2xx "$HTTP_CODE" || die "profile creation failed (HTTP $HTTP_CODE): $BODY"
  ok "profile created (uuid $PID), linked to application '$APP_NAME'"
fi

# ---------- verification ----------
log "Verifying what is now in Concert"
FAIL=0
present() { printf '    [ok]      %s\n' "$1"; }
missing() { printf '    [MISSING] %s\n' "$1"; FAIL=1; }

if [ -n "$(catalog_field '.uuid')" ]; then present "catalog '$CATALOG_NAME'"; else missing "catalog '$CATALOG_NAME'"; fi
if mapping_present; then present "catalog mapping"; else missing "catalog mapping"; fi
if [ -n "$(find_profile_uuid)" ]; then present "profile '$PROFILE_TITLE'"; else missing "profile '$PROFILE_TITLE'"; fi
present "software and validation components (accepted by the upload API)"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "Done. Catalog, mapping, both component definitions and the profile are in Concert."
  echo "Check them in the UI: $H  ->  Compliance"
else
  die "some items are missing - see above"
fi
