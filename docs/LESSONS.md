# Elementor MCP — Lessons Learned

The traps we hit on real builds, what they look like, and how the skill + setup script handle them now. Useful when something the automation doesn't cover comes up.

**Keeping this file current.** Every client build is a field test. When one ends — or hits a compaction point — sort what was learned into one of two places:

- **A defect in the plugin** (a tool that lies, a schema that hides a capability, a write path that drops data) → a numbered field report in the `elementor-mcp` repo, indexed in its `CLAUDE.md`. Verify the claim against the source and name the file and line; a report that guesses is worse than none.
- **A working practice** (a gotcha, a convention, a technique that isn't a bug in anything) → this file, in the section it belongs to.

The test for "is this a lesson": it cost more than ten minutes, and the next build would pay it again. Sources: `docs/audits/` for anything measured, and the client build's own decision ledger.

---

## Setup-time gotchas

### 1. The Application Password's *label* is not the username

When you create a WordPress Application Password, you give it a memorable name like "ClaudeMCP". This is a **label**, not a username. The actual username for HTTP Basic auth is your WP login (`admin`, `test`, your email-derived slug, etc.).

**Symptom:** `curl -u "ClaudeMCP:..."` returns `401 Unauthorized`.
**Fix:** `curl -u "<actual-wp-username>:..."` — find via `GET /wp-json/wp/v2/users`.
**The setup script handles this** by listing public users when auth fails so you can pick the right slug.

### 2. Neither MCP plugin is on wordpress.org

Both `mcp-adapter` (WordPress org) and `elementor-mcp` (our fork, `Digitizers/elementor-mcp` — a fork of `msrbuilds/elementor-mcp`) ship only via GitHub. The WP REST API's `/wp-json/wp/v2/plugins` endpoint can install plugins by *slug* (from wp.org) but cannot install from arbitrary zip URLs.

**Workaround:** Download zips from GitHub Releases and install via WP-CLI (Local) or upload via WP Admin (live).

### 3. The elementor-mcp source zipball has a hash-suffixed folder

GitHub's auto-generated source zipballs (used when a release has no asset zip) wrap the code in a directory like `Digitizers-elementor-mcp-<sha>/`. WordPress uses this folder as the plugin slug — leading to a confused activation and broken paths.

**Fix:** Unzip, rename the folder to `elementor-mcp/`, re-zip. The setup script does this automatically.

### 4. Local-by-Flywheel `wp-config.php` says `DB_HOST=localhost` but uses a per-site Unix socket

The site is fully functional via HTTP, but WP-CLI invoked from a regular shell fails:
```
Error establishing a database connection.
```

**Fix:** Find the socket via:
```bash
find ~/Library/Application\ Support/Local/run -name 'mysqld.sock'
```

Then call PHP with both socket overrides:
```bash
php -d mysqli.default_socket=$SOCK -d pdo_mysql.default_socket=$SOCK <wp-cli> <command>
```

The setup script auto-discovers the right socket by trying each one until `wp core version` succeeds.

### 5. Local has its own bundled PHP and WP-CLI binaries

System-installed PHP/WP-CLI may not have the MySQL extensions Local's stack uses. The setup script uses Local's bundled binaries:

- PHP: `~/Library/Application Support/Local/lightning-services/php-*/bin/darwin-arm64/bin/php`
- WP-CLI: `/Applications/Local.app/Contents/Resources/extraResources/bin/wp-cli/posix/wp`

### 6. Claude Code only reads `.mcp.json` at startup

Writing the file mid-session does nothing. You must quit and reopen Claude Code in the project directory.

### 7. The `detect-elementor-version` MCP tool errors in v1.5.0

It tries to return `null` for `elementor_pro_version` but the schema declares `string`. Calling it returns a validation error. **Use `list-pages` as the smoke-test** for whether the MCP is wired correctly.

### 8. The MCP can ship with every tool disabled, and says nothing about it

A fresh install presented as **zero tools exposed**. The cause was the `elementor_mcp_disabled_tools` option holding 104 ability slugs. Nothing in the MCP handshake, the tool list, or the logs mentions that abilities were suppressed.

**Symptom:** the server connects, `list-pages` and everything else are simply absent.
**Diagnose:** `wp option get elementor_mcp_disabled_tools --format=json`
**Fix:** back the list up to the project, then `wp option update elementor_mcp_disabled_tools '[]' --format=json` and restart Claude Code (see gotcha 6 — the tool list is read at startup).

**On a client with a tight tool cap, don't clear the whole list.** Emptying it exposes the full Pro+atomic set (~113 tools), which overruns Antigravity's ~100 cap — the client silently truncates, and the tools that fall off can be the atomic essentials, turning "no tools" into the subtler "writes don't persist" (`files/SKILL.md`, the Antigravity note). There, enable the plugin's **Low-tools mode** (WP Admin → MCP Tools), whose curated set keeps the five atomic essentials under the cap, or re-enable only the slugs the job needs. Clear the list outright only on clients with no cap.

Do this *before* concluding a tool doesn't exist. On this build, `create-theme-template`, `set-template-conditions`, and `sideload-image` were all in that list, and all three jobs were done by hand before anyone checked.

**Clearing that option alone does not stick.** A seeder in `includes/admin/class-admin.php` re-disables every Pro-badged tool whenever `elementor_mcp_defaults_applied` is below its `DEFAULTS_VERSION` — deliberately, so new Pro batches ship off by default and sites stay under client tool caps. Emptying the disabled list without touching that counter leaves the seeder armed, and the next admin request silently re-disables the pack. On this site that happened during a plugin upgrade: 36 tools vanished, exactly the `pro`-badged set, and the count only came to light from an ability-vs-tool diff.

```bash
wp option get elementor_mcp_defaults_applied        # must be >= DEFAULTS_VERSION
wp option get elementor_mcp_premium_unlock_applied
```

**Order matters — clearing while the seeder is armed is what fails.** If `elementor_mcp_defaults_applied` is *below* `DEFAULTS_VERSION`, the seeder has not run yet, so let it run **first**: load any wp-admin page once (that's the request that seeds and bumps the counter), confirm the counter now matches, and *then* clear the disabled list. Clear it before that and the very next admin request re-disables the pack. After any plugin upgrade the counter can fall behind again — so the sequence is: upgrade → load wp-admin once → check the counter → clear/curate the list → restart the client → re-check the exposed tool count.

### 9. A Hebrew site locale renders the whole design RTL

`WPLANG=he_IL` flips Elementor's body direction, so an LTR design arrives mirrored — columns reversed, text right-aligned — with nothing wrong in `_elementor_data`.

**Decide by the site's own language, not by the design and not by the conversation.** `WPLANG` sets admin translations, date/number formatting, and the `lang`/`dir` the browser and screen readers read — it is not a layout switch. Two cases:

- **The site itself is English** (English content, English audience) and the locale was left Hebrew because of who set it up: the locale is simply wrong. `wp option update WPLANG en_US` fixes the label *and* the direction. This was the case on this build.
- **The site is genuinely Hebrew** and only this design is LTR: keep `he_IL` — flipping it de-localizes the whole site. Override direction where it applies (`direction:ltr;text-align:left` on the section's containers, per the tier table in the working-from-a-design-export section), and expect to fight Elementor's RTL stylesheet, which loads whenever `is_rtl()` is true.

Never change the locale to fix pixels on a site whose content is Hebrew.

### 10. Raise `WP_MEMORY_LIMIT` before building a long page

A 256M install died partway through a ~380-element page and returned 500s. Two of the failed requests **had already written their elements**, leaving duplicates that only a visual diff caught.

**Fix:** `WP_MEMORY_LIMIT` to `512M` in `wp-config.php` up front. After any 5xx during a build, re-read the structure and check for duplicates before retrying.

### 11. A theme or mu-plugin can silently win the font fight

Correct kit tokens plus correct compiled CSS still rendered the wrong font for hours. The cause was a site mu-plugin filtering `elementor/frontend/print_google_fonts` to false and forcing `font-family !important` on every Elementor element.

**Symptom:** `get-global-fonts` and the compiled `post-<id>.css` both say the right family; the browser computes another.
**Diagnose:** grep `wp-content/mu-plugins` and the active theme for `print_google_fonts` and `font-family` + `!important`, and compare the computed style in the browser against the kit.
Whenever the DB says one thing and the pixels say another, **suspect a third party before suspecting your own write.**

---

## Build-time conventions

### 1. Widget add-tools take flat params, not `settings: {}`

```js
// ✓ Correct
add-heading({
  post_id: 11,
  parent_id: "abc",
  title: "...",
  title_color: "#171615",
  typography_font_family: "Cormorant Garamond"
})

// ✗ Wrong — error: "title is a required property of input"
add-heading({
  post_id: 11,
  parent_id: "abc",
  settings: { title: "...", title_color: "#171615" }
})
```

**The exception** is `add-container`, which takes `settings: {}` because containers have so many properties. Don't generalize from one to the other.

### 2. Always set `typography_typography: "custom"` to enable typography

Without this flag, the other `typography_*` keys are silently ignored. Same for `css_filters_css_filter: "custom"` for image filters. This pattern is how Elementor distinguishes "use defaults" from "I'm explicitly setting this."

### 3. Flex container key names

The schema confirms (and issue #32 was a bug about this) that the right keys are:

- `flex_direction` — `row` | `column` | `row-reverse` | `column-reverse`
- `flex_justify_content` — `flex-start` | `center` | `flex-end` | `space-between` | `space-around` | `space-evenly`
- `flex_align_items` — `flex-start` | `center` | `flex-end` | `stretch`
- `flex_gap` — `{column, row, isLinked, unit}`
- `flex_wrap` — `nowrap` | `wrap`

Note the `flex_` prefix on `justify_content` and `align_items` — without it, the keys are dropped.

### 4. Background type must be set first

Setting `background_color: "#F4F1EA"` alone does nothing. You must first set:
```
background_background: "classic"
```
Then `background_color`, `background_image`, etc. apply. Same for `background_overlay_background: "classic"` before any `background_overlay_*` keys.

### 5. Background overlay opacity unit is `px` (yes, really)

Schema quirk:
```js
background_overlay_opacity: { unit: "px", size: 0.45 }   // 0–1 range
```
The `px` unit doesn't mean pixels — it's just what the schema declares. The numeric range is 0–1.

### 6. Italic emphasis via inline `<em>` in headings

Elementor's Heading widget renders inline HTML in the title field. So:

```js
title: "where estates <em>are entrusted</em>"
```

Cormorant Garamond's italic auto-loads if the font is set. If italics fail to render, check that **Site Settings → Global Fonts → Primary** has an italic variant available (Cormorant Garamond from Google Fonts ships italic by default).

### 7. Padding shape

```js
padding: {
  unit: "px",
  top: "200",
  right: "56",
  bottom: "200",
  left: "56",
  isLinked: false
}
```

`isLinked: true` means top=right=bottom=left (Elementor's "linked" UI control). Use `false` whenever any side differs.

### 8. The CSS-class control is named differently on containers and widgets

- **Widgets** → `_css_classes` (leading underscore)
- **Containers** → `css_classes` (no underscore)

Write `_css_classes` on a container and it stores perfectly and produces no class in the markup — every shared-hover or shared-layout rule keyed to that class then does nothing. Verified both ways on Elementor 4.2: the same probe string renders from `_css_classes` on a classic heading widget and from `css_classes` on a classic container, and each is inert under the other's key.

**Both keys are classic-element controls.** On **atomic** (v4) elements neither applies: atomic carries a typed `settings.classes` reference list whose every id must resolve to a local style definition or a Global Class (`files/references/atomic-v4.md`) — an arbitrary class name written there renders nothing at all.

This is not an MCP defect — `get-container-schema` publishes `css_classes` correctly. It is what you get for assuming the widget key generalises. Read the container schema for the key rather than carrying one over.

Per-element `custom_css` (Pro) is the other route, and the right one when the rule is unique to a single element:

```
selector{transition:transform .2s ease;}
selector:hover{transform:translateY(-4px);}
```

`selector` resolves to `.elementor-element-<id>`, so this is also how you reach pseudo-classes and media queries the controls don't expose.

### 9. Converters and imports freeze widths in pixels

Anything that translates HTML into containers writes literal `width: 320px` where the source had a grid track. The page then looks right at the design width and wrong everywhere else — cards sitting at a third of the row, not filling it.

**Free route — no CSS at all, and it's the better default.** Clear the frozen `width` on each card and set its **flex item** settings instead (child container → Layout → `flex_grow: 1`, `flex_shrink: 1`, `flex_basis: 0`, plus `min-width: 0` — see convention 14). Equal columns then fill the row at every width with no arithmetic, because flex distributes what's left *after* the parent's gap. Per-breakpoint column counts come from the parent's `flex_wrap: wrap` plus a `flex_basis` percentage on tablet/mobile (e.g. `50%` / `100%`).

**Pro route — when the columns are deliberately unequal or must hit an exact track.** Per-element `custom_css` (Pro; see the note above), which buys precision the controls don't expose:

```
selector{flex:0 0 calc((100% - 48px)/3);max-width:calc((100% - 48px)/3);min-width:0;}
@media(max-width:1024px){selector{flex:0 0 calc((100% - 24px)/2);max-width:calc((100% - 24px)/2);}}
@media(max-width:767px){selector{flex:0 0 100%;max-width:100%;}}
```

The gap total in the numerator is `(columns - 1) × gap` — the arithmetic the flex route avoids entirely. On Free + atomic, where `custom_css` isn't available, the same rules go in the Customizer's Additional CSS keyed to `.elementor-element-<id>` (tier table above). Also expect **buttons to arrive as bare text widgets** — rebuild them as real Button widgets rather than styling the text.

### 10. Container gap replaces per-child margins, and the default is not zero

A container with no `flex_gap` uses the kit default (20px), so an imported design's deliberate rhythm — 14px under the eyebrow, 28px above a badge row — flattens to one uniform number. Set `flex_gap` to the design's *smallest* recurring gap, then add `margin` on the few children that need more. Chasing it with per-widget margins alone leaves the gap underneath, doubled.

### 11. `replace-system-colors` / `replace-system-typography` are the tools you want

`update-global-colors` appends to `custom_colors` and never touches the four **system** roles that every widget's colour picker actually references — so the brand palette lands and Elementor's stock `#6EC1E4` stays bound. `replace-system-colors` and `replace-system-typography` write the system roles properly.

They're easy to miss because the name reads destructive. Reach for them first when setting up a kit.

### 12. WordPress strips gradient-text CSS out of a Heading title

A heading title accepts inline HTML, but it goes through WordPress's KSES filter, which allows only a whitelist of CSS properties. `background-clip`, `-webkit-background-clip` and `-webkit-text-fill-color` are **not** on it. Write a gradient word this way:

```html
<span style="background:linear-gradient(...);-webkit-background-clip:text;-webkit-text-fill-color:transparent;color:transparent">Word</span>
```

and what survives is `background:linear-gradient(...)` plus `color:transparent` — a solid gradient block with invisible text inside it, which is a strange enough result that you'll blame the gradient rather than the filter.

**Fix:** keep the class in the title and move the rule to a stylesheet KSES never touches. On **Pro**, that's per-element `custom_css`, which is compiled server-side and unfiltered:

```
title:      Local currency at checkout, <span class="sp-grad">Global control</span> behind it
custom_css: selector .sp-grad{background:linear-gradient(96deg,#d24d00,#ff6601 45%,#ff9440);
              -webkit-background-clip:text;background-clip:text;
              -webkit-text-fill-color:transparent;color:transparent;}
```

**On Free**, the same rule goes in **Appearance → Customize → Additional CSS** (core WordPress, unfiltered) or a child-theme stylesheet — scoped by the wrapper you can actually attach: `.sp-grad` inside the title survives KSES because it is a class attribute, not a style property, so `.sp-grad{…}` alone is usually enough; scope it with `.elementor-element-<id> .sp-grad` if the class name is reused elsewhere, remembering that the id changes if the element is rebuilt.

The same trap applies to any inline style carrying a property outside the KSES list — check the rendered markup, not the stored setting.

> **`selector` is a Pro token.** Every recipe below that writes `selector{…}` assumes per-element `custom_css`, which is Pro — Elementor expands `selector` to `.elementor-element-<id>` when it compiles the rule server-side. On **Free**, put the same rule in **Appearance → Customize → Additional CSS** (or a child-theme stylesheet) and write that selector yourself: `.elementor-element-<id>{…}`, or a class you attached — remembering the id changes if the element is rebuilt, and that on atomic elements an arbitrary class won't attach (convention 8).

### 13. `transform: scale()` shrinks the paint, not the layout

A fixed-width composition (an orbit diagram, a dashboard mock) inside a fluid column overflows on mobile. `transform:scale(.6)` looks like the fix and isn't — the element still occupies its original box, so the page keeps its horizontal scrollbar. Compensating with negative margins gets the width right and then **the composition disappears entirely**, which sends you debugging the wrong thing.

`zoom` scales layout and paint together:

```
@media(max-width:600px){selector .stage{zoom:.62;}}
```

Supported in Chrome, Safari, and Firefox 126+. For a fixed-size design asset that must stay intact, it beats reflowing.

### 14. Grid and flex children default to `min-width: auto`

This is behind a whole family of "why is this overflowing" bugs. A grid item, a flex item, or a scroll container will not shrink below its content — so `overflow-x:auto` on the container does nothing, because the container itself grew.

Add `min-width: 0` at every level between the fixed-width content and the element that should clip:

```
.tabs > *{min-width:0;}
.tablist{min-width:0;}
.panes{min-width:0;overflow-x:auto;}
```

### 15. Elementor stretches container children to full width

Below the tablet breakpoint especially, a child of a flex container gets `width:100%` from Elementor's own CSS. Symptoms seen on one header: a 150px CTA button jumping to its own row, a nav block staying 1116px wide next to a 156px logo, a 34px avatar rendering as a full-width bar.

The fix is the same every time, and `!important` is required because Elementor's rule is equally specific:

```
selector{width:auto !important;flex:0 0 auto;}
```

Reach for this the moment something that should hug its content is as wide as its parent.

### 16. `display: contents` reorders across container boundaries

When two elements that must sit side by side live in different containers — a logo and burger in one, a CTA in its sibling — you can't reorder them with `order` alone, because they aren't siblings in the flex layout.

`display:contents` on the wrapper dissolves it for layout purposes, promoting its children to the parent's flex context, where `order` then works on all of them:

```
@media(max-width:1024px){
  selector{display:contents;}            /* on the wrapper   */
}
@media(max-width:1024px){
  selector{order:3;}                     /* on each child    */
}
```

Cleaner than restructuring the tree, and it leaves the desktop layout untouched.

### 17. A design export can contain unresolved runtime bindings

Markup exported from a design tool may still carry its own template syntax — `{{ tbg0 }}`, `{{ pick0 }}`, `<sc-if value="{{ isTab0 }}">`. Lift such a block verbatim into an HTML widget and you ship `{{ tbg0 }}` as literal on-screen text.

Grep every fragment before using it:

```bash
grep -o '{{[^}]*}}' fragment.html
```

Usually the *content* is clean and only the interactive shell is bound — so the panels can be lifted and only the controls rebuilt. Where a binding is a computed value (`pctA = (98.2 * e).toFixed(1)` — a count-up animation), find the source expression and substitute the final value.

---

## Layout decision: native widgets vs HTML widget

This is the single biggest productivity lever.

### Use native widgets when

- It's a one-off heading, image, button, text block
- The user will edit copy in Elementor's visual editor
- The widget maps 1:1 to the design (Heading for headings, Image for images, Button for buttons)

### Drop into a single HTML widget when

- **Card grid** (4+ identical cards) — saves dozens of widget calls and keeps spacing consistent
- **Content inside Tabs/Accordion** — `add-tabs` only takes `tab_content` as HTML strings, so any rich card grid inside a tab *must* be HTML
- **Complex hover effects** — image scale on hover inside a parent `<a>`, animated underline expanding on hover, gradient overlay reveal — these aren't exposed by widget controls
- **CSS pseudo-elements** (`::before`, `::after`) for decorative dividers, arrows, frames
- **CSS Grid layouts** with media queries — Elementor's built-in container is flex-only on the free tier
- **Scoped style block** styling many child elements consistently (form fields, listing cards, neighborhood tiles)

### Mixing the two

When you need to style a native widget from an HTML widget elsewhere, scope styles to the parent Elementor element ID:

```html
<style>
.elementor-element-f8d1545 .elementor-tab-title {
  text-transform: uppercase !important;
  letter-spacing: .26em !important;
}
.elementor-element-f8d1545 .elementor-tab-title.elementor-active {
  border-bottom-color: #171615 !important;
}
</style>
```

The `f8d1545` is the `element_id` returned when the widget was created. Always grab and remember these IDs — they're the only stable selector.

---

## Forms

**If Pro is active:** the `add-form` MCP tool builds a real, submitting Form
widget natively — no Fluent Forms, no shortcode, fully editable in Elementor. The
kit auto-detects Pro and the skill routes here. Confirm field/action keys via
`get-widget-schema({ widget_type: "form" })` before building.

**If free (fallback):** Elementor's Form widget is Pro and `add-form` isn't
exposed. The free path:

1. Build the form in **Fluent Forms** (or WPForms / CF7) — these have free plans
2. Get the shortcode (e.g., `[fluentform id="1"]`)
3. Drop it via Elementor's `add-shortcode` widget

If you're at the visual-build stage and forms aren't wired yet, an HTML `<form>` with a JS-alert handler is fine as a placeholder. **Flag it explicitly to the user** as "form is visual only — doesn't capture submissions yet."

---

## Header / Footer

**If Pro is active:** use the native **Theme Builder** via `create-theme-template`
(`header` / `footer` / `single` / `archive`) + the native Nav Menu widget — no
UAE/HFE plugin. The kit detects Pro and the skill routes here.

**If free (fallback):** Theme Builder is Pro. The free path uses **Header Footer Elementor (HFE)** by Brainstorm Force or UAE:

1. Install + activate HFE
2. **WP Admin → Header Footer Builder → Add New** → set Type: Header (or Footer), Display On: Entire Website
3. Edit with Elementor — the MCP can edit this template the same way it edits any page (find its post_id via `list-pages({post_type: "elementor-hf"})`)

For a transparent header that swaps to solid on scroll: with **Pro**, set the
header Container's **Sticky** (`Top`) + a sticky-state background, and use **Motion
Effects** natively. Free workaround is either keep it solid throughout, or
hand-write a small CSS snippet via Customizer → Additional CSS.

---

## What the MCP cannot do (set expectations early)

- Install plugins or themes, including **Elementor Pro** itself (paid, not on wp.org — the kit only detects it; use WP-CLI or WP Admin)
- Set the static front page (use `wp option update show_on_front page; wp option update page_on_front <id>`)
- Pixel-perfect HTML→Elementor translation — Elementor's flexbox container model is the ceiling (Pro adds CSS Grid containers)
- Auto-fix broken layouts — you read the rendered output and emit corrective `update-element` calls

**Pro features (Theme Builder, Loop Grid, Form widget, Sticky/Motion, Popups, Dynamic Tags) are driven natively when Pro is active** — they're auto-detected. They're only unavailable on the free tier, where the workarounds above apply.

---

## Patching `_elementor_data` directly

**`wp eval-file` passes its arguments in `$args`, not `$argv`.** A script reading `$argv[1]` gets nothing and dies with `ValueError: Path cannot be empty` from inside WP-CLI's own eval wrapper — an error that points at WP-CLI rather than at your script. Read `$args[0]`, `$args[1]`, and validate them:

```php
$pid  = (int) ( $args[0] ?? 0 );
$file = $args[1] ?? '';
if ( ! $pid || ! is_readable( $file ) ) { echo "usage: <post_id> <json-file>\n"; exit( 1 ); }
```


Sometimes the tools don't reach — an undocumented key, a bulk edit across 40 elements, a property the schema doesn't expose. The page is one JSON tree in the `_elementor_data` post meta, and you can walk it. Two details are fatal if you miss them.

**1. Never write it with `--format=json`.**

```bash
wp post meta update 907 _elementor_data '<json>' --format=json   # ✗ corrupts the page
```

That stores a serialized PHP array. Elementor expects a JSON *string*. The page opens empty. Use `wp eval-file` instead:

```php
$patch = json_decode( file_get_contents( $file ), true );   // id => settings map
if ( ! is_array( $patch ) ) { echo "bad patch json\n"; exit( 1 ); }
$data = json_decode( get_post_meta( $pid, '_elementor_data', true ), true );
if ( ! is_array( $data ) ) { echo "post $pid has no usable _elementor_data — aborting\n"; exit( 1 ); }
$hit  = [];
$walk = function ( &$els ) use ( &$walk, $patch, &$hit ) {
    foreach ( $els as &$e ) {
        if ( isset( $patch[ $e['id'] ] ) ) {
            $e['settings'] = array_merge( $e['settings'], $patch[ $e['id'] ] );
            $hit[ $e['id'] ] = true;
        }
        if ( ! empty( $e['elements'] ) ) { $walk( $e['elements'] ); }
    }
};
$walk( $data );

// Abort before saving if any target is missing — a partial write is worse
// than none, because it looks like it worked.
$missing = array_diff( array_keys( $patch ), array_keys( $hit ) );
if ( $missing ) { echo "ids not found: " . implode( ',', $missing ) . " — nothing written\n"; exit( 1 ); }
update_post_meta( $pid, '_elementor_data', wp_slash( wp_json_encode( $data ) ) );
delete_post_meta( $pid, '_elementor_element_cache' );
\Elementor\Plugin::$instance->files_manager->clear_cache();
```

**2. `delete_post_meta( $id, '_elementor_element_cache' )` is not optional.** Elementor caches rendered element HTML in that meta. `files_manager->clear_cache()` clears the *CSS* and leaves it. Skip the delete and a perfectly correct write serves the old HTML — which reads exactly like a failed write, and sends you rebuilding elements that were never broken. Elementor's own `Document::save()` deletes it; direct writers have to do it themselves.

**3. This walker patches `settings` — which on atomic (v4) pages is the wrong half for anything visual.** Atomic layout and appearance don't live in `settings`: they live in the element's **top-level `styles` map**, referenced from `settings.classes` (convention 8 and `files/references/atomic-v4.md`). Merge a padding or position change into an atomic element's `settings` and you get the whole silent-success chain — the walker matches the id, the save succeeds, both caches clear, and the page renders exactly as before.

So scope the recipe: on **classic (v3)** elements it patches anything. On **atomic** elements it is content-only *and* the values must be typed:

- **Content, in raw `$$type` shape.** Atomic settings are typed props, not flat strings. Write `title: "Hi"` into an atomic heading by hand and it saves and renders nothing: fetch the shape with `get-widget-schema` and build the typed value yourself. **A direct DB patch has no wrapper to fall back on** — it bypasses the plugin entirely, so this applies to every atomic prop, always.

  Going *through the tools* is the way out, and the reason is worth knowing: since plugin **1.27.0**, `save_page_data()` sweeps the whole tree through `Elementor_MCP_Atomic_Props::coerce_tree()` before writing, so flat values handed to any tool — `update-atomic-widget` included — are wrapped into the envelope the prop declares. On **older builds** that sweep doesn't exist and the universal `add-atomic-widget` / `update-atomic-widget` tools write settings verbatim, which is the behaviour `files/references/atomic-v4.md` still describes; check the plugin version before trusting either statement.
- **Styling — not through `settings` at all.** Patch the element's `styles` variant and keep its id in `settings.classes`, or use `create-global-class` / `apply-global-class`, which is the supported path and survives element rebuilds.

Both failures look identical from the outside: the walker matches, the save succeeds, the caches clear, the pixels don't move.

The `$missing` check above is the habit that pays for itself: without it a typo'd id in a 40-element patch commits a partial write that looks like a success. Keeping the patch as an `id => settings` map is what makes that check — and the diff — readable.

---

## Working from a design export

**The exported markup is the only source of truth for a value.** Not a screenshot, not a crop, not your memory of the last section.

- **Measure widths from the source render at the design viewport**, never from a screenshot the client pasted — those are scaled, and a 1320px container measures 1120 in a shrunk PNG. Getting this wrong costs a full pass.
- **Don't normalise across sections.** Real designs vary deliberately: on this build most sections were 1320 and two were 1120. A tidy-up pass that aligned everything to 1320 erased a deliberate difference and had to be reverted.
- **Check the provenance of reference images.** A `crops/` folder in the handover turned out to be screenshots of a *different company's* site. Everything measured from it was wrong.
- **Search the markup by byte range, not by string.** Exported headings are split across styled spans, so `find("Get solid in three steps")` returns nothing while the text is plainly on screen. Build a section index of byte offsets once, then slice.
- **Copy beats design.** When the client's content document and the design disagree, the document wins — and when there are two revisions of it, confirm which is authoritative before implementing either.

Orbiting badges, overlapping cards, and off-grid decoration have no *flex-flow* equivalent, but they are still expressible — the route depends on the tier and the engine, and none of them is "impossible":

| Site | Route |
|---|---|
| **Pro**, any engine | Per-element `custom_css` — `selector{position:absolute;top:…;left:…}` (see the `custom_css` note above). The tidiest option. |
| **Free + classic (v3)** | The widget's own `_position: absolute` control, with `_offset_x` / `_offset_y`. |
| **Free + atomic (v4)** | The hardest case: `custom_css` is Pro, `_position` is a classic-widget control, and the classic `css_classes` / `_css_classes` controls don't attach on atomic elements either — atomic uses the typed `settings.classes` reference list, where every id must resolve to a local style def or a Global Class (`files/references/atomic-v4.md`), and arbitrary class names render nothing. Nor does a Global Class help *for positioning specifically*: it carries the same atomic props, which have no `position`. So write the rule against **`.elementor-element-<id>`** from **Appearance → Customize → Additional CSS** (core WordPress, free, always available) or a child-theme stylesheet — accepting the one real cost: the id changes if that element is deleted and rebuilt, so re-check the rule after any rebuild of the section. |

What is *not* available on any tier is expressing it through the MCP's atomic props: `build_common_props()` has no `position` mapping (field report #4). **A Lottie is the last resort**, for compositions that also animate; it keeps the design's arrangement at the price of editability. If you author one in code: bodymovin easing handles must be arrays (`{"x":[0.5],"y":[1.0]}`) — scalars silently freeze the layer — and watch the export scale, since `deviceScaleFactor` multiplies with any clip scale.

---

## When something looks wrong on the rendered page

Work down this list before concluding a write failed. Most "the tool didn't work" reports on this build were stale caches or bad screenshots.

1. **Clear both caches** — the rendered-HTML meta *and* the compiled CSS, or a style change still shows stale and you'll misread a good write as a dropped property:

   ```bash
   wp eval "delete_post_meta( <id>, '_elementor_element_cache' ); \Elementor\Plugin::\$instance->files_manager->clear_cache();"
   ```

   Then reload (and warm once before screenshotting — see below). This alone explains a large share of "my change didn't apply".
2. `get-page-structure({post_id})` — confirms what's nested in what
3. `get-element-settings({element_id})` — shows the actual settings written to the DB
4. `curl <site-url>` and grep for your custom classes — confirms the page is actually rendering your widgets
5. Read the compiled CSS at `wp-content/uploads/elementor/css/post-<id>.css` — this is where a silently-dropped property shows up as an absent rule
6. View source in browser — Elementor wraps every widget in `.elementor-element.elementor-element-<id>` so you can find any element by its ID

### Screenshots that don't lie

- **Always pass `--virtual-time-budget`** to headless Chrome (`--virtual-time-budget=15000`). Without it the shot is taken before webfonts load, and you'll "fix" typography that was already correct.
- **The first screenshot after clearing the cache renders unstyled.** Elementor regenerates `post-<id>.css` on the next page view, and a screenshot that races it comes back with fallback fonts, no colours, and a wrong page height — an entire site that looks catastrophically broken. Warm the page with one throwaway request after any cache clear, and before believing a bad shot, take a second one at a different width. If **every** width is broken the same way, suspect the cache race — warm and re-shoot. If **only one** width is broken, that is the signature of a real responsive bug (a media query, a breakpoint boundary, a `_tablet`/`_mobile` control) — re-shoot once after warming to rule the race out, then go read the responsive CSS rather than blaming the cache; writing off a single-width failure as cache is how a real mobile regression ships.
- **Headless Chrome has a ~500px minimum layout width.** `--window-size=390,N` does not render a 390px viewport; it renders 500px and crops. Mobile was twice reported broken on this build on that evidence alone, and was fine both times. For real mobile, drive CDP and call `Emulation.setDeviceMetricsOverride`.
- Verify at **1440 / 1024 / 390** once a section is settled, not before.

---

## Reading list (what helped me get this right)

- [elementor-mcp source](https://github.com/Digitizers/elementor-mcp) (fork of [msrbuilds/elementor-mcp](https://github.com/msrbuilds/elementor-mcp)) — `includes/abilities/class-*-abilities.php` files are the ground truth on each tool's behavior
- [WordPress MCP Adapter](https://github.com/WordPress/mcp-adapter) — explains the JSON-RPC plumbing and auth options
- [Elementor's `_elementor_data` post meta format](https://developers.elementor.com/docs/getting-started/elementor-data/) — every page is one giant nested JSON tree in this meta key. The MCP reads/writes this directly.
- The [container schema dump](#) — `get-container-schema()` returns ~50KB of JSON Schema. Read once at session start; bookmark the keys.
