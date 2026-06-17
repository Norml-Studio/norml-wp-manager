# Safety Rules — Reference

Every operation falls into one of three buckets. This is the single most
important reference in the skill — apply it on every request before doing
anything.

## Safe (run immediately, then report)

Read-only or low-risk single-item operations. No confirmation needed.

- Any `GET` against `/wp-json/wp/v2/*` for reading content, post types,
  taxonomies, users, settings, media, comments
- `GET /wp-json/wp/v2/users/me` (your own identity)
- Listing posts, pages, custom post types (default + with filters)
- Reading ACF field values via `GET /wp/v2/posts/{id}?context=edit&_fields=acf`
- Reading SEO meta via `?context=edit&_fields=meta`
- Listing categories, tags, custom terms
- Listing plugins / themes (admin endpoints, read-only)
- Updating one specific post's title, content, status, or slug **when the
  user has named the specific post**
- Setting the featured image on one specific named post
- Creating one new draft post or page
- Updating one ACF field value on one specific named post
- Updating one named user's profile fields (display name, bio) — **not**
  role changes
- Creating a single category, tag, or custom taxonomy term
- Setting a single menu item's label

Pattern: read everything; update single named items.

## Confirm (show the endpoint + body, ask for "yes" before running)

Anything that mutates configuration, multiple items, or touches the
permission/role layer. Always print the exact endpoint, method, and
body — and the target — before asking.

### Content (bulk or status changes)

- Bulk post updates affecting more than 5 items
- `DELETE /wp/v2/posts/{id}` (single or many — always Confirm, even one)
- Changing `post_status` to `trash` / `private` on published content
- Creating or deleting menus, menu items in bulk
- Bulk media operations (uploads of >5 items, deletes)
- Permanently deleting media (`?force=true`)

### Users

- `POST /wp/v2/users` to create a new user **especially with admin role**
- `POST /wp/v2/users/{id}` to change roles (especially elevating to admin)
- `DELETE /wp/v2/users/{id}` (always — losing a user destroys their
  authored content unless `reassign` is set)
- Password resets via `POST /wp/v2/users/{id}` with `password` field
- Bulk role changes

### Settings

- `POST /wp/v2/settings` for `title`, `description`, `posts_per_page`,
  `default_category`, `default_post_format`, `language`, `timezone`,
  `date_format`, `time_format`, `start_of_week`
- Anything touching `url` or `home` is Stop-tier (see below)

### Plugin endpoints

- Any `POST` / `DELETE` against a plugin's own namespace
  (`/rankmath/v1/*`, `/wc/v3/*`, `/acf/v3/*` writes, etc.). Body shapes
  are plugin-specific — show the exact body before sending.

### ACF — multi-field or multi-post writes

- Updating ACF field values on more than one post in a single batch
- Writing to ACF repeater or flexible-content fields (these are
  position-sensitive — wrong shape can corrupt all rows)

## Stop (refuse without explicit, in-session re-authorization)

The REST API physically can't do most truly destructive things — no
`wp db reset`, no `rm`, no plugin code edits. The Stop bucket is a small
set of "REST-reachable but high-blast-radius" operations.

### Operations that can lock the user out of their own site

- `POST /wp/v2/settings` changing `url` or `home` (often locks login;
  no clean revert from REST)
- Deleting the last administrator user (regardless of `reassign`)
- Demoting all administrators to non-admin roles in one batch
- Removing the site's only login method (no 2FA backup, no admin email
  set, then changing the admin email to an inbox the user can't reach)

### Operations the REST API exposes but managed hosts usually disable

- `POST /wp/v2/plugins` (install / activate)
- `DELETE /wp/v2/plugins/{slug}`
- `POST /wp/v2/themes` (activate)

For these, **do not retry** if the host returns 404. Tell the user to
do it in wp-admin → Plugins / Appearance, or to ask their developer.

### Bulk destructive operations

- Bulk `DELETE` against >5 posts/pages/users at once
- Bulk media delete with `?force=true`
- Wiping comments en masse

If the user genuinely needs to proceed with a Stop-tier op:

1. Acknowledge the risk in the same session ("I understand the site
   could go offline.")
2. Confirm a backup exists ("I have a backup from {date}.")
3. Re-read the full endpoint + body back to them word-for-word.

Even with all three, prefer escalating to a developer.

## When you don't know what bucket

Default to **Confirm**, never to Safe. If you can't decide between
Confirm and Stop, treat it as Stop.

## Backup discipline

Before any Confirm or Stop operation, ask:

> "When was your last backup? Where is it?"

If the user can't answer, suggest taking one first. The REST API doesn't
have a backup endpoint — point them at:

- Their hosting provider's backup feature (most managed hosts have one)
- A backup plugin (UpdraftPlus, BackWPup) if installed
- Their developer if neither is available

The user can decline, but they should at least know they declined.

## Rotation (when a secret leaks)

If the Application Password was printed in chat, written to a file it
shouldn't be in, or otherwise exposed:

1. Tell the user immediately.
2. Have them revoke it in wp-admin → Users → Profile → Application
   Passwords → click the **X** next to the named password. The token
   dies immediately.
3. Re-run onboarding to generate and store a fresh one.
4. Remove any local file the password was leaked into. If it was in a
   shell history, run `history -c` (macOS bash) or
   `Clear-History; Remove-Item (Get-PSReadlineOption).HistorySavePath`
   (PowerShell).

If the user's WordPress login password was leaked (not just the
Application Password), they should change it via wp-admin → Users →
Profile → Set New Password, and also revoke all Application Passwords
to be safe.

## Error escalation

When something goes wrong (401, 403, 404, 5xx, connection refused):

- **Don't retry destructively.**
- **Don't "fix" by reverting or deleting state.**
- Report the exact HTTP status and the response body, and stop.
- For 5xx, suggest the user check their host's status page; rate
  limiting is the most common cause of intermittent 5xx in a script.
- For connection refused / DNS / timeout, suggest opening the site URL
  in a browser to confirm it's actually up.
