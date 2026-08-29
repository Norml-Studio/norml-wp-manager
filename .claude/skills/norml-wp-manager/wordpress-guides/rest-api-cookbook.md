# REST API Cookbook — Reference

Canonical WordPress REST API calls organized by intent. Every call in this
skill is an HTTPS request to `{production_url}/wp-json/...`, authenticated
via HTTP Basic Auth (username + Application Password). The wrapper below
assumes the macOS pattern; on Windows the equivalent is `Invoke-RestMethod`
with the `Authorization: Basic <base64>` header.

```bash
curl -sS \
  -u "${WP_USER}:$(security find-generic-password -s "${SECRET_ENTRY}" -w)" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  "${BASE}/wp-json/<endpoint>"
```

For brevity, the cookbook shows only the method, endpoint, and body. Add
the `-u` and `-H` flags from the wrapper above when running.

## Auth + identity smoke

```http
GET /wp-json/wp/v2/users/me?_fields=id,name,roles
```

Use as your "is this working" probe. 200 + a JSON user object means
credentials are valid. 401 means username/password mismatch.

## Posts and pages

### List

```http
GET /wp-json/wp/v2/posts?per_page=10&_fields=id,title,status,date
GET /wp-json/wp/v2/pages?per_page=10&_fields=id,title,status,date
GET /wp-json/wp/v2/posts?status=draft&context=edit
GET /wp-json/wp/v2/posts?author=2
GET /wp-json/wp/v2/posts?search=spring%20launch
```

Pagination via `?page=N` and the `X-WP-Total` / `X-WP-TotalPages` response
headers. Don't fetch-then-count; read the header.

### Read one (include `?context=edit` if you'll write back)

```http
GET /wp-json/wp/v2/posts/42?context=edit
GET /wp-json/wp/v2/pages/19?context=edit
```

`context=edit` returns `content.raw`, `excerpt.raw`, and `meta` — required
for round-trip editing. `context=view` (default) strips these.

### Update one

```http
POST /wp-json/wp/v2/posts/42
Content-Type: application/json

{ "title": "New title" }
```

```http
POST /wp-json/wp/v2/posts/42
Content-Type: application/json

{ "content": "<!-- wp:paragraph --><p>Updated body…</p><!-- /wp:paragraph -->" }
```

### Create a draft

```http
POST /wp-json/wp/v2/posts
Content-Type: application/json

{ "title": "Spring sale", "status": "draft" }
```

For custom post types, replace `posts` with the CPT's `rest_base` (see
`site-architecture.md` for the list).

### Publish a draft

```http
POST /wp-json/wp/v2/posts/42
Content-Type: application/json

{ "status": "publish" }
```

### Trash / restore / permanently delete

```http
# Trash
DELETE /wp-json/wp/v2/posts/42

# Permanently delete (Confirm — irreversible)
DELETE /wp-json/wp/v2/posts/42?force=true

# Restore from trash
POST /wp-json/wp/v2/posts/42
{ "status": "draft" }
```

## Custom post types

If a CPT is registered with `show_in_rest: true`, it's reachable at
`/wp/v2/{rest_base}`. The `rest_base` is in `GET /wp-json/wp/v2/types`.

```http
GET /wp-json/wp/v2/types
GET /wp-json/wp/v2/case-study?per_page=20
POST /wp-json/wp/v2/case-study
{ "title": "Acme", "status": "draft" }
```

CPTs registered **without** `show_in_rest: true` return 404 from REST.
This skill cannot reach them — the user needs their developer to flip
the flag.

## Taxonomies and terms

```http
GET /wp-json/wp/v2/taxonomies
GET /wp-json/wp/v2/categories?per_page=50
GET /wp-json/wp/v2/tags
GET /wp-json/wp/v2/product_cat
```

### Create a term

```http
POST /wp-json/wp/v2/categories
{ "name": "Insurance Tech", "slug": "insurance-tech" }
```

### Attach terms to a post

```http
POST /wp-json/wp/v2/posts/42
{ "categories": [12, 18], "tags": [3] }
```

Term IDs come from the taxonomy endpoint's response.

## ACF field values (when the field group has `show_in_rest`)

Include an `acf` object on the post body. ACF Pro auto-handles it on
save:

