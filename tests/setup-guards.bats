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
