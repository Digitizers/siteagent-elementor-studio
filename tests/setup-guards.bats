#!/usr/bin/env bats
# Unit tests for setup-elementor-mcp.sh's safety helpers, via its
# --self-test-fn hook. Findings from the ClawHub audit of 1.4.0 (AIG rated
# three of them High).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/files/setup-elementor-mcp.sh"
}

fn() { run bash "$SCRIPT" --self-test-fn "$@" </dev/null; }

# ---- http_verdict: a live run sends a reusable app password on every request --
@test "https needs no decision" {
  fn http_verdict https://example.com
  [ "$output" = "ok" ]
}

@test "plaintext http to a public host is refused" {
  fn http_verdict http://example.com
  [ "$output" = "refused" ]
}

@test "loopback hosts stay allowed over http" {
  # RFC 6761 names and loopback literals need no lookup
  for url in http://localhost:10004 http://127.0.0.1 "http://[::1]/" http://bar.localhost; do
    fn http_verdict "$url"
    [ "$output" = "local" ] || { echo "failed for $url: $output"; return 1; }
  done
}

@test "a suffix alone is not evidence of locality" {
  # ".local" is mDNS: wordpress.local commonly resolves to another machine on
  # the LAN. Treating the suffix as local waived the plaintext refusal AND
  # bypassed proxies, sending the application password over a real network.
  for url in http://wordpress.local http://foo.test; do
    fn http_verdict "$url"
    [ "$output" = "refused" ] || { echo "failed for $url: $output"; return 1; }
  done
}

@test "a name that merely resolves to loopback is not enough" {
  # .mcp.json persists the HOSTNAME, and the MCP server resolves it again on
  # every later request - so a lookup during setup proves nothing about them. A
  # hosts entry removed, an mDNS answer changed, a rebinding record, and the
  # credential travels in the clear with the opt-in never asked for.
  h=$(awk '$1=="127.0.0.1" && $2 ~ /\.local$/ {print $2; exit}' /etc/hosts)
  [ -n "$h" ] || skip "no 127.0.0.1 .local entry in /etc/hosts on this machine"
  fn http_verdict "http://$h"
  [ "$output" = "refused" ]
  # and naming it is the way through
  WP_ALLOW_HTTP="$h" fn http_verdict "http://$h"
  [ "$output" = "named" ]
}

@test "locality is decided without a lookup" {
  # no network in this helper: it is pure, which is also why native Windows
  # Python's missing SIGALRM stopped being a concern here
  run bash -c "sed -n '/^is_local_host()/,/^}/p' '$SCRIPT'"
  [[ "$output" != *"getaddrinfo"* ]]
  [[ "$output" != *"python3"* ]]
}

@test "naming the host permits it" {
  WP_ALLOW_HTTP=example.com fn http_verdict http://example.com
  [ "$output" = "named" ]
}

@test "naming one host does not permit another" {
  WP_ALLOW_HTTP=staging.example.com fn http_verdict http://prod.example.com
  [ "$output" = "refused" ]
}

@test "several hosts can be listed, spaces tolerated" {
  WP_ALLOW_HTTP="a.example.com, b.example.com" fn http_verdict http://b.example.com
  [ "$output" = "named" ]
}

@test "a blanket value is not a hostname and permits nothing" {
  for blanket in 1 true yes all '*'; do
    WP_ALLOW_HTTP="$blanket" fn http_verdict http://example.com
    [ "$output" = "refused" ] || { echo "blanket $blanket allowed it"; return 1; }
  done
}

@test "host comparison ignores case, port and path" {
  fn url_host http://Example.COM:8080/wp-json/
  [ "$output" = "example.com" ]
  WP_ALLOW_HTTP=example.com fn http_verdict http://EXAMPLE.com:8080/wp-json/
  [ "$output" = "named" ]
}

