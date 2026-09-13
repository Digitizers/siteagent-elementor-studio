# Changelog

All notable changes to the siteagent-elementor-studio skill kit are documented here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/),
and the kit is versioned via the `version:` field in `files/SKILL.md`.

## 1.5.0 — 2026-09-13

Security hardening of `setup-elementor-mcp.sh`, from the ClawHub audit of 1.4.0.
AIG rated three of these High.

- **The downloaded plugin zip is verified before it is unpacked.** The script
  installs and activates that archive as PHP on a WordPress site, so it now
  compares it against the sha256 the release API reports for the asset and
  aborts on a mismatch, with nothing installed. Be clear about what this is and
  is not: the digest travels in the same response as the URL, so it proves
  **integrity, not provenance** — a compromised release would publish a matching
  digest for a malicious asset. `EMCP_EXPECTED_SHA256` takes a digest obtained
  out of band, which is the provenance check. A release that publishes no digest
  is installed with an explicit warning rather than silently.
- **Plaintext `http://` to a non-local host is refused.** A live run sends a
  reusable application password on every request. `WP_ALLOW_HTTP=host` (comma
  separated) permits named hosts. Same rule, same reasoning, as
  wordpress-api-pro 3.9.5.
- **"Local" means a loopback ADDRESS, not a suffix.** `.local` is mDNS:
  `wordpress.local` commonly resolves to another machine on the LAN, so
  exempting the suffix sent the application password across a real network in
  the clear - and past any proxy - while reporting the host as local. An IP
  literal is now read directly, a name is resolved, and every address it
  resolves to must be loopback; `localhost` and `*.localhost` are loopback by
  RFC 6761 and need no lookup. **This is a behaviour change for live-host
  mode:** a `.local` or `.test` URL that does not resolve to loopback now needs
  an explicit `WP_ALLOW_HTTP` entry. Local-by-Flywheel is unaffected — it writes
  its sites into `/etc/hosts` at 127.0.0.1, and choosing Local mode sets the
  proxy-bypass flag on its own regardless of the domain the site carries.
- **`.mcp.json` is created mode 600 before the credential is written to it.**
  Writing first and fixing permissions afterwards leaves a window where the file
  is world-readable on a shared machine.
- **The suggested config printed when the file is not written no longer contains
  the credential.** It went to the terminal, the scrollback and any screen share;
  the Basic value is now replaced by a placeholder with the command to produce it.

The helpers behind these guards are unit-tested through the script's
`--self-test-fn` hook, the same convention `new-client.sh` uses
(`tests/setup-guards.bats`).

**Windows status: implemented, not verified.** Git Bash on NTFS does not
implement POSIX mode bits, so the credential file is restricted there with
`icacls /inheritance:r /grant:r <user>:F` (with `MSYS_NO_PATHCONV` /
`MSYS2_ARG_CONV_EXCL` set, or Git Bash rewrites the switches into paths). None
of that has been executed on a Windows machine - the POSIX path is tested, the
Windows branch is covered only by structural tests that the branching and the
argument guards are in place. Unverified there: that icacls accepts `$USERNAME`
as a principal, that `cygpath -w` yields a path it parses, and that `mv`
preserves our ACL over an existing file. One Git Bash run would settle all
three.

## 1.4.0 — 2026-07-21

- **Committed `.mcp.json`** (secrets as placeholders only) — the `elementor` connection now
  comes up from env vars alone: `WP_URL` / `WP_USERNAME` / `WP_APP_PASSWORD` (the same trio
  `wordpress-api-pro` reads) drive the `@msrbuilds/emcp-proxy` bridge via `npx`. claude.ai
  cloud environments (which load the repo's `.mcp.json` from the clone and inject env vars
  from the environment config) and devices with the vars in their shell get the Elementor
  tools with no per-machine setup. The `${VAR:-}` defaults keep the config parseable when the
  vars are unset — the connection then just shows as unavailable until they're provided (a
  bare unset `${VAR}` would fail the whole config parse, per the Claude Code docs — Codex
  round-1 P2). Real credentials never enter the tracked file. `.claude/settings.json` sets
  `enableAllProjectMcpServers` so the committed config is auto-approved once the folder is
  trusted — untrusted checkouts deliberately ignore the committed key (v2.1.196+) and
  prompt once.
