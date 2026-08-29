# Plugin Catalog — Reference

What common WordPress plugins do, what surfaces they expose via REST,
and what to watch out for when the user asks you to touch them. If a
plugin shows up in `site-architecture.md` and isn't listed here, treat
it as opaque — read its docs or check `/wp-json` for a namespace before
changing anything.

## Content & Custom Fields

### Advanced Custom Fields (ACF) / ACF Pro
- **Slug:** `advanced-custom-fields` or `advanced-custom-fields-pro`
- **Purpose:** Adds custom fields to posts, pages, users, taxonomies,
  options pages.
- **REST surface:** ACF Pro 6.x auto-injects an `acf` key into the
  default `/wp/v2/posts`, `/wp/v2/pages`, etc. payloads. Reading +
  writing via that key is the supported path (see `acf-guide.md`).
- **Caveat:** Each field group needs `show_in_rest: true` to be
  readable/writable through REST. Without it, REST silently no-ops.
- **Out of scope from REST:** Creating or editing field group
  definitions (that's theme code). ACF options pages have no built-in
  REST surface.

### Custom Post Type UI
- **Slug:** `custom-post-type-ui`
- **Purpose:** Register CPTs and taxonomies in wp-admin without code.
- **REST surface:** The CPTs and taxonomies it registers show up in
  `/wp/v2/types` and `/wp/v2/taxonomies`. CRUD on the CPT itself
  follows normal REST patterns. The plugin's own settings are not
  REST-exposed.

### Pods
- Similar to ACF + CPT UI rolled into one. Less common. Same REST
  exposure pattern — depends on per-field `show_in_rest` flag.

## SEO

### RankMath
- **Slug:** `seo-by-rank-math`
- **Storage:** `wp_postmeta` keys `rank_math_title`,
  `rank_math_description`, `rank_math_focus_keyword`,
  `rank_math_schema_*`.
- **Per-post meta via REST:** Only if the theme calls
  `register_post_meta(..., 'show_in_rest' => true)` for those keys.
  Most stock themes don't. Test with a read after write.
- **Site-wide settings via REST:** Yes — `/wp-json/rankmath/v1/*`
  namespace. Routes include `updateSettings`, `saveModule`,
  `updateMode`. Body shapes are undocumented — match what the
  wp-admin JS sends.

### Yoast SEO
- **Slug:** `wordpress-seo`
- **Storage:** `wp_postmeta` keys `_yoast_wpseo_title`,
  `_yoast_wpseo_metadesc`, `_yoast_wpseo_focuskw`.
- **REST surface:** Yoast registers some endpoints under
  `/yoast/v1/*` but coverage is partial. The per-post meta requires
  the same `register_post_meta` flag as RankMath.

### SEOPress
- **Slug:** `wp-seopress`
- **Storage:** `wp_postmeta` keys `_seopress_titles_title`,
  `_seopress_titles_desc`.
- **REST surface:** Mostly limited. Check `/wp-json` for a `seopress`
  namespace.

> **Rule:** never have two SEO plugins active at once. If the
> architecture doc shows two, flag it to the user.

## E-commerce

### WooCommerce
- **Slug:** `woocommerce`
- **Storage:** `wp_posts` (post_type `product`, `shop_order`),
  `wp_postmeta`, plus its own tables (`wp_wc_*`).
- **REST surface:** WooCommerce has its own auth scheme (`/wc/v3/*`)
  using consumer key + secret, not WordPress Application Passwords.
  This skill **does not** wire WooCommerce auth — that's a separate
  flow. If the user wants WooCommerce REST operations through this
  skill, point them at WooCommerce's auth docs.
- **Caution:** orders touch real money. Even reads should be Confirm
  if the user is unsure (PII / privacy concerns).

## Page builders

### Elementor / Elementor Pro
- **Slug:** `elementor` / `elementor-pro`
- **Storage:** `_elementor_data` postmeta (JSON blob).
- **Caveat:** editing `post_content` via REST does nothing visual if
  Elementor is active for that page — Elementor renders from
  `_elementor_data`, not from `post_content`. If the user wants to
  edit Elementor pages, they need to use the Elementor editor in
  wp-admin or escalate to a developer with the Elementor REST API
  (which requires their own auth setup).

### Bricks Builder
- **Slug:** `bricks`
- Theme + builder combo. `_bricks_page_content_2` postmeta (JSON).
  Same caveat: editing `post_content` won't show up.

### Beaver Builder
- **Slug:** `beaver-builder-lite-version` / `bb-plugin`
- `_fl_builder_data` postmeta (PHP-serialized — don't edit by hand
  even via REST).

### Divi (theme + plugin)
- Shortcodes in `post_content`. REST writes to `post_content`
  with `[et_pb_*]` shortcodes WILL render — but this skill almost
  never knows the right shortcode to write. Escalate to a developer.

### Gutenberg / Block Editor
- Native. Content is HTML+block markup in `post_content`. Safe to
  read + write via REST. `content.raw` (with `?context=edit`)
  preserves the block comments.

## Forms

### Gravity Forms
- **Slug:** `gravityforms`
- Custom tables for forms, entries. Has its own REST API but it
  requires Gravity Forms-specific API keys, not WordPress Application
  Passwords.

### WPForms
- **Slug:** `wpforms-lite` / `wpforms`
- Limited REST exposure. Manage in wp-admin.

### Contact Form 7
- **Slug:** `contact-form-7`
- Forms stored as CPT `wpcf7_contact_form`. Reachable via `/wp/v2/`
  if `show_in_rest` is enabled (it isn't by default).

## Caching / performance

> **Caching plugins are the #1 cause of "I changed something and it
> didn't appear."** When the user reports stale content, the issue is
> usually edge cache or page cache. Most cache plugins don't expose a
> "purge" endpoint via REST. The user has to purge via wp-admin or
> their hosting panel.

### WP Rocket
- **Slug:** `wp-rocket`
- No REST API for purge by default. Some hosts expose a webhook.

### W3 Total Cache
- **Slug:** `w3-total-cache`
- Limited REST exposure.

### LiteSpeed Cache
- **Slug:** `litespeed-cache`
- Has `/litespeed/v3/purge_*` endpoints (LiteSpeed servers only).

### WP Super Cache / WP Fastest Cache
- Manage via wp-admin only.

### Object cache (Redis / Memcached)
- Persistent object cache. No REST surface — purge via host panel.

## Security

> Security plugins can lock the user out of the site. **Never disable
> them without an explicit request from the user.** Many also
> selectively disable parts of the REST API.

### Wordfence
- **Slug:** `wordfence`
- Adds 2FA, login throttling, malware scanning.
- May rate-limit REST API calls that look anomalous to its heuristics.
- Has its own `/wordfence/v1/*` endpoints (admin-only).
- **Common gotcha:** Wordfence's "Brute Force Protection" can lock out
  the Application Password if too many failed attempts hit in a window.
  After enough 401s in a row, your IP gets blocked.

### Sucuri Security
- **Slug:** `sucuri-scanner`
- Audit logging + integrity scanning. Mostly admin-side.

### iThemes Security / Solid Security
- **Slug:** `better-wp-security` / `solid-security-pro`
- Can disable Application Passwords entirely. If the user's site has
  Solid Security active and the REST connection won't work, check the
  plugin's "Application Passwords" setting.

### Limit Login Attempts Reloaded
- **Slug:** `limit-login-attempts-reloaded`
- Throttles failed logins. Doesn't usually affect Application
  Passwords, but check if Application Password 401s start blocking.

### Disable REST API plugins
- Slugs like `disable-wp-rest-api`, `wp-rest-api-controller` —
  selectively close endpoints. If the user has one active and REST
  reads return 401/403 on logged-in calls, this is the cause.

## Backups

### UpdraftPlus
- **Slug:** `updraftplus`
- Schedules backups to S3 / Drive / etc.
- Limited REST. Manage in wp-admin.

### BackWPup / Duplicator
- Same — wp-admin only for typical workflows.

> Before any Confirm or Stop-tier operation, ask: "When was the last
> backup? Where is it?" If the user can't answer, suggest taking one
> from their hosting panel or backup plugin.

## Multilingual

### WPML
- **Slug:** `sitepress-multilingual-cms`
- Heavy plugin. Each translated post is a separate post row linked
  via WPML's own tables.
- **REST surface:** has `/wpml/v1/*` endpoints but they're partial.
  Editing translations through REST is risky — translation linkage
  can desync. Recommend wp-admin or developer for translation work.

### Polylang
- **Slug:** `polylang` / `polylang-pro`
- Similar to WPML. Translations are separate posts. REST surface is
  partial.

### TranslatePress
- **Slug:** `translatepress-multilingual`
- Stores translations inline as DOM annotations. REST exposure
  limited.

## Misc workhorses

| Plugin | Purpose | REST notes |
|---|---|---|
| `redirection` | URL redirects | Limited REST surface; manage in wp-admin |
| `wp-mail-smtp` | Transactional email | Manage in wp-admin |
| `monsterinsights` / `site-kit-by-google` | Google Analytics | Read-only typically |
| `jetpack` | Bundle of features | Heavy — check what features are on |
| `classic-editor` | Disables Gutenberg | If active, post_content is plain HTML not blocks |
| `disable-comments` | Hides comments | UI only — comments still in DB |

## When you see a plugin not in this catalog

1. Note it to the user.
2. Mention you're not familiar with it.
3. Check if it registered a REST namespace:
   ```http
   GET /wp-json
   ```
   Look for the plugin's slug in the `namespaces` array.
4. If it has a namespace, hit the root to see its routes:
   ```http
   GET /wp-json/{plugin-namespace}/v1
   ```
5. Treat any data modification through that plugin as **Confirm**-tier
   until you understand its body shapes. Body shapes for plugin
   namespaces are often "whatever the wp-admin JS sends" — match by
   inspecting browser devtools while using the wp-admin UI.