# ---- redact_basic_auth: the config is printed to a terminal and scrollback ----
@test "the Basic credential never reaches the printed config" {
  run bash -c "printf '{\"Authorization\": \"Basic YWRtaW46c2VjcmV0\"}' | '$SCRIPT' --self-test-fn redact_basic_auth"
  [[ "$output" != *"YWRtaW46c2VjcmV0"* ]]
  [[ "$output" == *"<base64 of WP_USERNAME:WP_APP_PASSWORD>"* ]]
}

@test "redaction leaves the rest of the config readable" {
  run bash -c "printf '{\"url\": \"https://x/wp-json\", \"Authorization\": \"Basic AAA\"}' | '$SCRIPT' --self-test-fn redact_basic_auth"
  [[ "$output" == *"https://x/wp-json"* ]]
}

# ---- sha256_of: the zip is installed as PHP on a WordPress site ---------------
@test "sha256_of matches a known digest" {
  printf 'x' > "$BATS_TEST_TMPDIR/f"
  fn sha256_of "$BATS_TEST_TMPDIR/f"
  [ "$output" = "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881" ]
}

@test "sha256_of changes when a single byte changes" {
  printf 'x' > "$BATS_TEST_TMPDIR/a"; printf 'y' > "$BATS_TEST_TMPDIR/b"
  fn sha256_of "$BATS_TEST_TMPDIR/a"; first="$output"
  fn sha256_of "$BATS_TEST_TMPDIR/b"
  [ "$output" != "$first" ]
}

# ---- IPv6 literals (Codex, PR #32): cutting at the first colon returned "[" ---
@test "a bracketed IPv6 loopback is recognised, not truncated" {
  fn url_host "http://[::1]:8080/wp-json/"
  [ "$output" = "::1" ]
  fn http_verdict "http://[::1]:8080/wp-json/"
  [ "$output" = "local" ]
}

@test "a public IPv6 literal is still refused" {
  fn url_host "http://[2001:db8::1]/"
  [ "$output" = "2001:db8::1" ]
  fn http_verdict "http://[2001:db8::1]/"
  [ "$output" = "refused" ]
}

@test "a named IPv6 host can be allowed like any other" {
  WP_ALLOW_HTTP="2001:db8::1" fn http_verdict "http://[2001:db8::1]:8080/"
  [ "$output" = "named" ]
}

# ---- write_secret_file (Codex, PR #32): truncating first destroyed the config -
@test "the credential file lands at mode 600 with the right content" {
  target="$BATS_TEST_TMPDIR/.mcp.json"
  fn write_secret_file "$target" '{"secret":"x"}'
  [ "$status" -eq 0 ]
  [ "$(cat "$target")" = '{"secret":"x"}' ]
  [[ "$(ls -l "$target" | cut -c1-10)" == "-rw-------"* ]]
}

@test "an existing world-readable file is replaced, not left readable" {
  target="$BATS_TEST_TMPDIR/.mcp.json"
  printf 'OLD\n' > "$target"; chmod 644 "$target"
  fn write_secret_file "$target" '{"secret":"x"}'
  [ "$status" -eq 0 ]
  [[ "$(ls -l "$target" | cut -c1-10)" == "-rw-------"* ]]
}

@test "an existing config survives when the write cannot be secured" {
  dir="$BATS_TEST_TMPDIR/ro"; mkdir -p "$dir"
  target="$dir/.mcp.json"
  printf 'KEEP ME\n' > "$target"
  chmod 555 "$dir"
  fn write_secret_file "$target" '{"secret":"x"}'
  chmod 755 "$dir"
  [ "$status" -ne 0 ]
  [ "$(cat "$target")" = "KEEP ME" ]
}

@test "no temp file is left behind on failure" {
  dir="$BATS_TEST_TMPDIR/ro2"; mkdir -p "$dir"
  printf 'KEEP\n' > "$dir/.mcp.json"; chmod 555 "$dir"
  fn write_secret_file "$dir/.mcp.json" '{"secret":"x"}'
  chmod 755 "$dir"
  [ "$(find "$dir" -name '.mcp.json.*' | wc -l | tr -d ' ')" = "0" ]
}

