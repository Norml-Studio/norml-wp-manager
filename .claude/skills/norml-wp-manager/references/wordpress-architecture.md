# WordPress Architecture — Reference

Baseline knowledge of how a WordPress install is laid out, viewed through
the lens of what's reachable via the REST API. Use this to answer "how
does WordPress work?" questions without an API round-trip. For site-
specific facts (which plugins, which theme, which post types), use
`{project_dir}/norml-wp-manager/site-architecture.md`.

## File layout (server-side)

This skill **never touches the filesystem**. The file layout below is
for context only — to understand where things live on the server when
the user says "the developer added X" or "I uploaded a plugin to Y."

```
{wordpress_path}/
├── wp-admin/                  Admin UI. Out of REST scope.
├── wp-includes/               Core code. Out of REST scope.
├── wp-content/                User-modifiable content + plugins.
│   ├── themes/                One folder per theme.
│   │   └── {active-theme}/
│   │       ├── style.css      Theme metadata + main stylesheet.
│   │       ├── functions.php  Theme PHP entrypoint.
│   │       ├── acf-json/      ACF field group JSON sync (if used).
│   │       └── ...
│   ├── plugins/               One folder per plugin.
│   ├── mu-plugins/            "Must-use" plugins — always active.
│   │                          Often host-managed (Kinsta, WP Engine).
│   └── uploads/               Media library files, by year/month.
│       └── YYYY/MM/...
├── wp-config.php              DB credentials, salts. Out of REST scope.
├── .htaccess                  Rewrite rules. Out of REST scope.
└── index.php                  WordPress bootstrap.
```

**This skill's scope is `wp-admin`-equivalent operations.** It reads
content, writes content, manages users, lists what's installed — but
never opens a file in `wp-content/themes/` or `wp-content/plugins/`. If
the user needs file-level work, they need their developer.

## REST API — the surface this skill works with

WordPress exposes a REST API at `/wp-json/`. Discovery is built-in:

```http
GET /wp-json
```

Returns the root response: WordPress version (in `description`),
registered REST namespaces (`namespaces` array), available routes,
authentication methods.

### Core namespace — `/wp-json/wp/v2/*`

| Resource | Endpoint | Notes |
|---|---|---|
| Posts | `/wp/v2/posts` | Built-in post type. |
| Pages | `/wp/v2/pages` | Built-in page type. |
| Custom post types | `/wp/v2/{rest_base}` | Only if registered with `show_in_rest: true`. |
| Categories | `/wp/v2/categories` | Built-in taxonomy. |
| Tags | `/wp/v2/tags` | Built-in taxonomy. |
| Custom taxonomies | `/wp/v2/{rest_base}` | Only if registered with `show_in_rest: true`. |
| Users | `/wp/v2/users` | Auth'd reads + writes. |
| Media | `/wp/v2/media` | Upload, attach, update metadata. |
| Comments | `/wp/v2/comments` | Moderation. |
| Settings | `/wp/v2/settings` | Admin-only. |
| Plugins | `/wp/v2/plugins` | Admin-only; often 404 on managed hosts. |
| Themes | `/wp/v2/themes` | Admin-only. |
| Types | `/wp/v2/types` | All registered post types + their `rest_base`. |
| Taxonomies | `/wp/v2/taxonomies` | All registered taxonomies. |
| Search | `/wp/v2/search` | Cross-type search. |
| Menus | `/wp/v2/menus` | Navigation menus. |
| Menu items | `/wp/v2/menu-items` | Per-menu items. |

### Plugin namespaces — `/wp-json/{plugin}/v{n}/*`

When a plugin registers REST routes, they show up under their own
namespace. Common ones:

- `/wp-json/rankmath/v1/*` — RankMath SEO
- `/wp-json/wc/v3/*` — WooCommerce (uses its own auth, not Application
  Passwords)
- `/wp-json/acf/v3/*` — ACF (when the "ACF to REST API" companion
  plugin is installed)
- `/wp-json/yoast/v1/*` — Yoast SEO (partial coverage)

The full list for the user's site is in `site-architecture.md` under
"Available namespaces."

## Authentication — Application Passwords

WordPress 5.6+ ships with Application Passwords built in. They're
**24-character tokens** generated per-user in
`wp-admin/profile.php` (Application Passwords section), used via HTTP
Basic Auth:

```
Authorization: Basic base64(username:application-password)
```

This skill:

- Stores the Application Password in macOS Keychain or Windows
  Credential Manager.
- Looks it up inline at every REST call. The plaintext password never
  exists as a Claude-visible variable.
- Tells the user to revoke (in wp-admin) + rotate (re-run onboarding)
  if it ever leaks.

Application Passwords:

- Grant whatever the underlying WordPress user can do (no per-endpoint
  scopes — admin password = admin REST access).
