#!/usr/bin/env bash
# =============================================================================
# setup-elementor-mcp.sh — Wire up the Elementor MCP server against a
# WordPress site (Local-by-Flywheel or live host) and write a .mcp.json
# in the current directory so Claude Code can drive Elementor.
#
# Usage:  bash "<skill-dir>/setup-elementor-mcp.sh"
#         (where <skill-dir> is the skill's announced base directory)
#         Fallback for manual installs: bash ~/.claude/scripts/setup-elementor-mcp.sh
#
# What it does:
#   1. Asks Local vs live host
#   2. Validates connectivity + REST auth
#   3. Confirms Elementor + Hello Elementor are installed (warns if not)
#   4. Downloads + installs the elementor-mcp fork (bundles the MCP Adapter)
#      (handles the GitHub-only zip, repacks the source zipball)
#   5. Verifies the /mcp/elementor-mcp-server route appears
#   6. Writes .mcp.json in the current directory
#
# Idempotent: safe to re-run.
# =============================================================================

set -uo pipefail

# ---- pretty-print helpers ----------------------------------------------------
BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
RED=$'\033[31m'; CYAN=$'\033[36m'; RESET=$'\033[0m'

step()  { printf "\n${BOLD}${CYAN}▸ %s${RESET}\n" "$*"; }
ok()    { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn()  { printf "  ${YELLOW}⚠${RESET} %s\n" "$*"; }
fail()  { printf "  ${RED}✗${RESET} %s\n" "$*"; }
info()  { printf "  ${DIM}%s${RESET}\n" "$*"; }
ask()   { printf "${BOLD}? %s${RESET} " "$*"; }

abort() { fail "$1"; exit 1; }

# ---- pure helpers (arg/stdin based; unit-tested via --self-test-fn) ----------
# Same convention as new-client.sh, deliberately inline so this stays one
# droppable file.

# arg1: site URL -> host, lowercased, port and path stripped
url_host(){ printf '%s' "${1:-}" | sed -E 's#^https?://##; s#[:/].*$##' | tr '[:upper:]' '[:lower:]'; }

# arg1: host -> "yes" when it is a local dev host (no wire to sniff)
is_local_host(){
  case "${1:-}" in
    localhost|127.0.0.1|0.0.0.0|::1|*.local|*.test|*.localhost) printf 'yes' ;;
    *) printf 'no' ;;
  esac
}

# arg1: site URL; env WP_ALLOW_HTTP (comma-separated hosts) ->
#   "ok"       https, nothing to decide
#   "local"    plaintext to a local dev host
#   "named"    plaintext to a host the caller named
#   "refused"  plaintext to anything else
# A live run sends a reusable application password on every request, so this is
# the same rule as wordpress-api-pro's WP_ALLOW_HTTP: name the host or use
# https. A blanket value cannot work here - "1" is simply not a hostname.
http_verdict(){
  url="${1:-}"
  case "$url" in http://*) ;; *) printf 'ok'; return ;; esac
  host=$(url_host "$url")
  [ "$(is_local_host "$host")" = "yes" ] && { printf 'local'; return; }
  allowed=",$(printf '%s' "${WP_ALLOW_HTTP:-}" | tr -d ' ' | tr '[:upper:]' '[:lower:]'),"
  case "$allowed" in *",$host,"*) printf 'named' ;; *) printf 'refused' ;; esac
}

# stdin -> same JSON with the Basic credential replaced by a placeholder
redact_basic_auth(){ sed -E 's#("Authorization": "Basic )[^"]*#\1<base64 of WP_USERNAME:WP_APP_PASSWORD>#'; }

# arg1: file -> sha256 hex, using whatever the machine has
sha256_of(){
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
  fi
}

# Hidden test hook: `setup-elementor-mcp.sh --self-test-fn <fn> [args...]` runs
# one helper and exits. Never touches the network, never prompts.
if [ "${1:-}" = "--self-test-fn" ]; then shift; fn="$1"; shift || true; "$fn" "$@"; exit $?; fi

# ---- prereq check ------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || abort "Missing required command: $1"; }
need curl
need python3
need unzip
need zip

# Lenient JSON parser. Some WP plugins (Fluent Forms, etc.) emit malformed JSON
# in /wp-json/ index — bad backslash escapes like \s inside string values.
# This helper falls back to escaping those before parsing, then reads dotted
# paths from the result. Usage: cmd | jq_lenient '.namespaces' OR
#   cmd | jq_lenient_test '.namespaces' 'mcp'   (prints "yes" if value present)

JQ_LENIENT_PY='
import sys, json, re
def _sanitize(s):
    valid = set("\"\\/bfnrtu")
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i+1 < len(s) and s[i+1] not in valid:
            out.append("\\\\")
        else:
            out.append(c)
        i += 1
    return "".join(out)
def _load(s):
    try: return json.loads(s)
    except json.JSONDecodeError: return json.loads(_sanitize(s))
'

# Read pretty/raw value at a dotted path from stdin JSON.
# Supports: .key, .key.subkey, .[0], .key.[0]
jq_lenient() {
  python3 -c "$JQ_LENIENT_PY"'
import sys, json
data = _load(sys.stdin.read())
path = sys.argv[1].lstrip(".").split(".") if sys.argv[1] != "." else []
cur = data
for p in path:
    if p == "": continue
    if p.startswith("[") and p.endswith("]"):
        cur = cur[int(p[1:-1])]
    else:
        cur = cur.get(p) if isinstance(cur, dict) else None
    if cur is None: break
if isinstance(cur, (dict, list)):
    print(json.dumps(cur))
else:
    print("" if cur is None else cur)
' "$1"
}

# Test if a string value appears in a list field at a dotted path.
# Returns "yes"/"no" on stdout.
jq_lenient_contains() {
  python3 -c "$JQ_LENIENT_PY"'
import sys
data = _load(sys.stdin.read())
path = sys.argv[1].lstrip(".").split(".")
needle = sys.argv[2]
cur = data
for p in path:
    if p == "": continue
    cur = cur.get(p) if isinstance(cur, dict) else None
    if cur is None: break
if isinstance(cur, list):
    print("yes" if any(needle in str(x) for x in cur) else "no")
elif isinstance(cur, dict):
    print("yes" if any(needle in str(k) for k in cur.keys()) else "no")
else:
    print("no")
' "$1" "$2"
}

# ---- intro -------------------------------------------------------------------
clear 2>/dev/null || true
cat <<'BANNER'

  ╭───────────────────────────────────────────────╮
  │   Elementor MCP — Setup Wizard                │
  │   ───────────────────────────                 │
  │   Wires Claude Code to a WordPress site so    │
  │   I can build Elementor pages directly.       │
  ╰───────────────────────────────────────────────╯

BANNER