# ---- platform split (Codex, PR #32): Git Bash on NTFS has no POSIX modes ------
@test "platform detection reports this machine correctly" {
  fn is_windows_bash
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) [ "$output" = "yes" ] ;;
    *) [ "$output" = "no" ] ;;
  esac
}

@test "the POSIX mode check is not applied on Windows" {
  # Guard the branch itself: the mode verification must sit under the non-Windows
  # arm, or every Git Bash write is rejected and the wizard is unusable there.
  run bash -c "sed -n '/^write_secret_file()/,/^}/p' '$SCRIPT'"
  [[ "$output" == *"is_windows_bash"* ]]
  [[ "$output" == *"icacls"* ]]
  # the -rw------- assertion must appear AFTER the else, not before the branch
  posix_line=$(printf '%s\n' "$output" | grep -n -- "-rw-------" | head -1 | cut -d: -f1)
  else_line=$(printf '%s\n' "$output" | grep -n "^  else" | head -1 | cut -d: -f1)
  [ -n "$posix_line" ] && [ -n "$else_line" ] && [ "$posix_line" -gt "$else_line" ]
}

@test "the icacls call is shielded from MSYS argument conversion" {
  # Git Bash rewrites /inheritance:r into a Windows path before launching a
  # native binary, so the ACL call fails without these guards (Codex, PR #32).
  run bash -c "sed -n '/^write_secret_file()/,/^}/p' '$SCRIPT'"
  [[ "$output" == *"MSYS_NO_PATHCONV=1"* ]]
  [[ "$output" == *"MSYS2_ARG_CONV_EXCL"* ]]
  # and the switches must still be single-slash: the env guards replace the
  # double-slash trick rather than combining with it
  [[ "$output" == *"icacls \"\$_win\" /inheritance:r /grant:r"* ]]
}

# ---- userinfo (Codex, PR #32): a real bypass of the plaintext guard ----------
@test "userinfo cannot impersonate a local host" {
  fn url_host "http://localhost:x@remote.example/"
  [ "$output" = "remote.example" ]
  fn http_verdict "http://localhost:x@remote.example/"
  [ "$output" = "refused" ]
}

@test "a bare user@ prefix is stripped too" {
  fn url_host "http://user@evil.example/"
  [ "$output" = "evil.example" ]
}

@test "userinfo before a genuinely local host still reads as local" {
  fn http_verdict "http://admin@localhost/"
  [ "$output" = "local" ]
}

@test "an @ in the path is not mistaken for userinfo" {
  fn url_host "https://example.com/path@nothost"
  [ "$output" = "example.com" ]
}

@test "userinfo before an IPv6 literal is handled" {
  fn url_host "http://user@[::1]:8080/"
  [ "$output" = "::1" ]
}

# ---- proxies (Codex, PR #32): the local exemption assumes no wire -----------
@test "site requests go through site_curl, not bare curl" {
  # The local exemption rests on the traffic staying on the machine; a
  # configured http_proxy would send the authenticated request over a real
  # network in plaintext.
  run bash -c "grep -c 'site_curl -s' '$SCRIPT'"
  [ "$output" -ge 13 ]
  run bash -c "grep -n 'curl -s -u \"\$WP_USER' '$SCRIPT' | grep -v site_curl | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "site_curl bypasses the proxy only for a local site" {
  run bash -c "sed -n '/^site_curl()/,/^}/p' '$SCRIPT'"
  [[ "$output" == *"SITE_IS_LOCAL"* ]]
  [[ "$output" == *"--noproxy"* ]]
}

