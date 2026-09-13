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

@test "local dev hosts stay allowed over http" {
  for url in http://mysite.local http://localhost:10004 http://127.0.0.1 http://foo.test http://bar.localhost; do
    fn http_verdict "$url"
    [ "$output" = "local" ] || { echo "failed for $url: $output"; return 1; }
  done
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
  fn http_verdict "http://admin@mysite.local/"
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
  run bash -c "grep -n 'Could not read a host from' '$SCRIPT'"
  [ "$status" -eq 0 ]
  # it must run before http_verdict's refusal, whose hint names WP_ALLOW_HTTP -
  # advice that cannot work for a URL with no host to name
  host_line=$(grep -n 'Could not read a host from' "$SCRIPT" | head -1 | cut -d: -f1)
  verdict_line=$(grep -n 'case "$(http_verdict "$SITE_URL")" in' "$SCRIPT" | head -1 | cut -d: -f1)
  [ "$host_line" -lt "$verdict_line" ]
}

@test "Local mode bypasses the proxy whatever domain the site carries" {
  # A Local site with a custom domain (project.dev from sites.json) is not in
  # is_local_host's suffix list, so testing the URL alone left the common mode
  # talking to its site through a configured proxy.
  fn http_verdict "http://project.dev"
  [ "$output" = "refused" ]
  run bash -c "sed -n '/^SITE_IS_LOCAL=no/,+1p' '$SCRIPT'"
  [[ "$output" == *'"$MODE" = "local"'* ]]
}
