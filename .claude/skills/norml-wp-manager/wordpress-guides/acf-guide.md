# ACF Guide — Reference

How Advanced Custom Fields stores data and how to read or write fields
via the WordPress REST API. Read this before touching any ACF field —
the wrong write path silently does nothing or corrupts data.

## What ACF is

A plugin (`advanced-custom-fields` or `advanced-custom-fields-pro`) that
adds typed custom fields to posts, pages, users, comments, options
pages, taxonomy terms, etc.

The user usually sees ACF in two places:

1. **Custom Fields → Field Groups** in wp-admin — where field groups
   are defined.
2. **The post editor** — where field values get filled in.

## What this skill can and can't do with ACF

This skill writes through the WordPress REST API, not through WP-CLI or
PHP. That has consequences.

### What works

- Reading field VALUES on REST-exposed field groups
- Writing field VALUES via the `acf` payload key on posts, when the
  field group has `show_in_rest: true`
- Reading the list of post types, taxonomies, and (if you have admin
  role) plugins to confirm ACF Pro is active
- Reading existing values to round-trip an edit

### What doesn't work from REST

- Creating or editing field group **definitions** — that's theme code
  work. Even ACF Pro 6.1+ Post Types UI (which stores CPTs in DB) isn't
  a REST-exposed surface by default.
- Writing values when the field group lacks `show_in_rest` — REST
  silently no-ops, you read back the old value.
- Writing complex types (repeater, flexible content) when they're not
  REST-exposed — `acf-json/`-bound projects have an extra layer of
  drift between DB + theme code.

If the user needs to add or edit field group DEFINITIONS, route them to
their developer. This skill does not touch theme code.

## Reading values

Use `?context=edit&_fields=acf` on the post:

```http
GET /wp-json/wp/v2/posts/42?context=edit&_fields=acf
```

Response:
```json
{
  "acf": {
    "hero_headline":  "Spring launch",
    "hero_subhead":   "All new collection",
    "faq_items": [
      { "question": "Q1?", "answer": "A1." }
    ]
  }
}
```

If you get `"acf": []` (empty array, not empty object), the post's CPT
has no REST-exposed ACF fields. Reading by name returns nothing because
the field group's `show_in_rest` is `false`.

## Writing values

Include an `acf` object on the post body. ACF Pro auto-routes it on save:

```http
POST /wp-json/wp/v2/posts/42
Content-Type: application/json

{
  "acf": {
    "hero_headline": "Spring launch",
    "hero_subhead":  "All new collection"
  }
}
```

After writing, **re-read** to confirm:

```http
GET /wp-json/wp/v2/posts/42?context=edit&_fields=acf.hero_headline
```

If the value didn't change, the field group isn't REST-exposed. Tell the
user.

## Field types — what to know when writing

### Text, textarea, number, email, url, password
Plain string/number. Send the value as-is.

### Select, radio
Send the option **key**, not the label. Read the field group definition
to confirm the key/label mapping.

### Checkbox, multi-select
Send a JSON array of selected keys:
```json
{ "services": ["web", "branding"] }
```

### True/False (boolean)
Send a boolean:
```json
{ "featured": true }
```

### Image, file
Send the attachment **ID** (integer). To set an image, upload to
`/wp/v2/media` first, capture the returned `id`, then write it:
```json
{ "hero_image": 318 }
```

### Link
Send the array shape ACF expects:
```json
{ "cta_link": { "url": "https://example.com/about", "title": "About", "target": "_self" } }
```

### Post Object / Relationship
Send the post ID (single) or array of IDs:
```json
{ "related_post": 19 }
{ "related_posts": [19, 22, 31] }
```

### Page Link
URL string.

### Taxonomy
Send the term ID or array of term IDs.

### User
Send the user ID or array of user IDs (depending on field config).

### Date Picker, Date Time Picker, Time Picker
String in the field's configured return format. Read what's there before
writing — formats vary: `YYYYMMDD`, `YYYY-MM-DD HH:MM:SS`, etc.

### Color Picker
Hex string with `#`: `"#1a4d2c"`.

### Google Map
Object shape:
```json
{ "location": { "address": "1 Market St", "lat": 37.79, "lng": -122.39, "zoom": 14 } }
```

### Repeater (ACF Pro)
Send a JSON array of row objects:
```json
{
  "services": [
    { "title": "Web design", "description": "…" },
    { "title": "Branding",   "description": "…" }
  ]
}
```

**Watch out:** writing a repeater REPLACES the whole list. To append,
read the current value first, then write the union.

### Flexible Content (ACF Pro)
Same idea as repeater, but each row has `acf_fc_layout` naming which
layout:
```json
{
  "page_blocks": [
    { "acf_fc_layout": "hero",   "title": "…", "subtitle": "…" },
    { "acf_fc_layout": "two_col","left": "…",   "right": "…" }
  ]
}
```

### Group (ACF Pro)
A nested object:
```json
{ "social_links": { "twitter": "@acme", "linkedin": "acme-co" } }
```

### Clone (ACF Pro)
Behaves like the cloned group — same shape.

## Options pages

If the theme registered an ACF options page (`Site Settings`, `Footer`,
etc.), values live in `wp_options`, not on a post. **This skill cannot
write ACF options pages via REST** — there's no built-in endpoint for
them. The user has two paths:

1. Edit options page values via wp-admin (the user opens the options
   page and types).
2. Ask their developer to add a custom REST endpoint that wraps
   `update_field(..., "option")`.

If the project has the *ACF to REST API* companion plugin installed, an
`/acf/v3/options/{key}` namespace appears. Check
`site-architecture.md` → REST namespaces.

## ACF JSON sync — when to be careful

If the theme has an `acf-json/` directory:

- The team's developers maintain field group **definitions** in code
  and commit them to git.
- Editing field groups in wp-admin is fine for testing but the JSON
  file is the source of truth on the next deploy.
- This skill **never** modifies `acf-json/` files — that's theme code
  and we don't touch the filesystem.

Field VALUES (what's filled into the fields on a post) are always
DB-only — JSON sync doesn't touch values. So writing values from REST
is fine; the next deploy won't overwrite.

## When the user says "the field doesn't exist" or "my write didn't land"

Four causes, in order of likelihood:

1. **The field group isn't REST-exposed.** Read with `_fields=acf` —
   if you get `"acf": []`, that's the cause. The fix is theme-side
   (the developer adds `show_in_rest: true` to the field group).
2. **Caching.** Some hosts cache `/wp-json/*` responses. Append
   `?_=$(date +%s)` to the URL when re-reading after a write.
3. **Field name vs label confusion.** ACF stores by *field name*
   (snake_case in the field group definition), not the label. If the
   site uses ACF Pro and you have admin, you can list field group
   definitions via `GET /wp-json/wp/v2/acf-field-group?context=edit`
   (when the field group is REST-exposed itself).
4. **Field group's Location rules don't match.** A field group might
   be defined but only show on certain post types or templates. Reading
   via REST returns null for posts the field group doesn't apply to.

## What you should NEVER do with ACF (from this skill)

- Try to register field group definitions via REST. This skill doesn't
  do theme code.
- Bulk-write repeater fields without reading their current shape first
  (you'll wipe rows).
- Write an ACF field on a post when you're not sure the field group
  applies to that post's type — you may be writing meta that nothing
  reads.
- Trust silent success. **Always re-read after a write.** ACF silently
  ignores writes for un-registered or un-REST-exposed fields.