# ---- authority separators (Codex, PR #32): same bypass, different character --
@test "a query marker cannot smuggle a local host" {
  fn url_host "http://evil.example?@localhost"
  [ "$output" = "evil.example" ]
  fn http_verdict "http://evil.example?@localhost"
  [ "$output" = "refused" ]
}

@test "a fragment marker cannot either" {
  fn url_host "http://evil.example#@localhost"
  [ "$output" = "evil.example" ]
  fn http_verdict "http://evil.example#@localhost"
  [ "$output" = "refused" ]
}

@test "a legitimate query string with an @ is unaffected" {
  fn url_host "https://example.com/a?b=@c"
  [ "$output" = "example.com" ]
}

@test "the proxy-bypass flag is set where both modes converge" {
  # Setting it only in the live-host branch left every Local-by-Flywheel run -
  # the common case - talking to its site through a configured proxy.
  run bash -c "grep -n 'SITE_IS_LOCAL=' '$SCRIPT' | grep -v 'SITE_IS_LOCAL:-no'"
  [[ "$output" == *"SITE_IS_LOCAL=no"* ]]
  # it must be computed before the connectivity step, which both modes reach
  set_line=$(grep -n '^SITE_IS_LOCAL=no' "$SCRIPT" | cut -d: -f1)
  probe_line=$(grep -n '3/8  Connectivity' "$SCRIPT" | cut -d: -f1)
  [ "$set_line" -lt "$probe_line" ]
}


# ---- an unreadable authority (Codex, PR #32 round 7) -------------------------
@test "an empty host is refused, not read as an allowlist match" {
  # "http:///remote.example" leaves no host, and an empty host is a substring of
  # the allowlist's own separators - ",," contains ",," - so it matched as
  # explicitly named while curl normalised the URL to remote.example.
  fn url_host "http:///remote.example"
  [ "$output" = "" ]
  fn http_verdict "http:///remote.example"
  [ "$output" = "refused" ]
}

@test "an empty host stays refused whatever the allowlist holds" {
  WP_ALLOW_HTTP=a.example fn http_verdict "http:///remote.example"
  [ "$output" = "refused" ]
  # an empty ENTRY cannot open the hole from the other side either
  WP_ALLOW_HTTP="a.example,,b.example" fn http_verdict "http:///x"
  [ "$output" = "refused" ]
}

@test "a scheme with no authority at all is refused" {
  fn http_verdict "http://"
  [ "$output" = "refused" ]
}

@test "a named host still matches after the empty-host guard" {
  WP_ALLOW_HTTP=a.example fn http_verdict "http://a.example"
  [ "$output" = "named" ]
}

@test "the live-host branch rejects a URL with no readable host" {
  run bash -c "grep -n 'Could not read a hostname from' '$SCRIPT'"
  [ "$status" -eq 0 ]
  # it must run before http_verdict's refusal, whose hint names WP_ALLOW_HTTP -
  # advice that cannot work for a URL with no host to name
  host_line=$(grep -n 'Could not read a hostname from' "$SCRIPT" | head -1 | cut -d: -f1)
  # the LIVE-HOST verdict, not the Local-mode one that now precedes it
  verdict_line=$(grep -n 'case "$(http_verdict "$SITE_URL")" in' "$SCRIPT" | tail -1 | cut -d: -f1)
  [ "$host_line" -lt "$verdict_line" ]
}

@test "the proxy bypass is decided for both modes at one place" {
  # It used to be set in the live-host branch alone, which left every
  # Local-by-Flywheel run talking to its site through a configured proxy; then
  # it keyed on MODE=local, which trusted a domain out of Local's metadata
  # rather than checking it. It is now one evidence test, reached by both modes.
  fn http_verdict "http://project.dev"
  [ "$output" = "refused" ]
  set_line=$(grep -n '^SITE_IS_LOCAL=no' "$SCRIPT" | cut -d: -f1)
  probe_line=$(grep -n '3/8  Connectivity' "$SCRIPT" | cut -d: -f1)
  [ "$set_line" -lt "$probe_line" ]
}

