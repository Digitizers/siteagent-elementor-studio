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