- The proxy launch is **version-pinned** (`@msrbuilds/emcp-proxy@1.9.1`), not `@latest` —
  the config is auto-approved and receives WordPress credentials, so an unpinned latest
  would be a standing supply-chain risk; bump the pin deliberately (Codex round-1 P1).
- **Both `.mcp.json` writers now refuse to write credentials into a tracked placeholder
  config** (Codex round-1 + round-2 P2): the interactive wizard, run inside this repo's
  checkout, would previously have untracked the committed config (`git rm --cached`) and
  replaced it with a real-credential file; the non-interactive `new-client.sh`
  (`--project-dir` at a checkout) would have overwritten it outright, putting the
  Basic-auth credential straight into `git diff`. Both now detect the tracked placeholder
  (`"WP_URL": "${WP_URL` marker + `git ls-files`) and point to the env-var route or a
  separate per-site project directory; everywhere else they keep writing the git-ignored
  per-project config as before.
- **Honest wizard outcome + first-session routing for the placeholder case** (Codex
  round-3 P2s): when the interactive wizard skips the write because of the tracked
  placeholder, it no longer prints "Setup complete → approve the server" (nothing was
  configured — credentials lived only in shell variables); it now ends with the exact
  `export WP_URL/WP_USERNAME/WP_APP_PASSWORD` lines to finish the connection, and stops
  suggesting a Basic-auth config to paste. SKILL.md's first-session predicate no longer
  treats the mere existence of `.mcp.json` as a connection — a placeholder config with
  unset env vars routes to the env-var fix or a separate per-site directory.

## 1.3.3 — 2026-07-21

- First-session setup now resolves `setup-elementor-mcp.sh` from the **loaded
  skill's own directory** (plugin/marketplace installs bundle it there), with
  `~/.claude/scripts/setup-elementor-mcp.sh` kept as the manual-install
  fallback — plugin users previously hit "file not found" because only
  `INSTALL.sh` creates the home-directory copy. README cross-references
  clarified to match.

## 1.3.2 — 2026-07-08

- Reconcile the `detect-elementor-version` guidance in `files/SKILL.md`: the Pro-detection section no longer tells the agent the tool "errors in v1.5.0" / "the buggy version tool" — that schema bug is fixed on current builds (as the Setup-gotchas + call-it sections already stated). The **tool-presence check remains the definitive Pro-vs-Free signal**; `detect-elementor-version` is usable but reports atomic/version support, not a Pro flag. Removes the internal contradiction. No skill-behavior change.

## 1.3.1 — 2026-07-08

- Refresh `references/engine-and-premium.md` (and the SKILL.md engine line) to current facts: the fork is **v1.24.0**, **up to 118 tools**, and — since **v1.22.0** — carries **no Freemius / no hosted marketplace / no phone-home**. Corrects the stale "v1.9.0 / 94 tools / Freemius auto-update" text, documents the v1.13–v1.24 capability surface (design-system CRUD, governed page + design-token writes, schema-in-error, numeric-range hints), and updates the fork-vs-upstream-Premium (`emcp-pro` 3.0.0) comparison. No skill-behavior change.

## 1.3.0 — 2026-07-08

Capability upgrade — teaches the fork's v1.14–v1.23 contract surface (all claims source-verified against `Digitizers/elementor-mcp`). Four additions:

- **Responsive value rules.** New "Responsive values" section in `SKILL.md`: classic widgets take per-breakpoint values as **suffixed keys** (`typography_font_size_tablet`, `align_mobile`) on the same base control with the same value shape; the suffix set is **breakpoint-dependent** (derives from Elementor's active breakpoints — `_tablet`/`_mobile` plus `_widescreen`/`_laptop`/custom, not a fixed list). Atomic (V4) responsive is **variants**, not suffixes — documented in `references/atomic-v4.md`.
- **`settings.classes` wiring for atomic local styles.** `references/atomic-v4.md` now explains the two coupled pieces — the typed `settings.classes` reference list **and** the separate top-level `styles` map that defines each class — the rule that every class id must resolve (local style def or Global Class `g-` id), that the local `styles` map is built **at creation** (`add-atomic-*` / `add-flexbox` / the universal `add-atomic-widget`), and that `update-atomic-widget` merges `settings` only — it can change `settings.classes` references but **cannot** write the `styles` map, so restyle by recreating or via a Global Class.
- **New `references/v3-to-v4-conversion.md`** — rebuilding a classic (V3) design on the atomic (V4) engine: the classic→atomic tool map, never-mix rule, `$$type` envelope cross-reference, styling parity (local styles vs. Global Classes / Variables), a worked hero example, and a conversion checklist.
- **New v1.14–v1.23 fork surface.** New `references/design-system-crud.md` documents the Elementor 4 design-system CRUD tools — Global Classes (`create-/update-/delete-/apply-global-class`), Variables (`list-/get-/create-/edit-/delete-/restore-variable`), and Interactions (`list-/add-/edit-/delete-interaction`), calling out `restore-variable` + `edit-interaction` as fork-superset capabilities, with Pro gating, caps, and permissions. New `references/error-recovery.md` covers governance errors (`governance_grant_required`/`_grant_invalid`/`_render_failed`/`_rollback_failed` — all opt-in, with retry semantics), schema-in-error recovery loops (`invalid_widget_type`/`widget_not_found` inline suggestions; atomic `save_rejected` inline prop schema), and `get-widget-schema` numeric range hints (`minimum`/`maximum`/`multipleOf`, slider unit enums). `SKILL.md` gains focused sections linking out to all three.

## 1.2.1 — 2026-07-08

- Fix the skill's H1 title in `files/SKILL.md` (`# Elementor Pro Studio Skill` → `# SiteAgent Elementor Studio Skill`) — a leftover from before the rename that ClawHub renders as the listing header. Also aligns the ClawHub publish display name to **"SiteAgent Elementor Studio"**. No functional change.

## 1.2.0 — 2026-07-07

- **Renamed: `claude-elementor-pro` → `siteagent-elementor-studio`.** The kit's brand tokens (repo name, install URLs, README title) **and the skill's own invocation name** (`elementor-pro-studio` → `siteagent-elementor-studio`) are rebranded, avoiding the trademark overlap of a name that stacked "Claude" and "Elementor **Pro**" (Elementor's flagship product). Descriptive references — "for Claude Code", Anthropic attribution, Elementor **Pro**-compatibility badges, and the `emersimeon/claude-elementor-kit` upstream credit — are unchanged (nominative/descriptive use).
- **Upgrade note (1.1.x → 1.2.0):** the skill now installs to `~/.claude/skills/siteagent-elementor-studio` and is invoked as `/siteagent-elementor-studio` (previously `elementor-pro-studio`). `INSTALL.sh`/`INSTALL.ps1` detect and offer to remove the prior `elementor-pro-studio` (and older `elementor-mcp`) skill directories so Claude doesn't load two copies. The old GitHub URL redirects.

## 1.1.2 — 2026-06-14

Security hardening (ClawHub audit — siteagent-elementor-studio 1.1.1):
- Read the WordPress application password silently (`read -rs`) so it no longer echoes to the terminal.
- Removed the username-enumeration fallback on auth failure (generic error instead).
- Declared the skill's shell/network/filesystem/env permissions in SKILL.md; noted shell/setup runs only on explicit confirmation.
- `.mcp.json` credential file is now git-ignored on write with a rotation/least-privilege warning.
- Framed companion tooling (content/SEO/media/ACF/Woo) as optional, opt-in, separately-credentialed.
- Added an optional `EMCP_PIN_VERSION` to pin the plugin release (default remains latest from the trusted Digitizers fork over HTTPS).

## 1.1.1 — 2026-06-13

- Point all operational references at our fork `Digitizers/elementor-mcp` (the Elementor 4.x-correct engine the skill drives); msrbuilds/elementor-mcp is retained as end-credit attribution only.
- Fix the post-install prompt to say `/siteagent-elementor-studio` (was still `/elementor-mcp`).
- `publish-clawhub.yml` dry-run now calls the real `clawhub skill publish --dry-run` (confirmed a genuine CLI flag) instead of just echoing the command.

## 1.1.0 — 2026-06-12

- Renamed the skill's invocation name to `siteagent-elementor-studio` (OpenClaw-neutral) and published to ClawHub under "Elementor Pro Studio". The GitHub repo remains `siteagent-elementor-studio`.
- Added a ClawHub publish workflow.

## [1.0.1] - 2026-07-03

Addresses Codex review findings across the installers and reference docs.

### Fixed

- **`new-client.sh` (HIGH):** live-host onboarding now copies the plugin zip to a
  durable path (`$PROJECT_DIR`, else `$HOME`) **before** aborting. The `EXIT` trap
  (`rm -rf "$WORK"`) previously deleted the zip the instant the script aborted, so the
  printed upload instructions pointed at an already-gone file.
- **`references/recipes.md` FAQ (HIGH):** dropped the "a mixed page is fine" guidance,
  which contradicted the never-mix rule (a classic accordion on a V4/atomic page does
  not persist). The div-block + `<details>` atomic pattern is now the only documented
  V4 path for the FAQ recipe.
- **`new-client.sh` (MED):** a local plugin-install failure is now fatal (`abort`),
  and the route check is fatal after an attempted install — no more false
  "Client ready" with a broken `.mcp.json`.
- **`setup-elementor-mcp.sh` (MED):** the MCP install step now supports Linux Local
  data roots (`~/.config/Local`, `~/.local/share/Local`) and app-resource paths,
  falling back to a clear manual-upload flow when the bundled WP-CLI toolchain can't be
  located — instead of resolving the site then aborting on macOS-only paths.
- **`setup-elementor-mcp.sh` (MED):** reinstall no longer skips solely because a
  generic `mcp` namespace is present. It now detects the old `mcp-adapter` +
  upstream `elementor-mcp` pair (standalone adapter plugin, or a pre-fork version)
  and offers to (re)install the bundled Digitizers fork over it.
- **`setup-elementor-mcp.sh` (P1, Codex follow-up):** accepting that (re)install no
  longer just warns and installs the fork on top of the old setup. A new
  `remove_plugin` helper deactivates + deletes the standalone `mcp-adapter` plugin
  via REST and re-verifies (via `refresh_plugins_json` + `plugin_is_installed`) that
  it's actually gone before the fork install proceeds. If REST removal fails, the
  script pauses in a recheck loop (or aborts on request) instead of ever installing
  the bundled fork alongside the still-present standalone adapter — which would
  double-load the MCP transport and break the route.
- **`references/recipes.md` Contact (MED):** added an `*Atomic/V4*` variant — a
  Fluent Forms shortcode dropped via `add-atomic-widget`, flagging that the native Pro
  Form widget isn't V4-ready.
- **`references/atomic-v4.md` (LOW):** clarified that "pass simple flat values" applies
  to the dedicated atomic helper tools; the universal `add-atomic-widget` /
  `update-atomic-widget` escape hatch needs raw `$$type`-shaped settings (flat values
  there are saved as empty/ignored).
- **`setup-elementor-mcp.sh` + `new-client.sh` (LOW):** a leading `~` in a resolved
  Local path from `sites.json` is now expanded to `$HOME` before the `wp-config.php`
  probe, which otherwise looked for a literal `~/...` directory and aborted.

## [1.0.0]

- Initial release of the SiteAgent Elementor Studio skill kit.