- Are revocable individually in wp-admin without affecting the user's
  login password.
- Show last-used IP and timestamp in the wp-admin AP panel — visible
  per-app audit trail.

## Database tables (default prefix `wp_`)

This skill never queries the DB directly. The table layout below is for
context — to understand what's behind a REST response.

| Table | Holds | Reachable via |
|---|---|---|
| `wp_posts` | Posts, pages, CPTs, attachments, revisions, drafts. | `/wp/v2/posts`, `/wp/v2/pages`, `/wp/v2/{cpt}` |
| `wp_postmeta` | Custom fields (ACF values, SEO meta, anything `update_post_meta`). | `acf` payload on post body, `meta` payload if `register_post_meta` allows |
| `wp_terms`, `wp_term_taxonomy`, `wp_term_relationships` | Taxonomy data — categories, tags, custom taxonomies. | `/wp/v2/categories`, `/wp/v2/tags`, `/wp/v2/{tax}` |
| `wp_users` | User accounts. | `/wp/v2/users` |
| `wp_usermeta` | User custom fields (capabilities, ACF user fields). | Partial via `/wp/v2/users` |
| `wp_options` | Site settings. `home`, `siteurl`, `blogname`, plus serialized blobs from plugins. | Partial via `/wp/v2/settings` (only opted-in keys) |
| `wp_comments`, `wp_commentmeta` | Comments. | `/wp/v2/comments` |

**Key takeaway:** lots of data lives in `wp_options` and `wp_postmeta`
that **never appears in the REST surface** unless a plugin or theme
explicitly opts in. When a write seems to silently fail, this is
usually why.

## Themes — parent vs child

A WordPress site has one active *stylesheet* (the theme the user
picked) and one active *template* (the parent theme). Usually they're
the same. When they differ, the active one is a child theme.

Visible via:
```http
GET /wp-json/wp/v2/themes
```

The theme with `status: "active"` is the active one. `template` field
is the parent.

## Page builders (visual editors)

Many sites use a builder instead of (or alongside) the Gutenberg block
editor. The active builder dictates *where* page content actually lives:

- **Gutenberg (core block editor)** — content is serialized HTML+block
  comments in `wp_posts.post_content`. **Safe to read + write via
  REST.**
- **Elementor** — content lives in `_elementor_data` postmeta (JSON
  blob). REST writes to `post_content` won't affect the front-end.
  Cannot be edited via this skill.
- **Bricks Builder** — `_bricks_page_content_2` postmeta. Same problem.
- **Beaver Builder** — `_fl_builder_data` postmeta (PHP-serialized).
- **WPBakery (Visual Composer)** — `post_content` with `[vc_*]`
  shortcodes.
- **Divi** — `post_content` with `[et_pb_*]` shortcodes.

**Rule of thumb:** before editing a page's body via REST, check the
active builder in `site-architecture.md`. If a builder is active
(Elementor, Bricks, Beaver), writing plain HTML to `post_content` will
silently fail to appear on the front-end. Tell the user.

## Hook lifecycle (high level — context only)

WordPress is event-driven. Knowing where a feature hooks helps explain
why something behaves as it does. Every request goes through:

1. `wp-load.php` boots WordPress, loads config, connects DB.
2. **`plugins_loaded`** — every active plugin's main file runs.
3. **`init`** — register post types, taxonomies, REST routes,
   shortcodes.
4. **`wp`** — query parsed, current object identified.
5. **`template_redirect`** — last chance to redirect.
6. Template file picked from `wp-content/themes/{active}/...`.
7. **`wp_head`** / `wp_footer`** — themes and plugins inject scripts,
   meta, schema markup.
8. Output rendered.

The REST API runs through the same pipeline, just routed differently —
plugin endpoint registrations happen in `rest_api_init`, which fires
during `init`.

## When the user says "I changed something in wp-admin but it didn't show up"

It's almost always cache. WordPress has multiple layers:

1. **Browser cache** — hard refresh (Cmd+Shift+R / Ctrl+F5).
2. **Page cache plugin** — WP Rocket, W3 Total Cache, LiteSpeed Cache,
   etc. Often invalidates on save automatically but not always.
3. **Host edge cache** — WP Engine, Kinsta, Cloudflare. Sometimes
   independent of any plugin.
4. **REST API response cache** — managed hosts cache `/wp-json/*` at
   the edge. Append `?_=$(date +%s)` to bust.
5. **Object cache (Redis / Memcached)** — server-side, usually
   plugin-managed.

This skill doesn't have purge endpoints for most cache layers. The user
needs to purge from their hosting panel or wp-admin.

## When the user says "I can't see the field I added"

Read `acf-guide.md`. Most often it's the field group lacking
`show_in_rest: true`, which means REST silently no-ops on reads and
writes for that field.