# ---- 1. Local vs live --------------------------------------------------------
step "1/8  Site type"
echo "    [1] Local-by-Flywheel  (any Local site, wherever it's stored)"
echo "    [2] Live host          (any WordPress site reachable over HTTP/HTTPS)"
ask "Pick (1 or 2):"
read -r SITE_TYPE
case "$SITE_TYPE" in
  1) MODE="local"; ok "Local-by-Flywheel mode" ;;
  2) MODE="live";  ok "Live-host mode" ;;
  *) abort "Invalid choice. Run again with 1 or 2." ;;
esac

# ---- 2. Site URL + path ------------------------------------------------------
step "2/8  Site URL"

if [ "$MODE" = "local" ]; then
  # Local records each site's REAL path + domain in sites.json. Read it so we
  # support sites created OUTSIDE the default ~/Local Sites/ folder (Local lets
  # you pick any location — e.g. ~/Documents/GitHub/MySite). Falls back to the
  # legacy ~/Local Sites/<name> convention when sites.json has no match.
  # Local stores sites.json under different roots per OS — pick the first that
  # exists (macOS, then the two common Linux locations).
  LOCAL_SITES_JSON=""
  for cand in \
    "$HOME/Library/Application Support/Local/sites.json" \
    "$HOME/.config/Local/sites.json" \
    "$HOME/.local/share/Local/sites.json"; do
    if [ -f "$cand" ]; then LOCAL_SITES_JSON="$cand"; break; fi
  done
  # Fall back to the macOS path so existing not-found messaging still applies.
  LOCAL_SITES_JSON="${LOCAL_SITES_JSON:-$HOME/Library/Application Support/Local/sites.json}"

  # Emits one "name<TAB>path<TAB>domain" line per configured Local site.
  list_local_sites() {
    [ -f "$LOCAL_SITES_JSON" ] || return 1
    python3 - "$LOCAL_SITES_JSON" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sites = d.values() if isinstance(d, dict) else d
rows = [v for v in sites if isinstance(v, dict) and v.get("name")]
if not rows:
    sys.exit(1)
for v in rows:
    print("\t".join([v.get("name", ""), v.get("path", ""), v.get("domain", "")]))
PY
  }

  if list_local_sites >/dev/null 2>&1; then
    info "Sites detected in Local:"
    while IFS=$'\t' read -r _n _p _dom; do
      printf "      ${CYAN}•${RESET} %s  ${DIM}(%s)${RESET}\n" "$_n" "$_dom"
    done < <(list_local_sites)
  elif [ -d "$HOME/Local Sites" ]; then
    info "Sites detected in ~/Local Sites/:"
    for d in "$HOME/Local Sites"/*/; do
      [ -d "$d" ] && printf "      ${CYAN}•${RESET} %s\n" "$(basename "$d")"
    done
  fi

  ask "Local site name:"
  read -r SITE_NAME

  # Resolve real path + URL from sites.json; fall back to the legacy convention.
  RESOLVED=$(list_local_sites 2>/dev/null | awk -F'\t' -v n="$SITE_NAME" '$1==n{print; exit}')
  if [ -n "$RESOLVED" ]; then
    # sites.json may store the path with a leading ~ — expand it, or the
    # wp-config.php probe below looks for a literal "~/..." dir and aborts.
    _lp="$(printf "%s" "$RESOLVED" | cut -f2)"
    case "$_lp" in \~|\~/*) _lp="$HOME${_lp#\~}" ;; esac
    SITE_PATH="${_lp}/app/public"
    SITE_URL="http://$(printf "%s" "$RESOLVED" | cut -f3)"
  else
    SITE_PATH="$HOME/Local Sites/$SITE_NAME/app/public"
    SITE_URL="http://${SITE_NAME}.local"
  fi
  [ -f "$SITE_PATH/wp-config.php" ] || abort "No wp-config.php at $SITE_PATH (is the site name correct? check Local)"
  ok "Site path:  $SITE_PATH"
  ok "Site URL:   $SITE_URL"
else
  ask "Full site URL (e.g. https://example.com — no trailing slash):"
  read -r SITE_URL
  SITE_URL="${SITE_URL%/}"
  [[ "$SITE_URL" =~ ^https?:// ]] || abort "URL must start with http:// or https://"
  # A live-host run sends a reusable application password on every request, so
  # plaintext http is refused unless the host is a local dev host or the caller
  # names it explicitly - same rule, and the same reasoning, as
  # wordpress-api-pro's WP_ALLOW_HTTP.
  case "$(http_verdict "$SITE_URL")" in
    refused)
      abort "Refusing http:// for $(url_host "$SITE_URL") — the application password would travel unencrypted.
  Use https://, or name this host explicitly: WP_ALLOW_HTTP=$(url_host "$SITE_URL") bash setup-elementor-mcp.sh"
      ;;
    named)
      warn "Sending credentials over plaintext http to $(url_host "$SITE_URL") (WP_ALLOW_HTTP names it)."
      ;;
  esac
  ok "Site URL:   $SITE_URL"
fi

# ---- 3. Connectivity probe ---------------------------------------------------
step "3/8  Connectivity"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$SITE_URL/wp-json/" || echo "000")
case "$HTTP_CODE" in
  200|301|302) ok "Reached WP REST API ($HTTP_CODE)" ;;
  000) abort "Could not reach $SITE_URL — is the site running?" ;;
  401|403) warn "REST returned $HTTP_CODE — may be auth-gated; continuing" ;;
  *) abort "Got HTTP $HTTP_CODE from $SITE_URL/wp-json/" ;;
esac

# ---- 4. Auth credentials -----------------------------------------------------
step "4/8  Authentication"

cat <<EOF
    You'll need a WordPress Application Password.
    To create one:
      1. Log in to ${SITE_URL}/wp-admin
      2. Users → Profile → scroll to "Application Passwords"
      3. Name it (e.g. "ClaudeMCP"), click Add — copy the password shown
      4. The password's NAME is just a label. The username is your WP login.
EOF

ask "WordPress username (your login, NOT the app-password label):"
read -r WP_USER
# Read the application password silently — it's a reusable secret, so it must
# NOT be echoed to the terminal (or captured in scrollback / screen shares).
ask "Application password (24 chars with spaces is OK — input hidden):"
read -rs WP_APP_PWD
printf '\n'

# Verify via /users/me
USERS_ME=$(curl -s -u "$WP_USER:$WP_APP_PWD" --max-time 10 "$SITE_URL/wp-json/wp/v2/users/me" || echo "{}")
USER_ID=$(echo "$USERS_ME" | jq_lenient '.id' 2>/dev/null || echo "")
if [ -n "$USER_ID" ] && [ "$USER_ID" != "" ]; then
  USER_NAME=$(echo "$USERS_ME" | jq_lenient '.name')
  ok "Authenticated as: $USER_NAME"
else
  # Deliberately do NOT enumerate/print the site's public user list here — that
  # would leak valid usernames (username enumeration) to anyone running setup.
  fail "Authentication failed."
  info "Verify your login username in ${SITE_URL}/wp-admin (Users → Profile — it's"
  info "your WP username, not the Application Password's label) and that the"
  info "Application Password was copied exactly (spaces are fine), then re-run."
  abort "Re-run with the correct username + application password."
fi

# ---- 5. Plugin baseline + optional auto-install ------------------------------
step "5/8  Plugin baseline"

# Helper: check if a given plugin folder/slug is active
plugin_is_active() {
  local slug="$1"
  echo "$PLUGINS_JSON" | python3 -c "$JQ_LENIENT_PY"'
import sys
slug = sys.argv[1]
d = _load(sys.stdin.read())
if isinstance(d, list):
    print("yes" if any(p.get("plugin","").startswith(slug+"/") and p.get("status")=="active" for p in d) else "no")
else:
    print("no")
' "$slug" 2>/dev/null || echo "no"
}

# Helper: check if a plugin is installed (any status)
plugin_is_installed() {
  local slug="$1"
  echo "$PLUGINS_JSON" | python3 -c "$JQ_LENIENT_PY"'
import sys
slug = sys.argv[1]
d = _load(sys.stdin.read())
if isinstance(d, list):
    print("yes" if any(p.get("plugin","").startswith(slug+"/") for p in d) else "no")
else:
    print("no")
' "$slug" 2>/dev/null || echo "no"
}

# Re-fetch the plugin list from REST.
# Updates the global $PLUGINS_JSON so plugin_is_active / plugin_is_installed
# reflect current state instead of cached snapshot.
refresh_plugins_json() {
  PLUGINS_JSON=$(curl -s -u "$WP_USER:$WP_APP_PWD" --max-time 10 \
    "$SITE_URL/wp-json/wp/v2/plugins" || echo "[]")
}

# Helper: install + activate a plugin from wordpress.org by slug via REST.
# REST plugins endpoint accepts {slug, status} — installs from wp.org directly.
# After install, RE-VERIFIES activation actually took effect (retries once).
install_wp_plugin() {
  local slug="$1"
  local label="$2"

  # Skip if already active
  if [ "$(plugin_is_active "$slug")" = "yes" ]; then
    ok "$label already active"
    return 0
  fi

  # Already installed but inactive — just activate
  if [ "$(plugin_is_installed "$slug")" = "yes" ]; then
    info "$label already installed — activating..."
    local plugin_path
    plugin_path=$(echo "$PLUGINS_JSON" | python3 -c "$JQ_LENIENT_PY"'
import sys
slug = sys.argv[1]
d = _load(sys.stdin.read())
if isinstance(d, list):
    for p in d:
        if p.get("plugin","").startswith(slug+"/"):
            print(p["plugin"]); break
' "$slug" 2>/dev/null)
    if [ -n "$plugin_path" ]; then
      curl -s -u "$WP_USER:$WP_APP_PWD" --max-time 30 \
        -H "Content-Type: application/json" \
        -X POST "$SITE_URL/wp-json/wp/v2/plugins/$plugin_path" \
        -d '{"status":"active"}' >/dev/null
    fi
  else
    info "Installing + activating $label from wordpress.org..."
    local result err
    result=$(curl -s -u "$WP_USER:$WP_APP_PWD" --max-time 60 \
      -H "Content-Type: application/json" \
      -X POST "$SITE_URL/wp-json/wp/v2/plugins" \
      -d "{\"slug\":\"$slug\",\"status\":\"active\"}" || echo '{"code":"network_error"}')
    err=$(echo "$result" | jq_lenient '.code' 2>/dev/null || echo "")
    if [ -n "$err" ] && [ "$err" != "" ]; then
      fail "Could not install $label: $err"
      return 1
    fi
  fi

  # ⭐ VERIFY activation actually took effect. WP REST sometimes returns
  # 200 for the install but the plugin ends up inactive (load order, race).
  refresh_plugins_json
  if [ "$(plugin_is_active "$slug")" = "yes" ]; then
    ok "Installed + activated $label"
    return 0
  fi

  # Retry activation once
  warn "$label installed but not active yet — retrying activation..."
  local plugin_path
  plugin_path=$(echo "$PLUGINS_JSON" | python3 -c "$JQ_LENIENT_PY"'
import sys
slug = sys.argv[1]
d = _load(sys.stdin.read())
if isinstance(d, list):
    for p in d:
        if p.get("plugin","").startswith(slug+"/"):
            print(p["plugin"]); break
' "$slug" 2>/dev/null)
  if [ -n "$plugin_path" ]; then
    curl -s -u "$WP_USER:$WP_APP_PWD" --max-time 30 \
      -H "Content-Type: application/json" \
      -X POST "$SITE_URL/wp-json/wp/v2/plugins/$plugin_path" \
      -d '{"status":"active"}' >/dev/null
    sleep 1
    refresh_plugins_json
  fi

  if [ "$(plugin_is_active "$slug")" = "yes" ]; then
    ok "Installed + activated $label (after retry)"
    return 0
  fi

  fail "$label installed but could NOT auto-activate."
  info "Activate manually: ${SITE_URL}/wp-admin/plugins.php"
  return 1
}

# Helper: fully remove a plugin (deactivate, then delete) via REST, by slug.
# Used to clear out an old standalone plugin BEFORE installing something that
# bundles/replaces it — e.g. the standalone `mcp-adapter` plugin once the
# elementor-mcp fork bundles its own copy. Leaving both loaded double-registers
# the MCP transport and breaks the route, so this must fully succeed (verified
# via refresh_plugins_json + plugin_is_installed) before the caller proceeds.
# Returns 0 only if the plugin is confirmed GONE afterward.
remove_plugin() {
  local slug="$1"
  local label="$2"

  if [ "$(plugin_is_installed "$slug")" != "yes" ]; then
    ok "$label not installed — nothing to remove"
    return 0
  fi

  local plugin_path
  plugin_path=$(echo "$PLUGINS_JSON" | python3 -c "$JQ_LENIENT_PY"'
import sys
slug = sys.argv[1]
d = _load(sys.stdin.read())
if isinstance(d, list):
    for p in d:
        if p.get("plugin","").startswith(slug+"/"):
            print(p["plugin"]); break
' "$slug" 2>/dev/null)

  if [ -z "$plugin_path" ]; then
    fail "Could not resolve plugin path for $label ($slug) — cannot remove via REST"
    return 1
  fi

  if [ "$(plugin_is_active "$slug")" = "yes" ]; then
    info "Deactivating $label..."
    curl -s -u "$WP_USER:$WP_APP_PWD" --max-time 30 \
      -H "Content-Type: application/json" \
      -X PUT "$SITE_URL/wp-json/wp/v2/plugins/$plugin_path" \
      -d '{"status":"inactive"}' >/dev/null
  fi

  info "Deleting $label..."
  curl -s -u "$WP_USER:$WP_APP_PWD" --max-time 30 \
    -X DELETE "$SITE_URL/wp-json/wp/v2/plugins/$plugin_path" >/dev/null

  refresh_plugins_json
  if [ "$(plugin_is_installed "$slug")" = "no" ]; then
    ok "$label removed"
    return 0
  fi

  fail "$label still present after deactivate + delete attempt"
  return 1
}

# Helper: install + activate a theme from wordpress.org by slug
install_wp_theme() {
  local slug="$1"
  local label="$2"
  info "Installing $label theme from wordpress.org..."
  local result
  result=$(curl -s -u "$WP_USER:$WP_APP_PWD" --max-time 60 \
    -H "Content-Type: application/json" \
    -X POST "$SITE_URL/wp-json/wp/v2/themes" \
    -d "{\"slug\":\"$slug\"}" 2>&1 || echo '{}')
  # Switching themes via REST isn't standard — fall back to telling user
  # how to activate it (many WP versions don't support theme activation via REST).
  warn "Theme installed but auto-activation isn't supported via REST API in all WP versions."
  warn "Activate it manually: WP Admin → Appearance → Themes → $label → Activate"
}

# Fetch current state once
PLUGINS_JSON=$(curl -s -u "$WP_USER:$WP_APP_PWD" --max-time 10 "$SITE_URL/wp-json/wp/v2/plugins" || echo "[]")
THEME_JSON=$(curl -s -u "$WP_USER:$WP_APP_PWD" --max-time 10 "$SITE_URL/wp-json/wp/v2/themes?status=active" || echo "[]")
ACTIVE_THEME=$(echo "$THEME_JSON" | python3 -c "$JQ_LENIENT_PY"'
import sys
d = _load(sys.stdin.read())
print(d[0]["stylesheet"] if isinstance(d, list) and d else "?")
' 2>/dev/null || echo "?")

# Report current state
HAS_ELEMENTOR=$(plugin_is_active "elementor")
HAS_PRO=$(plugin_is_active "elementor-pro")
HAS_UAE=$(plugin_is_active "header-footer-elementor")
HAS_EA=$(plugin_is_active "essential-addons-for-elementor-lite")
HAS_FF=$(plugin_is_active "fluentform")
# Dynamic-data stacks (Tier-0): JetEngine + ACF (free / Pro / Secure Custom Fields fork).
HAS_JET=$(plugin_is_active "jet-engine")
HAS_ACF="no"
for acf_slug in advanced-custom-fields advanced-custom-fields-pro secure-custom-fields; do
  [ "$(plugin_is_active "$acf_slug")" = "yes" ] && { HAS_ACF="yes"; break; }
done

[ "$HAS_ELEMENTOR" = "yes" ] && ok "Elementor (free) — active" || warn "Elementor — not active"
if [ "$HAS_PRO" = "yes" ]; then
  ok "Elementor Pro — active (native Form, Theme Builder, Loop Grid, Popups available)"
else
  info "Elementor Pro — not active (free tier; using UAE + Fluent Forms workarounds)"
fi
# Dynamic-data stacks — reported so the skill branches into ACF/JetEngine guidance.
[ "$HAS_JET" = "yes" ] && ok "Crocoblock JetEngine — active (dynamic listings/fields via add-widget)"
if [ "$HAS_ACF" = "yes" ]; then
  [ "$HAS_PRO" = "yes" ] && ok "ACF — active (bind via Pro dynamic tags)" \
                        || warn "ACF — active, but dynamic-tag binding needs Elementor Pro"
fi
[ "$ACTIVE_THEME" = "hello-elementor" ] && ok "Theme: Hello Elementor — active" || warn "Theme: $ACTIVE_THEME (Hello Elementor recommended)"
# UAE/HFE is only needed for headers/footers on the FREE tier — Pro has Theme Builder.
if [ "$HAS_PRO" = "yes" ]; then
  [ "$HAS_UAE" = "yes" ] && ok "UAE / Header Footer Elementor — active (optional; Pro Theme Builder covers this)" || info "UAE / Header Footer Elementor — not needed (Pro Theme Builder covers headers/footers)"
else
  [ "$HAS_UAE" = "yes" ] && ok "UAE / Header Footer Elementor — active" || warn "UAE / Header Footer Elementor — not active (needed for headers/footers)"
fi

# ---- 6. Optional auto-install of baseline plugins ----------------------------
step "6/8  Auto-install baseline plugins?"

# With Pro active, the UAE + Fluent Forms workarounds are unnecessary — Pro's
# native Theme Builder and Form widget cover those. So Pro changes both what
# counts as "missing baseline" and what we offer to install.
NEEDS_ANY="no"
[ "$HAS_ELEMENTOR" != "yes" ] && NEEDS_ANY="yes"
[ "$HAS_PRO" != "yes" ] && [ "$HAS_UAE" != "yes" ] && NEEDS_ANY="yes"
[ "$ACTIVE_THEME" != "hello-elementor" ] && NEEDS_ANY="yes"

if [ "$HAS_PRO" = "yes" ]; then
  info "Elementor Pro detected — skipping UAE + Fluent Forms (Pro covers headers/footers + forms natively)."
fi

if [ "$NEEDS_ANY" = "no" ]; then
  ok "All baseline plugins + theme already in place — skipping auto-install."
else
  if [ "$HAS_PRO" = "yes" ]; then
    cat <<EOF
    Some baseline pieces aren't yet active on this site.
    The wizard can install them for you from wordpress.org:

      • Elementor (free)         — base for Elementor Pro
      • Hello Elementor (theme)  — blank canvas theme
      • Essential Addons (lite)  — extra free widgets (optional)

    ${YELLOW}Note:${RESET} Pro is active — no UAE or Fluent Forms needed.
    Auto-install is safest on a fresh demo site. If this is an existing
    site you care about, choose 'No' and install manually.
EOF
    ask "Auto-install Elementor (free base)? [Y/n]"
    read -r DO_INSTALL
    if [[ ! "$DO_INSTALL" =~ ^[Nn]$ ]]; then
      [ "$HAS_ELEMENTOR" != "yes" ] && install_wp_plugin "elementor" "Elementor (free)"

      if [ "$ACTIVE_THEME" != "hello-elementor" ]; then
        ask "Also install Hello Elementor theme? (Switch theme manually after.) [Y/n]"
        read -r DO_THEME
        [[ ! "$DO_THEME" =~ ^[Nn]$ ]] && install_wp_theme "hello-elementor" "Hello Elementor"
      fi

      ask "Also install Essential Addons (optional but useful)? [y/N]"
      read -r DO_OPT
      [[ "$DO_OPT" =~ ^[Yy]$ ]] && [ "$HAS_EA" != "yes" ] && install_wp_plugin "essential-addons-for-elementor-lite" "Essential Addons (lite)"
    else
      info "Skipped auto-install. Install missing baseline pieces yourself before using Claude to build."
    fi
  else
    cat <<EOF
    Some baseline plugins/theme aren't yet active on this site.
    The wizard can install them for you from wordpress.org:

      • Elementor (free)         — the page builder
      • Hello Elementor (theme)  — blank canvas theme
      • UAE / Header Footer      — for site-wide headers and footers
      • Essential Addons (lite)  — extra free widgets (optional)
      • Fluent Forms             — real working contact forms (optional)

    ${YELLOW}Note:${RESET} Auto-install is safest on a fresh demo site. If this is
    an existing site with content/theme you care about, choose 'No'
    and install manually via WP Admin → Plugins → Add New.
EOF
    ask "Auto-install Elementor + UAE? [Y/n]"
    read -r DO_INSTALL
    if [[ ! "$DO_INSTALL" =~ ^[Nn]$ ]]; then
      [ "$HAS_ELEMENTOR" != "yes" ] && install_wp_plugin "elementor" "Elementor (free)"
      [ "$HAS_UAE" != "yes" ] && install_wp_plugin "header-footer-elementor" "UAE / Header Footer Elementor"

      if [ "$ACTIVE_THEME" != "hello-elementor" ]; then
        ask "Also install Hello Elementor theme? (Switch theme manually after.) [Y/n]"
        read -r DO_THEME
        [[ ! "$DO_THEME" =~ ^[Nn]$ ]] && install_wp_theme "hello-elementor" "Hello Elementor"
      fi

      ask "Also install Essential Addons + Fluent Forms (optional but useful)? [y/N]"
      read -r DO_OPT
      if [[ "$DO_OPT" =~ ^[Yy]$ ]]; then
        [ "$HAS_EA" != "yes" ] && install_wp_plugin "essential-addons-for-elementor-lite" "Essential Addons (lite)"
        [ "$HAS_FF" != "yes" ] && install_wp_plugin "fluentform" "Fluent Forms"
      fi
    else
      info "Skipped auto-install. You'll need to install the missing plugins yourself before using Claude to build."
    fi
  fi
fi

# ---- 7. Install MCP plugin ---------------------------------------------------
step "7/8  Installing MCP plugin"

# The skill requires the Digitizers elementor-mcp FORK, which BUNDLES the MCP
# Adapter. Older sites ran the upstream pair: a SEPARATE `mcp-adapter` plugin
# alongside `elementor-mcp`. That pair still registers the generic `mcp`
# namespace, so "namespace present" alone must NOT short-circuit the install —
# it would leave the old, unbundled setup in place forever. Detect the old pair
# (a standalone mcp-adapter plugin, or an elementor-mcp below the fork's floor)
# and offer to (re)install the bundled fork over it.
REQUIRED_EMCP_VERSION="1.10.0"   # floor for the bundled Digitizers fork

# Version of the installed elementor-mcp plugin (empty if not installed).
emcp_installed_version() {
  echo "$PLUGINS_JSON" | python3 -c "$JQ_LENIENT_PY"'
import sys
d = _load(sys.stdin.read())
if isinstance(d, list):
    for p in d:
        if p.get("plugin","").startswith("elementor-mcp/"):
            print(p.get("version","")); break
' 2>/dev/null || echo ""
}

# True (0) when dotted version $1 is strictly lower than $2.
ver_lt() {
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$1" ]
}

NS_JSON=$(curl -s -u "$WP_USER:$WP_APP_PWD" --max-time 10 "$SITE_URL/wp-json/" || echo "{}")
HAS_MCP=$(echo "$NS_JSON" | jq_lenient_contains '.namespaces' 'mcp' 2>/dev/null || echo "no")
HAS_OLD_ADAPTER=$(plugin_is_installed "mcp-adapter")
EMCP_VER=$(emcp_installed_version)

NEEDS_UPGRADE="no"
[ "$HAS_OLD_ADAPTER" = "yes" ] && NEEDS_UPGRADE="yes"
{ [ -n "$EMCP_VER" ] && ver_lt "$EMCP_VER" "$REQUIRED_EMCP_VERSION"; } && NEEDS_UPGRADE="yes"

SKIP_MCP_INSTALL="no"
if [ "$HAS_MCP" = "yes" ] && [ "$NEEDS_UPGRADE" = "no" ]; then
  ok "MCP namespace already registered${EMCP_VER:+ (elementor-mcp $EMCP_VER, bundled fork)} — skipping plugin install."
  SKIP_MCP_INSTALL="yes"
elif [ "$HAS_MCP" = "yes" ] && [ "$NEEDS_UPGRADE" = "yes" ]; then
  warn "An older MCP setup is present — the skill needs the bundled elementor-mcp fork:"
  [ "$HAS_OLD_ADAPTER" = "yes" ] && info "  • standalone 'MCP Adapter' plugin found — the fork bundles the adapter, so the separate one must be removed"
  { [ -n "$EMCP_VER" ] && ver_lt "$EMCP_VER" "$REQUIRED_EMCP_VERSION"; } && info "  • elementor-mcp $EMCP_VER is below the required $REQUIRED_EMCP_VERSION"
  info "  Accepting below will deactivate + delete the standalone 'MCP Adapter' via REST"
  info "  and verify it's gone BEFORE installing the bundled fork — running both at once"
  info "  double-loads the MCP transport and breaks the route."
  ask "(Re)install the bundled fork now? [Y/n]"
  read -r DO_UPGRADE
  if [[ "$DO_UPGRADE" =~ ^[Nn]$ ]]; then
    warn "Leaving the existing MCP plugins as-is. Remove the old pair and re-run if the MCP misbehaves."
    SKIP_MCP_INSTALL="yes"
  elif [ "$HAS_OLD_ADAPTER" = "yes" ]; then
    if remove_plugin "mcp-adapter" "MCP Adapter (standalone)"; then
      ok "Old standalone MCP Adapter removed — safe to install the bundled fork."
    else
      warn "Could not automatically remove the standalone 'MCP Adapter' plugin."
      cat <<EOF

    Installing the bundled fork on top of the old adapter would leave TWO
    adapter implementations loaded, which breaks the MCP route. This step
    will NOT proceed until the standalone adapter is confirmed gone.

    Please remove it by hand:
      1. Open ${CYAN}${SITE_URL}/wp-admin/plugins.php${RESET}
      2. Deactivate "MCP Adapter"
      3. Delete "MCP Adapter"

EOF
      REMOVED_OLD_ADAPTER="no"
      while [ "$REMOVED_OLD_ADAPTER" != "yes" ]; do
        ask "Press Enter once removed (or type 'abort' to stop here)..."
        read -r ADAPTER_RECHECK
        if [ "$ADAPTER_RECHECK" = "abort" ]; then
          abort "Stopped — remove the standalone MCP Adapter plugin, then re-run this wizard."
        fi
        refresh_plugins_json
        if [ "$(plugin_is_installed "mcp-adapter")" = "no" ]; then
          REMOVED_OLD_ADAPTER="yes"
          ok "Confirmed — standalone MCP Adapter is gone."
        else
          warn "Still detected — try again, or type 'abort'."
        fi
      done
    fi
  fi
fi

if [ "$SKIP_MCP_INSTALL" = "no" ]; then
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT

  # The plugin is fetched from the trusted Digitizers/elementor-mcp repo over
  # HTTPS. By default we pull `releases/latest` (unpinned) so re-runs pick up
  # security fixes and the auto-update floor ($REQUIRED_EMCP_VERSION) stays met.
  # Security-conscious users can pin an exact release tag by exporting
  # EMCP_PIN_VERSION (e.g. EMCP_PIN_VERSION=v1.10.0) before running this script.
  EMCP_PIN_VERSION="${EMCP_PIN_VERSION:-}"
  if [ -n "$EMCP_PIN_VERSION" ]; then
    EM_RELEASE_API="https://api.github.com/repos/Digitizers/elementor-mcp/releases/tags/${EMCP_PIN_VERSION}"
    info "Downloading the elementor-mcp fork — pinned to ${EMCP_PIN_VERSION} (trusted Digitizers repo, HTTPS)..."
  else
    EM_RELEASE_API="https://api.github.com/repos/Digitizers/elementor-mcp/releases/latest"
    info "Downloading the elementor-mcp fork (bundles the MCP Adapter, latest release from the trusted Digitizers repo over HTTPS; set EMCP_PIN_VERSION to pin a tag)..."
  fi
  # Take the asset's sha256 from the SAME API response as its URL, so a
  # download mangled or swapped in transit (proxy, CDN, partial transfer) is
  # caught before the zip is installed onto a WordPress site.
  #
  # Be clear about what this is NOT: the digest travels with the URL, so it
  # proves integrity, not provenance. A compromised release would publish a
  # matching digest for a malicious asset. Export EMCP_EXPECTED_SHA256 with a
  # digest obtained out of band for a real provenance check.
  EM_RELEASE_JSON=$(curl -s "$EM_RELEASE_API")
  EM_ZIPBALL=$(printf '%s' "$EM_RELEASE_JSON" \
    | python3 -c "$JQ_LENIENT_PY"'
import sys
d = _load(sys.stdin.read())
a = [a for a in d.get("assets",[]) if a["name"].endswith(".zip")]
print(a[0]["browser_download_url"] if a else d.get("zipball_url",""))
')
  EM_DIGEST=$(printf '%s' "$EM_RELEASE_JSON" \
    | python3 -c "$JQ_LENIENT_PY"'
import sys
d = _load(sys.stdin.read())
a = [a for a in d.get("assets",[]) if a["name"].endswith(".zip")]
print((a[0].get("digest") or "").replace("sha256:","") if a else "")
')
  [ -n "$EM_ZIPBALL" ] || abort "Could not fetch elementor-mcp download URL.${EMCP_PIN_VERSION:+ Check that EMCP_PIN_VERSION=$EMCP_PIN_VERSION is a real release tag.}"
  curl -sL -o "$WORK/elementor-mcp-src.zip" "$EM_ZIPBALL" || abort "elementor-mcp download failed."

  # Verify before unzipping: the archive is about to be installed and activated
  # as PHP on a WordPress site, so a bad one must never reach the repack step.
  EM_EXPECTED="${EMCP_EXPECTED_SHA256:-$EM_DIGEST}"
  if [ -n "$EM_EXPECTED" ]; then
    EM_ACTUAL=$(sha256_of "$WORK/elementor-mcp-src.zip")
    if [ "$EM_ACTUAL" != "$EM_EXPECTED" ]; then
      abort "elementor-mcp download failed integrity check.
    expected sha256: $EM_EXPECTED
    got sha256:      $EM_ACTUAL
  Nothing was installed. Re-run; if it persists, the download is being tampered with or the release was replaced."
    fi
    ok "Download verified (sha256 ${EM_ACTUAL:0:12}…)${EMCP_EXPECTED_SHA256:+ against EMCP_EXPECTED_SHA256}"
  else
    warn "This release publishes no sha256 for its asset — installing an UNVERIFIED download."
    info "  Pin it instead: EMCP_PIN_VERSION=<tag> EMCP_EXPECTED_SHA256=<digest> ./setup-elementor-mcp.sh"
  fi

  # Repack with clean folder name (zipballs have ugly hash-suffixed dirs)
  ( cd "$WORK" && unzip -q elementor-mcp-src.zip )
  EM_DIR=$(find "$WORK" -maxdepth 1 -type d -name "*elementor-mcp*" ! -name "Digitizers-elementor-mcp" 2>/dev/null | head -1)
  if [ -n "$EM_DIR" ] && [ "$(basename "$EM_DIR")" != "elementor-mcp" ]; then
    mv "$EM_DIR" "$WORK/elementor-mcp"
  fi
  ( cd "$WORK" && rm -f elementor-mcp.zip && zip -qr elementor-mcp.zip elementor-mcp )
  ok "Repacked elementor-mcp.zip with clean folder name"

  MANUAL_UPLOAD="no"
  if [ "$MODE" = "local" ]; then
    # Install via WP-CLI through Local's bundled binaries. macOS and Linux store
    # Local's data dir + app resources under different roots — probe both so a
    # Linux site resolved from sites.json (see the roots list in step 2) can
    # install too, instead of aborting on macOS-only paths. If the bundled
    # toolchain or a live socket can't be found, fall through to manual upload.
    info "Installing via Local's bundled WP-CLI..."

    LOCAL_DATA_ROOT=""
    for root in \
      "$HOME/Library/Application Support/Local" \
      "$HOME/.config/Local" \
      "$HOME/.local/share/Local"; do
      [ -d "$root" ] && { LOCAL_DATA_ROOT="$root"; break; }
    done

    LOCAL_PHP=""
    [ -n "$LOCAL_DATA_ROOT" ] && LOCAL_PHP=$(find "$LOCAL_DATA_ROOT/lightning-services" -maxdepth 6 -name "php" -type f 2>/dev/null | head -1)

    LOCAL_WP=""
    for cand in \
      "/Applications/Local.app/Contents/Resources/extraResources/bin/wp-cli/posix/wp" \
      "/opt/Local/resources/extraResources/bin/wp-cli/posix/wp" \
      "/usr/lib/local-by-flywheel/resources/extraResources/bin/wp-cli/posix/wp"; do
      [ -f "$cand" ] && { LOCAL_WP="$cand"; break; }
    done
    # Last resort: a wp-cli on PATH (still driven by Local's PHP + socket).
    [ -z "$LOCAL_WP" ] && command -v wp >/dev/null 2>&1 && LOCAL_WP="$(command -v wp)"

    if [ -x "$LOCAL_PHP" ] && [ -n "$LOCAL_WP" ] && [ -d "$LOCAL_DATA_ROOT/run" ]; then
      # Find the MySQL socket that actually serves THIS site (only the running
      # site's socket answers `core version`).
      SOCK=$(find "$LOCAL_DATA_ROOT/run" -name "mysqld.sock" 2>/dev/null | while read s; do
        if "$LOCAL_PHP" -d "mysqli.default_socket=$s" -d "pdo_mysql.default_socket=$s" "$LOCAL_WP" --path="$SITE_PATH" --skip-plugins --skip-themes core version >/dev/null 2>&1; then
          echo "$s"; break
        fi
      done)
      if [ -n "$SOCK" ]; then
        ok "MySQL socket: $SOCK"
        PHPRUN=( "$LOCAL_PHP" -d "mysqli.default_socket=$SOCK" -d "pdo_mysql.default_socket=$SOCK" )
        info "Installing elementor-mcp (fork — bundles the MCP Adapter)..."
        "${PHPRUN[@]}" "$LOCAL_WP" --path="$SITE_PATH" --skip-plugins --skip-themes plugin install "$WORK/elementor-mcp.zip" --activate --force >/dev/null 2>&1 \
          && ok "elementor-mcp installed + activated" || fail "elementor-mcp install failed"
      else
        warn "Could not find a live MySQL socket for $SITE_NAME (is the site started in Local?)."
        MANUAL_UPLOAD="yes"
      fi
    else
      warn "Couldn't locate Local's bundled WP-CLI toolchain on this OS."
      MANUAL_UPLOAD="yes"
    fi
  fi

  if [ "$MODE" != "local" ] || [ "$MANUAL_UPLOAD" = "yes" ]; then
    # Live host — or Local without a usable bundled WP-CLI (e.g. an atypical
    # Linux install). REST can't push arbitrary plugin zips, so upload by hand.
    warn "REST API can't install arbitrary plugin zips here — upload it by hand."
    info ""
    info "Zip ready at:"
    info "  $WORK/elementor-mcp.zip"
    info ""
    info "Upload it via:"
    info "  ${SITE_URL}/wp-admin/plugin-install.php?tab=upload"
    info ""
    info "(Choose file → Install Now → Activate Plugin.)"
    info ""
    ask "Press Enter once it's uploaded and activated..."
    read -r _
  fi
fi

# ---- 6b. Verify MCP namespace, with interactive recovery on failure --------
info "Verifying /mcp/elementor-mcp-server route..."
sleep 2

verify_mcp_namespace() {
  local ns_json
  ns_json=$(curl -s -u "$WP_USER:$WP_APP_PWD" --max-time 10 "$SITE_URL/wp-json/" || echo "{}")
  local has_mcp has_em
  has_mcp=$(echo "$ns_json" | jq_lenient_contains '.namespaces' 'mcp' 2>/dev/null || echo "no")
  has_em=$(echo "$ns_json" | jq_lenient_contains '.routes' 'elementor-mcp-server' 2>/dev/null || echo "no")
  [ "$has_mcp" = "yes" ] && [ "$has_em" = "yes" ] && return 0
  return 1
}

if verify_mcp_namespace; then
  ok "Elementor MCP server route registered ✓"
else
  # Recovery loop — common cause: plugin installed but didn't auto-activate
  warn "MCP namespace not yet registered."
  cat <<EOF

    This usually means the MCP plugin installed but didn't
    auto-activate. WordPress sometimes returns success for the install
    request even when activation was skipped (load order, race condition,
    or PHP-FPM opcode cache).

    Please open WP Admin → Plugins in your browser and confirm this
    is active (look for "Deactivate" not "Activate"):

      • MCP Tools for Elementor   (the fork — bundles the MCP Adapter)

    URL: ${CYAN}${SITE_URL}/wp-admin/plugins.php${RESET}

    If it's grey/inactive, click "Activate" on it.

EOF
  ask "Press Enter when both are active (or 'skip' to bypass this check)..."
  read -r RECOVER

  if [ "$RECOVER" = "skip" ]; then
    warn "Skipping MCP verification — proceeding to write .mcp.json anyway."
    warn "If Claude Code can't reach the MCP, fix the activation issue and re-run."
  else
    sleep 1
    if verify_mcp_namespace; then
      ok "Elementor MCP server route now registered ✓"
    else
      warn "Still not seeing the MCP namespace."
      info "Things to try, in order:"
      info "  1. WP Admin → Plugins: deactivate then reactivate both MCP plugins"
      info "  2. Check WP Admin → Plugins for any error notices at the top"
      info "  3. WP Admin → Settings → Permalinks → Save (flushes rewrites)"
      info "  4. Restart your Local site (stop + start)"
      ask "Try again? Press Enter to retry, or 'skip' to write .mcp.json anyway..."
      read -r RECOVER2
      if [ "$RECOVER2" = "skip" ]; then
        warn "Proceeding to .mcp.json anyway. Fix activation before using Claude."
      else
        sleep 1
        if verify_mcp_namespace; then
          ok "Elementor MCP server route now registered ✓"
        else
          fail "MCP namespace still missing after retry."
          info "Writing .mcp.json anyway so you can debug from there."
          info "Run this to see what's wrong: curl -u USER:PASS ${SITE_URL}/wp-json/"
        fi
      fi
    fi
  fi
fi

# ---- 7. Write .mcp.json ------------------------------------------------------
step "8/8  Writing .mcp.json"
PROJECT_DIR="$(pwd)"
MCP_FILE="$PROJECT_DIR/.mcp.json"

# Base64-encode auth (Python3 portable)
AUTH_B64=$(printf "%s:%s" "$WP_USER" "$WP_APP_PWD" | python3 -c "import sys,base64; sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode())")

# If .mcp.json already exists, merge (don't clobber)
if [ -f "$MCP_FILE" ]; then
  # A git-TRACKED placeholder config (the kit's committed cloud config, secrets as
  # ${VAR} env placeholders) must never be replaced with a real-credential file:
  # gitignore can't protect a tracked path, and untracking it would stage the
  # committed feature for deletion.
  if git -C "$PROJECT_DIR" ls-files --error-unmatch .mcp.json >/dev/null 2>&1 \
     && grep -q '"WP_URL": *"\${WP_URL' "$MCP_FILE" 2>/dev/null; then
    warn ".mcp.json here is a committed placeholder config (tracked in git) — refusing to write credentials into it."
    info "  Either: export WP_URL / WP_USERNAME / WP_APP_PASSWORD in your environment (the committed config reads them),"
    info "  or run this wizard from a separate per-site project directory."
    SKIP_WRITE=1
    TRACKED_PLACEHOLDER=1
  else
    warn ".mcp.json already exists at $MCP_FILE"
    ask "Overwrite? [y/N]"
    read -r OVR
    [[ "$OVR" =~ ^[Yy]$ ]] || { info "Leaving existing .mcp.json untouched. New config printed below."; SKIP_WRITE=1; }
  fi
fi

NEW_CONFIG=$(cat <<JSON
{
  "mcpServers": {
    "elementor": {
      "type": "http",
      "url": "${SITE_URL}/wp-json/mcp/elementor-mcp-server",
      "headers": {
        "Authorization": "Basic ${AUTH_B64}"
      }
    }
  }
}
JSON
)

if [ "${SKIP_WRITE:-0}" != "1" ]; then
  # Create it 0600 BEFORE the credential lands in it: writing first and chmod-ing
  # after leaves a window where the file is world-readable on a shared machine.
  ( umask 077; : > "$MCP_FILE" )
  chmod 600 "$MCP_FILE" 2>/dev/null || warn "Could not chmod 600 $MCP_FILE — check its permissions yourself."
  printf "%s\n" "$NEW_CONFIG" > "$MCP_FILE"
  ok "Wrote $MCP_FILE (mode 600)"

  # .mcp.json embeds a reusable Basic-Auth credential (base64 of
  # user:app-password). If we're inside a git repo, make sure it can't be
  # accidentally committed: ignore it unless it's already ignored.
  if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # If .mcp.json is already TRACKED (committed in an earlier run), a .gitignore
    # rule does NOT protect it — git keeps reporting the credential file. Untrack
    # it from the index first so the ignore rule can take effect.
    if git -C "$PROJECT_DIR" ls-files --error-unmatch .mcp.json >/dev/null 2>&1; then
      if git -C "$PROJECT_DIR" rm --cached -q .mcp.json 2>/dev/null; then
        warn ".mcp.json was tracked by git — removed it from the index (commit this removal)."
        info "  • It may still live in earlier commits; if it was ever pushed, rotate the Application Password."
      fi
    fi
    if git -C "$PROJECT_DIR" check-ignore -q .mcp.json 2>/dev/null; then
      info ".mcp.json is already git-ignored — good."
    else
      GITIGNORE="$PROJECT_DIR/.gitignore"
      { [ -f "$GITIGNORE" ] && [ -s "$GITIGNORE" ] && [ -z "$(tail -c1 "$GITIGNORE")" ]; } || printf '\n' >> "$GITIGNORE"
      printf '# Contains reusable WordPress credentials — keep out of version control\n.mcp.json\n' >> "$GITIGNORE"
      ok "Added .mcp.json to $GITIGNORE so it won't be committed."
    fi
  fi

  warn "SECURITY: $MCP_FILE holds a reusable WordPress credential (Basic auth)."
  info "  • Keep it out of version control and off shared machines."
  info "  • Use a least-privileged Application Password (only the role you need)."
  info "  • Rotate/revoke that Application Password after setup or client handoff"
  info "    (WP Admin → Users → Profile → Application Passwords → Revoke)."
elif [ "${TRACKED_PLACEHOLDER:-0}" != "1" ]; then
  echo
  info "Suggested config (the credential is REDACTED — this goes to your terminal,"
  info "scrollback and any screen share, so the real value is not printed):"
  printf '%s\n' "$NEW_CONFIG" | redact_basic_auth | sed 's/^/      /'
  info "  Fill it in with: printf '%s:%s' \"\$WP_USERNAME\" \"\$WP_APP_PASSWORD\" | base64"
  warn "SECURITY: that config embeds a reusable WordPress credential — write it"
  info "  with mode 600, keep it out of version control, and rotate/revoke the"
  info "  Application Password after use."
fi

# ---- final instructions ------------------------------------------------------
if [ "$HAS_PRO" = "yes" ]; then
  printf "\n  ${BOLD}${GREEN}Elementor Pro is active${RESET} — Claude will use native ${BOLD}Form${RESET}, ${BOLD}Theme Builder${RESET},\n  ${BOLD}Loop Grid${RESET}, ${BOLD}Popups${RESET}, ${BOLD}Dynamic Tags${RESET}, and ${BOLD}Sticky/Motion${RESET} (no workaround plugins).\n"
else
  printf "\n  ${DIM}Free Elementor — Claude will use the documented workarounds (Fluent Forms,\n  UAE/HFE headers). Activate Elementor Pro and re-run this wizard to unlock native\n  Form / Theme Builder / Loop Grid / Popups.${RESET}\n"
fi

if [ "${TRACKED_PLACEHOLDER:-0}" = "1" ]; then
cat <<EOF

  ${BOLD}${YELLOW}⚠ Site setup done — the Claude connection is NOT configured yet${RESET}

  This checkout uses the committed placeholder .mcp.json, which reads the
  connection from environment variables. The wizard did not persist your
  credentials anywhere. Finish with:
    export WP_URL="$SITE_URL"
    export WP_USERNAME="$WP_USER"
    export WP_APP_PASSWORD="<the application password you entered>"
  Then restart Claude Code in this directory — or run this wizard again from a
  separate per-site project directory to write a local .mcp.json instead.
EOF
exit 0
fi

cat <<EOF

  ${BOLD}${GREEN}✓ Setup complete${RESET}

  ${BOLD}Three steps to start using it:${RESET}
    1. ${CYAN}Quit Claude Code${RESET} (Cmd-Q in the desktop app, or Ctrl-C in the CLI)
    2. ${CYAN}Reopen it in this directory:${RESET}  cd "$PROJECT_DIR"
    3. Claude Code will ask you to ${BOLD}approve the 'elementor' MCP server${RESET} — say yes

  ${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}
  ${BOLD}What can you do now?${RESET}

  Claude can ${BOLD}build${RESET}, ${BOLD}edit${RESET}, ${BOLD}reference${RESET}, or ${BOLD}explore${RESET} your Elementor site.
  Type ${CYAN}/siteagent-elementor-studio${RESET} or ask in plain words. Examples:

  ${BOLD}🏗  Build${RESET} — create new pages or sections from a design
    ${DIM}"Build me a homepage based on this HTML mockup"${RESET}
    ${DIM}"Add a contact section with a form"${RESET}
    ${DIM}"Build a site-wide header using my Main menu"${RESET}

  ${BOLD}✏  Edit${RESET} — change something on an existing page
    ${DIM}"Make the hero headline 20% smaller"${RESET}
    ${DIM}"Change the burgundy color to navy"${RESET}
    ${DIM}"Replace the placeholder form with Fluent Forms id=1"${RESET}

  ${BOLD}🔍  Reference${RESET} — inspect what's there
    ${DIM}"Show me my current global colors"${RESET}
    ${DIM}"List the pages on my site"${RESET}
    ${DIM}"What's on the contact page?"${RESET}

  ${BOLD}🧭  Explore${RESET} — figure out what's possible
    ${DIM}"What can you do with my Elementor site?"${RESET}
    ${DIM}"/siteagent-elementor-studio"  (Claude will ask which mode you want)${RESET}

  ${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}

  ${BOLD}Reference:${RESET}
    Skill file: ~/.claude/skills/siteagent-elementor-studio/SKILL.md
    MCP plugin: https://github.com/Digitizers/elementor-mcp

EOF