```http
POST /wp-json/wp/v2/posts/42
{
  "acf": {
    "hero_headline": "Spring launch",
    "hero_subhead":  "All new collection",
    "faq_items": [
      { "question": "Q1?", "answer": "A1." },
      { "question": "Q2?", "answer": "A2." }
    ]
  }
}
```

Read existing values via `?context=edit`:

```http
GET /wp-json/wp/v2/posts/42?context=edit&_fields=acf
```

**Hard caveat:** if the field group lacks `show_in_rest`, ACF returns
`acf: []` (empty array) on reads and silently no-ops on writes. Confirm
the field group is REST-exposed before assuming a write landed. See
`acf-guide.md` for the deeper map.

## SEO meta (RankMath, Yoast)

Most SEO plugins store per-post meta in `wp_postmeta`. Whether REST can
write it depends on whether the theme calls `register_post_meta(..., 'show_in_rest' => true)`.

### When `meta` is registered with `show_in_rest`

```http
POST /wp-json/wp/v2/posts/42
{
  "meta": {
    "rank_math_title":          "Page title — Site Name",
    "rank_math_description":    "Page meta description.",
    "rank_math_focus_keyword":  "target keyword"
  }
}
```

If REST silently no-ops on these (you write, then re-read and the values
didn't change), the meta isn't registered for REST. The user's developer
needs to add the registration, or the value has to be set in wp-admin.

### RankMath site-wide settings

If RankMath is active, its own namespace exists:

```http
GET /wp-json/rankmath/v1/
```

Lists its endpoints. Specific bodies need to be probed per endpoint —
the namespace is "whatever the wp-admin JS sends" and is sparsely
documented.

## Media — upload + featured image

Media uploads are a two-call flow. Upload the file, capture the returned
ID, then attach it to a post.

### Upload

```bash
curl -sS \
  -u "${WP_USER}:$(security find-generic-password -s "${SECRET_ENTRY}" -w)" \
  -H "Content-Type: image/jpeg" \
  -H "Content-Disposition: attachment; filename=\"hero.jpg\"" \
  --data-binary @"/path/to/hero.jpg" \
  "${BASE}/wp-json/wp/v2/media"
```

Response includes `id`, `source_url`, `mime_type`.

### Attach as featured image

```http
POST /wp-json/wp/v2/posts/42
{ "featured_media": 318 }
```

### Update media metadata (alt text, caption, title)

```http
POST /wp-json/wp/v2/media/318
{
  "title":       "Hero image",
  "alt_text":    "A field of yellow flowers at sunset",
  "caption":     "Spring is here.",
  "description": "Used on the homepage hero."
}
```

## Users

```http
GET /wp-json/wp/v2/users?per_page=50&_fields=id,name,roles
GET /wp-json/wp/v2/users?roles=administrator
GET /wp-json/wp/v2/users/42
```

### Create a user

```http
POST /wp-json/wp/v2/users
{
  "username": "new-editor",
  "email":    "editor@example.com",
  "password": "<a-strong-password>",
  "roles":    ["editor"]
}
```

> Admin role assignments are Confirm-tier — show the body and ask before
> running.

### Change a user's role

```http
POST /wp-json/wp/v2/users/42
{ "roles": ["author"] }
```

### Delete a user

```http
DELETE /wp-json/wp/v2/users/42?reassign=1&force=true
```

`reassign` is the destination user ID for any posts they own. Required.

## Site settings (admin-only)

```http
GET  /wp-json/wp/v2/settings
POST /wp-json/wp/v2/settings
{
  "title":          "New site title",
  "description":    "New tagline",
  "posts_per_page": 12
}
```

Changing `url` or `home` here can lock the user out of the site — treat
as Confirm-tier with extra warning.

## Navigation menus (admin, WordPress 5.9+)

Nav menus are REST-editable since WordPress 5.9. Requires the
`edit_theme_options` capability (administrator). On older WP these
endpoints 404 — fall back to wp-admin → Appearance → Menus.

### List menus, items, and theme locations

```http
GET /wp-json/wp/v2/menus
GET /wp-json/wp/v2/menu-items?menus=3&per_page=100&_fields=id,title,url,parent,menu_order,object,object_id
GET /wp-json/wp/v2/menu-locations
```

`menu-locations` maps each theme slot (e.g. `primary`, `footer`) to a menu ID.

### Add an item

```http
POST /wp-json/wp/v2/menu-items
{ "title": "Pricing", "url": "/pricing/", "menus": 3, "status": "publish", "menu_order": 2 }
```

To link an item to existing content instead of a raw URL, send
`"type": "post_type", "object": "page", "object_id": 19` (the page ID).

### Reorder / re-parent / rename an item

```http
POST /wp-json/wp/v2/menu-items/57
{ "menu_order": 1, "parent": 0, "title": "Home" }
```

`menu_order` sets position; `parent` is the parent item's ID (0 = top level)
to build sub-menus.

### Remove an item

```http
DELETE /wp-json/wp/v2/menu-items/57?force=true
```

> Menu edits change site-wide navigation. Treat structural changes (reordering,
> deleting, or re-parenting several items) as Confirm-tier — show the before/after
> and ask first.

## Comments

```http
GET    /wp-json/wp/v2/comments
POST   /wp-json/wp/v2/comments/19
{ "status": "approved" }
DELETE /wp-json/wp/v2/comments/19?force=true
```

## Plugins (admin-only, often 404 on managed hosts)

```http
GET /wp-json/wp/v2/plugins?_fields=plugin,name,status,version
GET /wp-json/wp/v2/plugins/advanced-custom-fields-pro/advanced-custom-fields-pro
```

`POST` to install or activate plugins returns 404 on most managed hosts.
Tell the user to do it in wp-admin → Plugins.

## Themes (admin-only)

```http
GET /wp-json/wp/v2/themes
```

`active: true` flags the active theme.

## Search

```http
GET /wp-json/wp/v2/search?search=spring%20launch&per_page=10
```

Returns a deduplicated list of posts/pages/CPTs matching the query.

## Output style

- Default to compact responses with `?_fields=field1,field2`
- Use `?context=edit` when reading data you intend to write back
- Pagination via `?per_page=N&page=N` and the `X-WP-Total` header
- Errors come back as
  `{ "code": "...", "message": "...", "data": { "status": <http-code> } }`
  — always check the status code, never just the body

## Common known-issues

- **`401 Unauthorized` on a known-good endpoint** → Application Password
  revoked, expired, or wrong account. Verify via `/users/me` first.
- **`403 Forbidden` on a known-good endpoint** → the connected user lacks
  the capability. Either change role or use a different account.
- **`404 Not Found` on `/wp/v2/plugins` POST** → host disabled it.
  No retry strategy — use wp-admin or escalate to a developer.
- **Cache hits / stale reads** → some hosts (WP Engine, Kinsta) cache
  `/wp-json/*` at the edge. Append `?_=$(date +%s)` to bust cache when
  read-after-write consistency matters.
- **`acf` field returns `[]` (empty array)** → no fields are REST-exposed
  for that post's CPT. Not an error, a config gap. See `acf-guide.md`.
- **Slow responses** → `/wp-json` root can be 200+ KB on plugin-heavy
  sites. Cache the root response locally; don't refetch every call.
- **Bulk write rate-limits / 503s** → pace yourself. 0.3s between writes
  is a polite default; some hosts trip at 5 req/s.

## Anti-patterns — don't do these

- **Don't put the literal password on the curl command line.** Always
  interpolate from the OS secret store inline. The password should never
  exist as a standalone shell variable; if it does, shell history can
  capture it.
- **Don't assemble `AUTH="-u $WP_USER:$WP_PASS"` and use `curl $AUTH …`
  unquoted.** Word-splitting on whitespace in the password leaks
  fragments into argv. Always inline-quote: `curl -u "$WP_USER:$WP_PASS"`.
- **Don't omit `Content-Type: application/json` on writes.** WordPress
  treats missing/wrong content-type as form-encoded and silently drops
  nested objects (the `acf` key, the `meta` key).
- **Don't loop hundreds of REST calls without delays.** Hosts WILL 503
  you. Either pace at 0.3s+ between writes, or escalate the task to a
  developer with SSH/WP-CLI.
- **Don't retry blindly on 4xx.** 4xx means the request itself is wrong;
  retrying just hammers the server.