# ---- inherited ACLs and retry hints (Codex, PR #32 round 8) ------------------
@test "a credential file is written with no inherited ACL" {
  # A temp file created in a directory carrying an inheritable ACL inherits its
  # entries, and chmod does not touch them - another principal could read the
  # reusable Basic credential while ls -l still read -rw-------.
  [ "$(uname -s)" = "Darwin" ] || skip "needs BSD chmod +a / ls -le"
  d="$BATS_TEST_TMPDIR/acl"
  mkdir -p "$d"
  chmod +a "everyone allow read,readattr,file_inherit" "$d" || skip "cannot set an ACL here"
  # the inheritance is real: an ordinary file created here picks the ACE up
  touch "$d/witness"
  [ "$(ls -le "$d/witness" | wc -l | tr -d ' ')" -gt 1 ]
  run bash "$SCRIPT" --self-test-fn write_secret_file "$d/.mcp.json" '{"x":1}' </dev/null
  [ "$status" -eq 0 ]
  [ "$(ls -le "$d/.mcp.json" | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$(ls -l "$d/.mcp.json" | cut -c1-10)" == "-rw-------" ]]
}

@test "the ACL check lists entries rather than trusting the flag character" {
  # On macOS ls -l shows "+" for an ACL but "@" for extended attributes, and
  # only ONE of them - com.apple.provenance is set on ordinary new files there,
  # so an inherited ACL routinely hides behind "@".
  run bash -c "sed -n '/^write_secret_file()/,/^}/p' '$SCRIPT'"
  [[ "$output" == *"ls -le"* ]]
  [[ "$output" == *"chmod -N"* ]]
  [[ "$output" == *"setfacl -b"* ]]
}

@test "retry hints name the script's real path" {
  # The wizard runs as `bash "<skill-dir>/setup-elementor-mcp.sh"` from the
  # user's PROJECT directory, so a hint reading `bash setup-elementor-mcp.sh`
  # cannot be copied and run - the file is not in that directory.
  run bash -c "grep -nE '(bash|\\./)[^\"]*setup-elementor-mcp\\.sh' '$SCRIPT' | grep -v '^\\s*[0-9]*:#' | grep -v 'SELF'"
  [ -z "$output" ]
  run bash -c "grep -c 'bash \\\\\"\$SELF\\\\\"' '$SCRIPT'"
  [ "$output" -ge 2 ]
}

@test "the script resolves its own path before anything can change directory" {
  self_line=$(grep -n '^SELF=' "$SCRIPT" | head -1 | cut -d: -f1)
  [ -n "$self_line" ]
  run bash -c "sed -n '${self_line},+1p' '$SCRIPT'"
  [[ "$output" == *'PWD'* ]]
  # nothing may cd before it
  cd_line=$(grep -n '^[[:space:]]*cd ' "$SCRIPT" | head -1 | cut -d: -f1)
  [ -z "$cd_line" ] || [ "$self_line" -lt "$cd_line" ]
}

@test "a directory at the config path is refused, not written into" {
  # `mv -f tmp somedir` moves INTO the directory: the helper would return 0, the
  # wizard would report the config written, Claude would find nothing at that
  # path, and the credential would sit in a file inside the directory.
  d="$BATS_TEST_TMPDIR/dir-target"
  mkdir -p "$d/.mcp.json"
  run bash "$SCRIPT" --self-test-fn write_secret_file "$d/.mcp.json" '{"x":1}' </dev/null
  [ "$status" -eq 7 ]
  [ -z "$(ls -A "$d/.mcp.json")" ]
  # the wizard must have a message for it rather than falling through the case
  run bash -c "grep -c '7) abort' '$SCRIPT'"
  [ "$output" -ge 1 ]
}

@test "the base64 hint cannot emit a wrapped credential" {
  # GNU base64 wraps at 76 columns, so a long user:password pair comes back on
  # several lines and pasting it into the JSON yields an invalid config.
  run bash -c "grep -nE '\| *base64' '$SCRIPT' | grep -v \"tr -d\""
  [ -z "$output" ]
  # and the value the wizard itself computes never wraps: python3's b64encode
  # emits one line by construction, unlike the base64(1) the hint shells out to
  run bash -c "grep -c 'base64.b64encode' '$SCRIPT'"
  [ "$output" -ge 1 ]
}

@test "the loopback test fails closed" {
  for h in definitely-no-such-host-98f3a1.invalid 1.1.1.1 "" softlab.local foo.test; do
    fn is_local_host "$h"
    [ "$output" = "no" ] || { echo "failed for ${h:-<empty>}: $output"; return 1; }
  done
}

# ---- host shape (Codex, PR #32 round 10) ------------------------------------
@test "a host with shell metacharacters is refused, not reflected" {
  # The refusal reflects the host into a command the user is invited to copy,
  # so "http://foo;printf PWNED" offered `WP_ALLOW_HTTP=foo;printf pwned bash ...`
  fn valid_host "foo;printf pwned"
  [ "$output" = "no" ]
  fn valid_host 'foo$(id)'
  [ "$output" = "no" ]
  fn http_verdict "http://foo;printf PWNED"
  [ "$output" = "refused" ]
}

@test "ordinary hosts and IP literals pass the shape test" {
  for h in example.com 127.0.0.1 x_y.local 2001:db8::1 sub.domain.co.uk; do
    fn valid_host "$h"
    [ "$output" = "yes" ] || { echo "failed for $h: $output"; return 1; }
  done
}

@test "the copyable hint quotes the host" {
  run bash -c "grep -c \"WP_ALLOW_HTTP='\" '$SCRIPT'"
  [ "$output" -ge 1 ]
}

@test "loopback literals are answered directly" {
  for h in 127.0.0.1 127.1.2.3 ::1 0.0.0.0 localhost bar.localhost; do
    fn is_local_host "$h"
    [ "$output" = "yes" ] || { echo "failed for $h: $output"; return 1; }
  done
}

@test "a NAME that merely starts with 127. is not a loopback literal" {
  # curl resolves "127.attacker.example" through DNS like any other host; the
  # glob 127.* waived it past the plaintext refusal and the proxy bypass.
  for h in 127.attacker.example 127.0.0.1.evil.com 1270.0.0.1 127.0.0.256 127.0.0 127.0.0.1a; do
    fn is_local_host "$h"
    [ "$output" = "no" ] || { echo "failed for $h: $output"; return 1; }
  done
  fn http_verdict "http://127.attacker.example"
  [ "$output" = "refused" ]
}

@test "the whole of 127.0.0.0/8 is still local" {
  for h in 127.0.0.1 127.1.2.3 127.255.255.255; do
    fn is_local_host "$h"
    [ "$output" = "yes" ] || { echo "failed for $h: $output"; return 1; }
  done
}

# ---- ClawHub audit of 1.5.0 --------------------------------------------------
@test "a Local domain is trusted only with a loopback entry in /etc/hosts" {
  # Local writes its sites into /etc/hosts at 127.0.0.1; a name with no such
  # entry is left to DNS/mDNS, where any responder on the LAN can answer.
  h=$(awk '$1=="127.0.0.1" && $2 ~ /\.local$/ {print $2; exit}' /etc/hosts)
  if [ -n "$h" ]; then
    fn hosts_maps_to_loopback "$h"
    [ "$output" = "yes" ]
  fi
  for miss in no-such-host-4b1c9a.local example.com ""; do
    fn hosts_maps_to_loopback "$miss"
    [ "$output" = "no" ] || { echo "failed for ${miss:-<empty>}: $output"; return 1; }
  done
}

@test "EVERY mapping for the name must be loopback" {
  # The resolver hands curl all of a name's addresses and curl tries the next
  # one when a connection fails, so a name with both 127.0.0.1 and a LAN address
  # reaches the LAN the moment the local site is stopped - with the proxy
  # bypassed and the plaintext refusal waived. Stopping at the first loopback
  # match answered "yes" for exactly that host.
  hf="$BATS_TEST_TMPDIR/hosts"
  cat > "$hf" <<'HOSTS'
127.0.0.1 both.local
192.168.1.50 both.local
127.0.0.1 pure.local
::1 pure.local
10.0.0.5 lan.local
127.0.0.1 commented.local # trailing comment
# 127.0.0.1 disabled.local
127.0.0.256 bad256.local
127.invalid badname.local
127.0.0 short.local
127.1.2.3 highoctet.local
127.00.0.1 lead0.local
127.008.0.1 lead8.local
HOSTS
  for case in "both.local:no" "pure.local:yes" "lan.local:no" \
              "commented.local:yes" "disabled.local:no" "absent.local:no" \
              "bad256.local:no" "badname.local:no" "short.local:no" \
              "highoctet.local:yes" "lead0.local:no" "lead8.local:no"; do
    fn hosts_maps_to_loopback "${case%%:*}" "$hf"
    [ "$output" = "${case##*:}" ] || { echo "failed for $case: got $output"; return 1; }
  done
}

@test "a 127. PREFIX is not a loopback address" {
  # the third time this exact mistake appeared in this file: a name like
  # 127.invalid or 127.0.0.256 is not an address at all, so the resolver
  # ignores that line and may fall through to DNS - while a prefix match called
  # the host local, bypassed the proxy and waived the plaintext refusal
  run bash -c "sed -n '/^hosts_maps_to_loopback()/,/^}/p' '$SCRIPT'"
  [[ "$output" == *"function is_loopback"* ]]
  [[ "$output" != *'$1 !~ /^127\./'* ]]
}

@test "Git Bash reads the Windows resolver file" {
  # Local updates %WINDIR%\System32\drivers\etc\hosts there; MSYS's /etc/hosts
  # is not guaranteed to be it, so reading it would report a legitimate Local
  # domain as unmapped and abort. (Windows: implemented, not verified.)
  run bash -c "sed -n '/^hosts_maps_to_loopback()/,/^}/p' '$SCRIPT'"
  [[ "$output" == *"is_windows_bash"* ]]
  [[ "$output" == *"cygpath"* ]]
  [[ "$output" == *"System32/drivers/etc/hosts"* ]]
}

@test "a CRLF hosts file still matches its last field" {
  # The Windows resolver file is CRLF, so the last field arrives as
  # "site.local\r" and never matched - reporting a legitimate Local mapping as
  # absent and aborting the run, which pushes the user toward WP_ALLOW_HTTP.
  hf="$BATS_TEST_TMPDIR/win-hosts"
  printf '127.0.0.1 crlf.local\r\n127.0.0.1 crlf2.local other.local\r\n' > "$hf"
  for h in crlf.local crlf2.local other.local; do
    fn hosts_maps_to_loopback "$h" "$hf"
    [ "$output" = "yes" ] || { echo "failed for $h: $output"; return 1; }
  done
}

@test "the hosts-file argument is a test seam only" {
  # nothing in the script itself passes a second argument
  run bash -c "grep -cE 'hosts_maps_to_loopback \"[^\"]*\" +\"' '$SCRIPT'"
  [ "$output" = "0" ]
}

@test "Local mode checks its domain before sending a credential to it" {
  # wp-config.php proves the FILES are here, not that the HTTP endpoint is
  cfg=$(grep -n 'No wp-config.php at' "$SCRIPT" | head -1 | cut -d: -f1)
  chk=$(grep -n 'hosts_maps_to_loopback "\$_local_host"' "$SCRIPT" | head -1 | cut -d: -f1)
  url=$(grep -n 'ok "Site URL:   \$SITE_URL"' "$SCRIPT" | head -1 | cut -d: -f1)
  [ -n "$chk" ] && [ "$cfg" -lt "$chk" ] && [ "$chk" -lt "$url" ]
}

@test "the proxy bypass follows evidence, not the chosen mode" {
  run bash -c "grep -n 'SITE_IS_LOCAL=yes' '$SCRIPT'"
  [[ "$output" != *'"$MODE" = "local"'* ]]
  run bash -c "sed -n '/^SITE_IS_LOCAL=no/,/^fi/p' '$SCRIPT'"
  [[ "$output" == *"is_local_host"* ]]
  [[ "$output" == *"hosts_maps_to_loopback"* ]]
}

@test "an unverifiable download is refused unless opted into" {
  run bash -c "sed -n '/publishes no sha256/,/^  fi/p' '$SCRIPT'"
  [[ "$output" == *"abort"* ]]
  [[ "$output" == *"EMCP_ALLOW_UNVERIFIED"* ]]
}

@test "the recovery hint does not name a plugin the script removes" {
  run bash -c "grep -c 'reactivate both MCP plugins' '$SCRIPT'"
  [ "$output" = "0" ]
}

@test "the hosts file counts only when the resolver reads it first" {
  # glibc takes its order from /etc/nsswitch.conf: a "hosts:" line putting dns
  # or mdns before "files" means curl can get a routable address without
  # /etc/hosts being consulted at all, while a direct scan still says loopback.
  ns="$BATS_TEST_TMPDIR/ns"
  mkdir -p "$ns"
  printf 'hosts: files dns\n'                                   > "$ns/good"
  printf 'hosts: dns files\n'                                   > "$ns/dnsfirst"
  printf 'hosts: mdns4_minimal [NOTFOUND=return] files dns\n'    > "$ns/mdnsfirst"
  printf 'hosts: files mdns4 dns\n'                             > "$ns/filesfirst"
  printf 'passwd: files\n'                                      > "$ns/nohostsline"
  # an UNKNOWN source before files is not harmless: Samba's wins resolves over
  # the network, and so may the next name nobody here has heard of
  printf 'hosts: wins files dns\n'                              > "$ns/winsfirst"
  printf 'hosts: myhostname files\n'                            > "$ns/myhostfirst"
  # files can answer and still not decide it
  printf 'hosts: files [SUCCESS=continue] dns\n'                > "$ns/successcontinue"
  printf 'hosts: files [SUCCESS=merge] dns\n'                   > "$ns/successmerge"
  printf 'hosts: files [SUCCESS=continue NOTFOUND=return] dns\n' > "$ns/multikey"
  printf 'hosts: files [NOTFOUND=return] dns\n'                 > "$ns/notfound"
  printf '#hosts: dns\nhosts: files\n'                          > "$ns/commented"
  for case in "good:yes" "dnsfirst:no" "mdnsfirst:no" "filesfirst:yes" "nohostsline:yes" \
              "winsfirst:no" "myhostfirst:no" "successcontinue:no" "successmerge:no" \
              "multikey:no" "notfound:yes" "commented:yes"; do
    fn hosts_file_is_authoritative "$ns/${case%%:*}"
    [ "$output" = "${case##*:}" ] || { echo "failed for $case: got $output"; return 1; }
  done
  # absent file: macOS and the BSDs have none and resolve the hosts file first
  fn hosts_file_is_authoritative "$ns/definitely-absent"
  [ "$output" = "yes" ]
}

@test "the resolver-order check gates the real hosts file only" {
  # a caller-supplied hosts file is the test seam; nsswitch says nothing about it
  run bash -c "sed -n '/^hosts_maps_to_loopback()/,/^}/p' '$SCRIPT'"
  [[ "$output" == *"hosts_file_is_authoritative"* ]]
  [[ "$output" == *'-z "${2:-}"'* ]]
}
