---
name: norml-wp-manager
version: 1.1.1
requires_onboarding: true
description: >
  Norml WordPress Copilot: manage a single WordPress site through the
  WordPress REST API from Claude Desktop / Cowork, Claude Code, Codex, or
  Gemini CLI.
  For non-technical site owners — no SSH, no WP-CLI, no developer tooling.
  Needs WordPress 5.6+ and an admin or editor Application Password. All
  state for a site lives in one portable folder you name: generated
  `capabilities.md`, readable `project-notes.md` + `changelog.md` at the top, machinery in a hidden
  `.wpm/` (connection config + the auto-generated site scan; the
  credential only when no OS keychain is available). Detects a supported CLI
  runtime (Console) vs Claude Desktop / Cowork (Desktop) and acts
  accordingly; on Desktop it verifies your site is reachable before
  asking for any credential. The Application Password lives in macOS
  Keychain / Windows Credential Manager / Linux libsecret on Console, or
  a local browser-to-folder handoff on Desktop — the credential never enters
  the AI conversation and is immediately imported into a born-private,
  gitignored file. Use when the user says "WordPress Copilot," "manage my WordPress,"
  "edit a post," "update content," "list plugins," "what's my theme,"
  "scan my site," "publish a draft," "find an ACF field," "update SEO
  meta," "upload a featured image," "set up WordPress access,"
  "norml-wp-manager," or "/norml-wp-manager." Refuses destructive ops
  without explicit confirmation; never asks for a password in chat.
metadata:
  author: "Norml Studio"
---

# Norml WordPress Copilot

Installed skill: `norml-wp-manager`

> **Requires onboarding.** Before this skill can do anything, the site must be
> connected once. If no `*/.wpm/config.json` is found (Console: walking up from
> the working directory; Desktop: in the mapped project folder), hard-stop and
> route to onboarding — **Console → `onboarding-console.md`**, **Desktop →
> `onboarding-desktop.md`** — never improvise the connection by asking for the
> Application Password in chat.

> **REST API only.** This skill talks to WordPress exclusively over its built-in
> REST API at `/wp-json/`. It does **not** use SSH, does **not** use WP-CLI,
> does **not** touch the server filesystem. That makes it safe to hand to a
> site owner who has WordPress admin access but no developer tooling. The
> trade-off: anything the REST API can't do, this skill can't do — bulk DB
> operations, plugin/theme install on most managed hosts, `wp eval` PHP,
> search-replace. Those belong to a developer using WP-CLI directly.

## One mental model

Everything Claude knows about a site lives in **one folder the user names** (e.g.
`acme-marketing/`). Three human-readable files sit at the top (`capabilities.md`,
`project-notes.md`, `changelog.md`); a hidden `.wpm/` subfolder holds the machinery (connection
config, the credential when applicable, the auto-generated site scan). Delete the
folder and the skill forgets the site — nothing else on the machine is touched.

```
acme-marketing/                    ← THE unit. User-named, visible, one per site. Portable, zip-safe, update-safe.
├── README.md                      ← 4 plain lines: what this is / move / delete / "don't hand-edit .wpm/"
├── capabilities.md                ← generated contract: what this account can do here. Rewritten on capability rescan.
├── project-notes.md               ← durable human/AI knowledge. Hand-editable. Survives rescans.
├── changelog.md                   ← append-only op + decision + [SCAN] log. Human-readable audit trail.
└── .wpm/                          ← the machinery (dotted = hidden, brand-neutral).
    ├── config.json                ← connection config, schema_version 4. NO secret. chmod 600.
    ├── credential                 ← AP, RAW string. born chmod 600. gitignored. FLOOR TIER ONLY (absent on OS-keychain).
    ├── .gitignore                 ← lives HERE, beside the secret. One line: credential
    └── docs/                      ← auto-generated scan layer. Read-before-operate. Do-not-hand-edit.
        ├── README.md              ← doc index + rescan map + read-order contract
        ├── 00-connection.md       ← env, network-gate result, auth, user+roles, secret pointer, last_scan_at
        ├── 01-site.md             ← WP version (best-effort), settings, REST namespaces, multisite hint
        ├── 02-content-model.md    ← post types (per-type show_in_rest), taxonomies, content counts
        ├── 03-plugins-theme.md    ← active theme, plugin inventory, detected key plugins, 3rd-party agents
        └── 04-rest-capabilities.md← writability matrix + known blockers + "What REST cannot see"
```

**Hard invariants (non-negotiable):**

1. **One user-named folder per site. No `~/.config/` anywhere, ever** — not
   written, read, probed, or created as a side effect.
2. **Per-site state never lands inside the skill folder** (`~/.claude/skills/…`
   or the desktop skill mount) — skill updates wipe it.
3. **Network reachability is proven before any credential is created or handed off** (Desktop).
4. **The credential never enters argv or the AI transcript, and is born
   private on disk.** The v2.3.0 `-u "$user:$pass"` pattern is a **vulnerability**,
   not a mitigation.
5. **No security claim the platform doesn't deliver** — no false "owner-read only"
   where the filesystem ignores POSIX perms.

Config is resolved at runtime by walking for `*/.wpm/config.json` — NEVER a
literal folder name, NEVER `~/.config`. The site folder is always **derived** from
the `.wpm/` parent, so `config.json` stores zero paths that escape the folder.

## Where this skill runs — two environments

The skill detects its environment once per session and acts accordingly.

- **Console** = Claude **Code** (terminal). A real local shell: the OS secret
  store is reachable, an OS dialog can pop, and outbound network is unrestricted.
- **Desktop** = the Claude **desktop app** + **Cowork**. A cloud sandbox: no OS
  secret store, no OS dialog, and a default-deny egress allowlist. The bundled
  local `connect.html` writes a short-lived handoff directly into the selected
  site folder, outside the AI conversation. **This is the
  PRIMARY distribution target.**

### `env` values (four cells)

`console-macos` | `console-windows` | `console-linux` | `desktop`. Set once at
setup, written to `config.json`, held for the session. Governs secret lookup, the
network gate, and 403 disambiguation.

### Detection by probe (first decisive signal wins)

- **PROBE-P (platform):** `uname -s` → Darwin / Linux / `MINGW*`|`MSYS*`|`CYGWIN*`
  (Windows = PowerShell).
- **PROBE-E (egress — THE decisive tell):**
  ```bash
  curl -sS -o /dev/null -w "%{http_code}" --max-time 8 https://example.com
  ```
  `200`/`30x` = outbound OPEN (Console-like); blocked / `000` / curl exit
  6/7/35/56 = a default-deny allowlist is present = **DESKTOP**. **Probe a NEUTRAL
  host (example.com), not anthropic.com** — package / GitHub / Anthropic hosts are
  allowlisted and would pass even inside a sandbox, defeating the test.
- **PROBE-K (OS secret store — only if PROBE-E is OPEN):** macOS
  `command -v security`; Windows `lib/credman.ps1` resolves; Linux
  `command -v secret-tool` **AND a store→lookup→delete round-trip succeeds** →
  libsecret, else FLOOR. (The binary can exist while the D-Bus secret service
  isn't running — headless/WSL/SSH — so the round-trip is mandatory; any failure
  silently degrades to FLOOR, never blocks setup.)
- **PROBE-D (OS dialog — confirms the Console capture path):** macOS `osascript` /
  Windows `PromptForCredential` succeeds.

### Router decision

```
IF PROBE-E BLOCKED                          → env = DESKTOP  (storage = FLOOR; run NETWORK GATE before any credential)
ELIF PROBE-E OPEN and a secret store passes → env = CONSOLE  (storage = that OS store)
ELIF PROBE-E OPEN but no secret store       → env = CONSOLE  (storage = FLOOR; e.g. Linux server / WSL, no keyring)
ELSE / no writable folder & no shell        → UNSUPPORTED (claude.ai web/mobile) — say so, point at Console or Desktop
```

**Anti-false-positive rules:**

- Never conclude Desktop from `uname=Linux` alone — WSL and Linux servers are
  **Console** (network open, no keyring → FLOOR, no gate).
- Never conclude Console from "Keychain present" without running PROBE-E first.
- A timeout where even anthropic.com is unreachable = a **dead network** ("your
  machine has no internet right now"), **not** Desktop.

> This **replaces v2.3.0's "is `~/.config/` writable?" check**, which mis-routed
> sandboxes with a writable `$HOME` and never gated on network. The egress probe
> is the single signal that separates "Linux Console, no keyring → file, network
> open, NO gate" from "Desktop sandbox → file, network BLOCKED, gate REQUIRED."

### First-run setup is environment-specific

Don't improvise it here. **Console → `onboarding-console.md`** (no gate).
**Desktop → run the NETWORK GATE first, then `onboarding-desktop.md`.** See the
Pre-flight router below for the exact branch.

## When to use

Any request to read, change, or audit content on the user's WordPress site —
posts, pages, custom post types, ACF field values, SEO metadata, media,
users, categories, settings.

Typical asks:

- *"List my plugins"* / *"What's my theme?"*
- *"Show me my last 10 posts."*
- *"Update the title of post 42 to 'Spring launch.'"*
- *"Publish the draft called 'New pricing page.'"*
- *"What ACF fields does the homepage use? What are their current values?"*
- *"Set the featured image on post 42 to {filename}."*
- *"Update the SEO title and description on the /about page."*
- *"Add a category called 'Insurance Tech.'"*
- *"Who are the admin users on this site?"*
- *"Scan my site again — I activated a new plugin."*

## Skip if

- The user needs to **install, activate, or update a plugin or theme.** Most
  managed hosts disable `POST /wp/v2/plugins`. Tell the user to use wp-admin
  (Plugins → Add New) or have their developer do it via SSH/WP-CLI.
- The user needs to **edit theme code, plugin code, `functions.php`, or any
  PHP file.** That's developer territory — this skill never touches files.
- The user needs **bulk database operations** (search-replace, mass schema
  updates, `wp_options` rows that aren't REST-exposed). REST is too slow and
  the surface is too narrow. Escalate to a developer.
- The user wants to **migrate a whole site** between environments. Different
  workflow entirely.
- The user is doing a **code-level architecture audit** of the WordPress
  install. This skill operates inside wp-admin's surface, not under it.

## Pre-flight (run every session, before the first WP operation)

### Step 1 — Detect the environment

Run the probes above (PROBE-E first, then PROBE-K / PROBE-D as needed). Decide
`env` via the router decision table. **Hold `env` for the whole session** — it
changes how the credential is looked up, whether a network gate is required, and
how a 403 is diagnosed.

### Step 2 — Resolve the site folder + resume-or-onboard

- **Console:** walk up from the current working directory for `*/.wpm/config.json`.
  **There is no `~/.config` branch** — drop it entirely.
- **Desktop:** look in the mapped project folder for `.wpm/config.json`.
- **Found + `config.env` matches the detected env** → **RESUME** (go to Step 3).
- **Found but env mismatches** (e.g. a Console keychain config opened in Desktop) →
  tell the user this site was set up for the *other* environment, offer a fresh
  setup, and **never silently reuse a keychain pointer that can't resolve in a
  sandbox.**
- **Absent** → **FIRST-RUN.** Branch on `env` and follow EXACTLY ONE runbook —
  **Console = no gate (`onboarding-console.md`); Desktop = NETWORK GATE FIRST
  (`onboarding-desktop.md`).** Do not interleave the two.
- Templates are **READ** from the skill folder but **NEVER written back there**. If
  the skill isn't at `~/.claude/skills/` (Cowork mounts it elsewhere), write
  minimal inline versions of the curated files so setup still completes.
- A v3 config (found at the old `~/.config/norml-wp-manager/config.json` **or**
  `{project}/norml-wp-manager/config.json`) → **offer one-time migration**, never
  silently dual-home. See `wordpress-guides/safety-rules.md` and the changelog migration
  note; carry `project-notes.md` + `changelog.md` over verbatim, reuse (or
  cleanly re-key) the keychain entry, and **rotate** a floor secret rather than
  byte-copying it.

### Step 3 — Load the doc set before any WP op, in this exact order

1. **`.wpm/docs/00-connection.md`** — env, who you're connected as + roles, secret
   pointer, last scan time.
2. **`capabilities.md`** — *what can I actually do here.* This is the visible,
   generated operating contract. Consult
   **BEFORE any write.**
3. **`.wpm/docs/02-content-model.md`** — does the target post type have
   `show_in_rest`?
4. **`project-notes.md`** (site-folder top level) — surface gotchas; if the user is
   editing the homepage and notes say "uses Elementor," lead with that.
5. The **last ~20 lines of `changelog.md`** (site-folder top level) — so you don't
   blindly conflict with, repeat, or undo a recent deliberate change.

If `00`–`04` are missing → run the **scan (all stages) inline first** (Stage 0
gates everything; see "Scaffold + scrape"). If `last_scan_at` is >7 days old,
mention it once and proceed unless the user declines.

### Step 4 — Operate-phase gate (NEW hard rule)

Before any write, check `04`/`02`. If the target surface is **not REST-exposed** or
**not writable at the connected role**, do **NOT** fire a doomed request. Tell the
user: *"this CPT/field isn't reachable over REST; edit it in wp-admin, or have a
developer flip `show_in_rest`,"* and append a `[LEARNED]` line to `changelog.md`.

> **Never** ask the user for the Application Password in chat in any environment.
> Console captures it through a native OS dialog. Desktop / Cowork captures it in
> the bundled local `connect.html` handoff, which writes a short-lived,
> git-ignored file that the importer deletes immediately after authentication.

## How operations work

Every WordPress operation is an HTTPS call to `{production_url}/wp-json/...`,
authenticated with HTTP Basic Auth using the WordPress login slug plus the
Application Password retrieved at runtime. There is **exactly one** sanctioned auth
call form and **exactly one** sanctioned secret reader.

### The only sanctioned secret reader

`get_password()` is the single reader. It never echoes the value — it pipes it
straight into the auth call.

```bash
get_password() {   # resolves the AP for the active tier; prints to stdout for piping only
  case "$SECRET_KIND" in
    macos-keychain)             security find-generic-password -s "$SECRET_REF" -w ;;
    linux-libsecret)            secret-tool lookup service "$SECRET_REF" ;;
    windows-credential-manager) : ;;   # Windows uses the PSCredential path below, never this
    portable-file)              cat "$SITE_FOLDER/.wpm/$SECRET_REF" ;;   # floor: raw string file
  esac
}
```

(`$SECRET_KIND` / `$SECRET_REF` come from `config.json` `secret_store.kind` /
`secret_store.ref`. `$SITE_FOLDER` is derived from where `config.json` was found.)

### The only sanctioned auth call

```bash
restcall() {   # $1 = endpoint path (e.g. /wp/v2/users/me), $2.. = extra curl args
  local ep="$1"; shift
  curl -sS --proto '=https' --max-redirs 0 \
    --config <(printf 'user = "%s:%s"\n' "$WP_USER" "$(get_password)") \
    -H "Accept: application/json" "$@" "${PROD_URL}${ep}"
}
```

**Mandate and forbid, explicitly:**

- `--config <(...)` (process-substitution FD) is **mandatory**: curl's argv shows
  only `--config /dev/fd/NN`; the `user = "..."` line travels over a pipe — never on
  disk, never in argv, and `set -x` renders the FD path, not the bytes.
- **FORBIDDEN: a real curl config file** (`-K /tmp/wpm-curl.cfg`) — it trades an
  argv leak for a world-readable-`/tmp` leak. Recorded as a rejected alternative so
  no contributor "hardens" the FD form into it.
- Every authenticated call carries **`--proto '=https' --max-redirs 0`** so a
  compromised site can't bounce the Basic-auth header to another origin.
- **Windows / PowerShell:** build a `PSCredential` and call
  `Invoke-RestMethod -Authentication Basic -Credential $cred` (the secret stays a
  `SecureString`). **Do NOT** shell out to `curl.exe -u`.

> **Vulnerability reclassification.** The v2.3.0 `-u "$user:$pass"` pattern is a
> **vulnerability**, not a mitigation. It leaks the credential into `ps`,
> `/proc/<pid>/cmdline`, and auditd, and — under `set -x` — into the Bash-tool
> transcript. It is removed from every script and every command template in this
> document. Do not reintroduce it.

**Two genuinely-correct rules carried over from v2.3.0 (keep them):**

- **Always send `Content-Type: application/json` on writes**, otherwise WordPress
  treats the body as form-encoded and silently drops nested objects (the `acf` key,
  the `meta` key).
- **Use `?context=edit` when reading data you intend to write back** — without it,
  `context=view` strips the raw + meta payloads and the round-trip becomes
  impossible.

## Secret-storage ladder

Two rungs. **There is no Rung 3.** No crypto theater.

| Rung | When | Mechanism |
|---|---|---|
| **1 — OS secret store** (preferred) | **Console only** | A real OS vault: macOS Keychain (`security`, write via **stdin** not `-w`), Windows Credential Manager (P/Invoke), Linux libsecret (**only if the round-trip probe passes**). The secret never enters chat, never touches a file; captured by a native OS dialog, looked up inline at call time. Service name `norml-wp-manager-{site}`. |
| **2 — FLOOR: gitignored, born-private raw file** | ALL of Desktop + Linux/Windows console without a working vault | `{site_folder}/.wpm/credential`. Born private: `( umask 077; printf '%s' "$ap" > tmp ); mv -f tmp credential` — **NOT** create-then-`chmod` (which leaves a brief world-readable window). Read via `get_password()` (`cat`), never echoed. Windows floor: lock the ACL with `icacls "<file>" /inheritance:r /grant:r "$env:USERNAME:M"` **before** writing content (POSIX `chmod` is a no-op on NTFS). |

**No Rung 3 (stated plainly, protect it).** There is no zero-infra way to encrypt
the floor file meaningfully — any key the skill could auto-decrypt with must sit on
the same disk as the file it protects. A per-session passphrase is unacceptable UX
for a non-technical owner. The floor is **honest plaintext**, protected by
filesystem perms + git-exclusion. **No contributor may add a fake "encrypted
credential store."**

**The real mitigations carry the weight crypto can't:**

- **Least-privilege editor-role AP by default** — admin only when the task needs
  plugin/theme/settings endpoints. A leaked editor AP can't install plugins, edit
  users, or escalate.
- **AP ≠ login password** — independently revocable; always say so.
- **Monthly rotation** for any standing floor secret.
- **End-of-Desktop-session rotation as the DEFAULT close-out** (not "consider it").
  The skill proactively offers to walk the revoke when a Desktop session that
  handled the AP ends.
- **No argv / no trace / no echo** — the `--config <(...)` form, `set +x`, and never
  `cat`/`echo` the credential to stdout.
- **Assertive gitignore gate (BLOCKING)** — after writing `credential`, if git is
  present run `git check-ignore`; if it does NOT return the path, **STOP and back
  the credential out**, don't merely assert the line exists.
- **HTTPS only** — `production_url` must be `https://` for any AP-bearing call;
  warn-and-allow only for explicit `localhost`.

**Honest caveat (no false claims).** On a Windows-host Desktop session where the
floor file can't be ACL-locked from the sandbox, the skill **MUST NOT** report
"owner-read only." It says plainly: *"On this setup the file's OS permissions can't
be locked to you — treat the folder as readable by anyone with an account on this
PC; rotate weekly and use an editor AP."*

## Safety classification (apply to every request)

Cross-reference against `wordpress-guides/safety-rules.md`. Three buckets:

- **Safe** — read-only or low-risk single-item edits. Run immediately, then
  report. Examples: `GET /wp/v2/posts`, `GET /wp/v2/users/me`, updating one
  named post's title, attaching a featured image to one post, updating one
  ACF field value on one post.

- **Confirm** — anything that mutates multiple items, changes
  site-wide settings, creates/deletes users, or trashes published content.
  Show the exact endpoint + body you intend to send, the affected target,
  and ask for an explicit "yes" in the same session before executing.
  Examples: `POST /wp/v2/settings` for site title / posts_per_page,
  `POST /wp/v2/users` (especially with admin role), bulk content edits
  affecting >5 items, `DELETE /wp/v2/posts/{id}?force=true`, any change
  to `siteurl` or `home`.

- **Stop** — destructive or unsupported via REST. Refuse and explain. The
  REST API physically can't do most truly destructive operations (no
  `wp db reset`, no `rm`), but a few are still dangerous: changing
  `siteurl`/`home` (often locks the user out), demoting the last
  administrator, bulk-deleting users with content. If the user insists,
  point them at a backup first and have them confirm the risk explicitly.

When in doubt, treat as Confirm, not Safe.

## Project knowledge layer — the site folder

The site folder is **the canonical knowledge store for everything norml-wp-manager
knows about this WordPress site**. It is the main point of context for every future
session. It is designed to **compound knowledge over time** — every session leaves
the folder richer than it found it. There are **two trust layers**.

### Two-layer trust split

**(a) Generated layer — `.wpm/docs/00–04` (do-not-hand-edit).** Auto-written by the
scan, **overwritten by rescan**. Each file opens with a frozen header:

```
<!-- GENERATED by norml-wp-manager scan — DO NOT EDIT BY HAND. Rescan rewrites this file. -->
_Scanned: {ISO-8601} · Connected as: {user} ({roles}) · Tier: {secret_store.kind} · env: {env}_
```

…and **ends with a `What REST cannot see here` fenced block** (the honesty ceiling).
Anything that should survive a rescan does **not** go here — it goes in
`project-notes.md`.

**(b) Visible operating layer — top-level `capabilities.md`.** Generated from the
Stage 4 REST checks and overwritten on a capability rescan. It is the short human/AI
contract for what this connected account can read, create, update, and delete here.

**(c) Curated layer — top-level `project-notes.md` + `changelog.md`.**
Hand/AI-editable, **never touched by a rescan.** (Templates KEPT verbatim from
v2.3.0; only the write location moved to the site-folder top level.)

### `project-notes.md` — how this site works

Durable knowledge that doesn't change with a rescan. Claude appends to it when it
learns something non-obvious. The user can edit freely. Four sections:

```markdown
# {Site Name} — WP management notes

> Durable knowledge about managing this site. Claude appends to this file
> when it learns something non-obvious. Humans can edit freely. Survives
> capability rescans.

## Workflows specific to this site

(How to do common things on THIS site. Add as the team develops
site-specific patterns. E.g. "Blog posts use category 'Updates' by
default, featured image must be 1200×630, RankMath title format is
'{Post title} — {Site name}'.")

## Discovered facts

(Claude appends one-liners with dates when it learns something
non-obvious during a session.)

## Known gotchas

(Things that don't work, things to avoid, workarounds in use.)

## Open questions

(Unverified assumptions, things to test next session.)
```

### `changelog.md` — what was done and decided

Append-only, chronological, at the **site-folder top level**. Every write operation
lands here. Significant decisions and discoveries also land here. The reader (Claude
or human) can scroll backward to answer "what's been done on this site, when, and
why?"

Format: newest entry on top. Per-day section. One line per logical change. Tags at
the start of each line:

- `[WRITE]` — content / postmeta change (post update, page update, ACF
  value, featured image)
- `[OPTION]` — `wp_options` or settings change (site title,
  posts_per_page)
- `[USER]` — user create / role change / delete / password reset
- `[MEDIA]` — upload / attach / update metadata / delete
- `[DECISION]` — policy / convention agreed with the user (e.g. "use
  category X for all blog posts going forward")
- `[LEARNED]` — non-obvious fact discovered during a session (e.g. "the
  case_study CPT isn't REST-exposed; ask the developer to flip
  `show_in_rest: true`")
- `[SCAN]` — architecture scan ran; what notable changed since the last
  one (or `[SCAN] … ABORTED at gate: {egress-blocked|unreachable|auth-failed}`)
- `[ROLLBACK]` — explicit undo of a previous write

Example:

```markdown
## 2026-05-20 — Spring sale launch + RankMath fixes

- 14:35 — [WRITE] Updated post 42 ("Spring sale") — title + body + set
  featured image (media #318). Was draft, now published.
- 14:32 — [DECISION] All blog posts use category "Updates" by default;
  confirmed with the user.
- 14:20 — [LEARNED] rank_math_focus_keyword isn't REST-writable on this
  site — the theme doesn't `register_post_meta(...,'show_in_rest'=>true)`.
  Wrote the value via wp-admin instead. Logged in project-notes.md →
  Known gotchas.
- 14:00 — [SCAN] First-time site architecture scan completed.
  RankMath SEO + ACF Pro active. 11 plugins. Active theme: child of
  "blocksy" (v2.0.30).
```

## Scaffold + scrape (init)

On first connect — and on demand thereafter — the skill scrapes the site over REST
into the five numbered docs in `.wpm/docs/`. The scan is **REST-only and
infra-free**.

**Five read-only REST stages. Stage 0 gates everything. "Degrade" = on a 403/empty
response at a higher-role endpoint, write "not visible at this role" into that doc's
blockers, never crash.**

| Stage | Endpoints (anon where marked) | Writes | Captures |
|---|---|---|---|
| **0 — Reachability + identity (GATE; first)** | `GET {url}/wp-json` (anon, the gate probe) → auth `GET /wp/v2/users/me?_fields=id,name,roles` | `00-connection.md` | anon probe result (Desktop: blocked at proxy → allowlist not set → hard-stop + run gate); auth user id/name/**roles**; `env`. **If 0 fails, 1–4 do NOT run.** |
| **1 — Site basics** | `GET /wp-json` (namespaces, description, gmt_offset) · `GET /wp/v2/settings` (admin; degrade to anon subset) | `01-site.md` | WP version (best-effort, marked approximate), title/tagline/language/posts_per_page/start_of_week, registered REST namespaces, multisite hint |
| **2 — Content model** | `GET /wp/v2/types` · `GET /wp/v2/taxonomies` · `HEAD …/posts` · `HEAD …/pages` · per-CPT `HEAD /wp/v2/{rest_base}?per_page=1&status=publish` | `02-content-model.md` | post types with **`show_in_rest` per type**, `rest_base`/`hierarchical`/`viewable`; taxonomies + attach map; counts via `X-WP-Total` |
| **3 — Plugins + theme** | `GET /wp/v2/plugins` (admin) · `GET /wp/v2/themes` (admin) · derive from namespaces | `03-plugins-theme.md` | active theme name+version; plugin inventory grouped by function; detected 3rd-party admin agents; degrade to "not visible at this role" |
| **4 — REST capability map (derived)** | `OPTIONS` on posts/pages/media + per-CPT (Allow/methods) · `HEAD …/users?roles=administrator` · derive | `.wpm/docs/04-rest-capabilities.md` + top-level `capabilities.md` | detailed evidence plus the visible writability contract at the connected role; known blockers; master **"What REST cannot see"** |

**"What REST cannot see" (in every doc, mastered in `04`):** exact WP core version;
PHP/MySQL/server stack/DB size/table prefix/custom tables; `wp-config.php`
constants; cron events; theme file tree / `functions.php` / template hierarchy /
enqueued assets; ACF field-group **definitions** (per-post values may be visible via
`?context=edit`, the schema is not); page-builder data shape (`_elementor_data`
opaque blob); plugin settings in `wp_options`; **CPTs/taxonomies with
`show_in_rest: false` are invisible to REST entirely** — with an explicit warning
that the site may have more types than REST sees.

**Role-requirement honesty.** An editor AP fully populates `00`, `02`, and most of
`04`; `01` settings + `03` plugins/themes need **admin** → without admin those carry
"not visible at this role" and `04` notes the gap. Non-fatal.

### Rescan map

`scan-site.sh --site-folder {path} --stage {0|1|2|3|4|all}` — **Stage 0 always
re-runs first** as a cheap reachability re-check.

| User says | Stage(s) | Rewrites |
|---|---|---|
| "rescan my site" / "refresh architecture" / "I installed a plugin" | `all` | `00–04` |
| "recheck connection" / "is my site reachable" | `0` | `00` |
| "refresh site basics" | `0,1` | `00,01` |
| "redo content model" / "I added a custom post type" | `0,2` | `00,02` |
| "rescan plugins" / "re-check the theme" | `0,3` | `00,03` |
| "recheck what I can edit over REST" | `0,4` | `00,04` |

**Rescan rules:** overwrite ONLY the targeted docs; **never** touch
`project-notes.md` / `changelog.md`; **diff-before-overwrite** and print a per-doc
delta ("post types: +1 `portfolio`; plugins: +Yoast, −WP Rocket"); append **one**
`[SCAN]` line to `changelog.md` (or `[SCAN] … ABORTED at gate: {egress-blocked |
unreachable | auth-failed}` on a Stage-0 failure — the scan must stop swallowing
403 silently); write `config.json.last_scan_at`. Staleness: pre-flight reads
`last_scan_at`; if >7 days, mention once, proceed unless declined.

## Write-back rules — how the skill compounds knowledge

The whole point of the site folder is that **every session leaves it richer than it
found it**. Three triggers for writing back; treat them as defaults, not exceptions.

### When to append to `changelog.md`

Append an entry **before closing any response that mutated the site**. This is the
audit trail the user relies on to answer "what did Claude touch, when, and why?"

Triggers:

- `[WRITE]` — any operation that wrote to a post, page, postmeta, or
  ACF field value
- `[OPTION]` — any change to `wp_options` or settings
- `[USER]` — any user create / role change / delete / password reset
- `[MEDIA]` — any upload / attach / update / delete
- `[DECISION]` — any policy or convention the user agreed to ("from now
  on we use X")
- `[LEARNED]` — any non-obvious fact discovered (silently-no-op'd REST
  endpoint, hidden constraint, version mismatch); also write to
  `project-notes.md` for the durable copy
- `[SCAN]` — when the scan runs
- `[ROLLBACK]` — any explicit undo

Multi-step operations collapse into **one compound entry** capturing the
full flow — not one entry per HTTP call. The reader cares about the
change, not the request count.

**Do not log:** pure reads (list / get / query). If a read revealed
something durable, that goes in `project-notes.md → ## Discovered
facts`, not the changelog.

How to write:

1. Read `{site_folder}/changelog.md` (site-folder top level).
2. If today's date section exists at the top, append entries to it.
   Otherwise insert a new `## YYYY-MM-DD — {short theme}` section above
   the previous section.
3. Use `Edit` with a unique `old_string`. Newest entry on top of the
   day's section. Time format `HH:MM` (local time, 24-hour).
4. One line per logical change. Tag at the start. Include the target
   and a one-line cause.

### When to append to `project-notes.md`

Write to `project-notes.md → ## Discovered facts` (or `## Known gotchas`
when it's a "watch out for X" lesson) when ANY of these hold:

- A first attempt at an operation failed and a second attempt
  succeeded — the *thing that made it work* is the durable fact.
- A counterintuitive constraint surfaced (ACF field key doesn't match
  its label; CPT slug differs from public name; a plugin hooks
  something unexpectedly).
- A workaround used to bypass a "Known blockers" item from
  `04-rest-capabilities.md`.
- The user explicitly says "remember this," "add this to the notes,"
  "going forward do X."

**Do not write** routine successes ("posted a blog post"), anything
obvious from the generated docs, or personally-identifying details
about specific posts/users (use patterns, not contents).

Date the line `YYYY-MM-DD` so the file stays sortable. Newest first
within the section.

### When to update the generated docs (`00–04`)

Only via a **rescan**. Never hand-edit. If a fact should survive across
rescans, it belongs in `project-notes.md`.

## Knowledge baseline

Use these reference files to answer "how does WordPress work" questions
without an API call:

- `wordpress-guides/wordpress-architecture.md` — file layout, DB tables, hook
  lifecycle, what each WP component does.
- `wordpress-guides/rest-api-cookbook.md` — canonical REST API calls organized
  by intent (content, ACF, SEO meta, media, users, settings, taxonomies).
- `wordpress-guides/safety-rules.md` — Safe / Confirm / Stop categories with
  examples, plus credential rotation.
- `wordpress-guides/acf-guide.md` — how ACF stores fields and how to read/write
  them via the REST API (`acf` payload key, ACF Pro defaults, fallback for
  un-REST-exposed groups).
- `wordpress-guides/plugin-catalog.md` — common WordPress plugins, what each
  stores, and how to talk to it over REST (which endpoints exist, which
  ones are commonly disabled).

For **site-specific** facts (active theme, installed plugins, registered
CPTs, ACF groups, REST-exposed surfaces, workflows, gotchas, what's been
done), read the docs in the site folder — the generated `.wpm/docs/00–04`
plus the curated `project-notes.md` + `changelog.md` at the top level.

## Credentials — hard rules

- **Never** ask the user to paste the Application Password, an API token,
  or any secret into chat in **any** environment. Desktop / Cowork uses the
  bundled local connector handoff; Console uses a native OS dialog.
- **Never** read or echo the contents of any OS secret-store entry or the floor
  `credential` file. The only thing you ever do with the AP is pipe it through
  `get_password()` into the `restcall` auth FD (or the `PSCredential` on Windows).
- **Never** write secrets into `config.json`, any `.wpm/docs/` file, or
  any file you control besides the dedicated born-private `credential`.
- **Never** run a secret-bearing script with `bash -x`, and never add `set -x` to
  one. Every such script runs `set +x` immediately after `set -euo pipefail`.
- The setup scripts (`scripts/setup-*`) and `prompt-secret-*` are the only places
  secrets are entered. On Console they go straight into the OS secret store via a
  native dialog (macOS writes over **stdin**, not `-w`); the password never passes
  through chat or any Claude-visible variable. On the floor tier the AP is written
  born-private (`umask 077`) and immediately git-checked.
- If a secret is leaked (printed, written, or pasted somewhere it
  shouldn't be), tell the user to **rotate** it — revoke in wp-admin, generate a
  new AP, re-store. The flow is in `wordpress-guides/safety-rules.md → "Rotation."`

## Onboarding

First-run setup is **environment-specific** and follows EXACTLY ONE runbook. The
connector, no-chat secret boundary, and ordering contracts below are immutable.

### The connector

WordPress supplies the built-in **authorize-application** deep link:

```
{production_url}/wp-admin/authorize-application.php?app_name=norml-wp-manager-{site_name}
```

User clicks → logs into WP if needed → **"Authorize norml-wp-manager-{site}?"** →
clicks Yes → copies the 24-character AP shown once. **Console:** the OS dialog
captures it. **Desktop / Cowork:** the bundled local `connect.html` page captures
it outside chat and writes a one-time `credential.handoff`; the importer locks the
real `credential`, verifies authentication, runs the site scan, and deletes the
handoff. Keep manual `{url}/wp-admin/profile.php` as a one-line fallback. **No
hosted `success_url` relay.**

**Explicitly REJECTED (recorded so no contributor re-adds):**

- ✗ **Hosted relay** (e.g. `connect.norml.studio` catching `success_url`) — breaks
  100%-self-contained on day one and routes a stranger's live WP credential through
  a third-party server. If Norml ever wants it, it's a separate, clearly-branded,
  opt-in product — never a dependency of this MIT skill.
- ✗ **localhost auto-capture listener** — unnecessary. The Desktop connector is a
  static local file with no network access of its own; WordPress authorization
  opens separately in the user's browser.

### Console first-run (no gate) → `onboarding-console.md`

```
pick folder (+ collision / cloud-sync guard)
  → collect basics (site name / production URL / WP login slug)
  → CONNECTOR: one-click authorize deep link
  → OS DIALOG captures the AP (never chat)
  → assertive gitignore gate ONLY if floor tier
  → test connection (authenticated GET /wp/v2/users/me)
  → scan (00→04) ; scaffold README + project-notes + changelog
  → report what was created + SECURITY FLAGS
```

### Desktop first-run (gate first) → `onboarding-desktop.md`

The immutable ordering contract — **no Application Password is requested, generated,
or written until the gate returns reachable:**

```
NETWORK GATE (anon GET {site}/wp-json → allowlist fix → re-probe until 200)
  → collect site name / WP username / folder (+ collision / cloud-sync guard)
  → CONNECTOR: one-click authorize deep link
  → open bundled connect.html locally; paste the AP into that local-only form
  → choose the site folder; browser writes .wpm/credential.handoff + config + .gitignore without network access
  → import-desktop-handoff rewrites .wpm/credential born-private, verifies auth, and deletes the handoff
  → ASSERTIVE GITIGNORE GATE: if git present, `git check-ignore credential` MUST return it, else BACK OUT the secret + warn
  → authenticated GET /wp/v2/users/me  (now guaranteed to reach WP)
  → scan (00→04) ; generate capabilities.md ; scaffold README + project-notes + changelog
  → report what was created + SECURITY FLAGS
  → offer end-of-session AP revoke as the DEFAULT close-out
```

**No half-written debris:** `credential` is created only AFTER the gate returns
200 **AND** the auth check succeeds. If setup aborts mid-way, remove the empty
`.wpm/` scaffold — no stray folders or half-written password left behind.

### Desktop secret handoff — no chat paste

Open the bundled `connect.html` in Chrome or Edge. It is a self-contained local
file with network access disabled. The user pastes the Application Password into
that local page and chooses the site folder; the page writes a short-lived
`.wpm/credential.handoff`. The skill then runs `scripts/import-desktop-handoff.sh`
or `.ps1`, validates the credential without echoing it, rewrites it with the
platform's private-file controls, deletes the handoff, and runs the scan. If the
runtime cannot use the local connector, hard-stop and route to a Console install;
never downgrade to asking for the secret in chat.

### Required post-setup SECURITY FLAGS (both environments)

State these as a deliverable at the end of both onboarding contracts:

1. **(floor tiers only)** plaintext-AP-on-disk reminder + rotation cadence.
2. **admin-count > threshold** ("N administrators is a lot for one site — consider
   trimming") — data from `04`'s `HEAD …/users?roles=administrator`.
3. **any detected 3rd-party admin-level agent plugin** (ManageWP-Worker, Jetpack,
   iThemes Sync, etc.) — cross-referenced from `03-plugins-theme.md`.

## Error handling

Fail loudly and stop. Do not improvise destructive recovery.

A `403`/`000` is **TWO different failures** — disambiguated by `env` + **where the
response came from**. Never conflate them. Read against `.wpm/docs/00-connection.md`.

- **Egress / allowlist (Desktop only).** Signature: `env=desktop` AND any of — the
  response came from the **sandbox proxy, not WordPress** (no WP JSON body / proxy
  error / "blocked by your network egress settings"); OR an anon `GET {site}/wp-json`
  itself fails / `000` / curl exit 6/7/35/56; OR the gate was never cleared this
  session. **→ Fix = Settings → Capabilities → Domain allowlist. Never mention WP
  roles.** Quick confirm: re-run the anon probe — if it ALSO fails → egress; if it
  returns 200 but the authenticated call 403s → capability.
- **WordPress capability.** Signature: network known-reachable (anon `/wp-json`
  returned 200) AND the 403 carries a **real WP JSON body** with a `rest_*` code
  (`rest_cannot_edit`, `rest_forbidden`). **→ Fix = use an editor/admin account for
  that endpoint.** This is the ONLY place v2.3.0's "your WP user lacks the
  capability" message is correct.
- **In Console an egress 403 is effectively impossible** (open network) → a 403
  there is **always** the capability kind.
- **`401 Unauthorized`** → the Application Password is wrong, revoked, or belongs to
  a different user; the username must be the **login slug** (check
  `{url}/wp-admin/profile.php`). Don't retry — re-run the onboarding password step.
- **`404 Not Found` / `rest_no_route` on a known endpoint** → the feature isn't
  exposed to REST (a CPT registered without `show_in_rest`, an ACF group without
  `show_in_rest`, or a plugin endpoint disabled by the host). Stop and explain; the
  scan should already have flagged it and the operate-phase gate should have caught
  the write before it fired.
- **`5xx`** → host-side issue, often rate limiting. Don't retry blindly; suggest the
  user check their host's status page.
- **Connection refused / DNS / timeout / `000`:** Desktop → almost always the
  allowlist (run the anon probe; if blocked → allowlist fix); Console → the site is
  down or `production_url` is wrong.

Carry these troubleshooting rows verbatim into BOTH onboarding files:

- **"No Application Passwords section"** → WP < 5.6 or disabled by a plugin.
- **"Can't edit the allowlist"** → Team/Enterprise admin-locked → ask the admin or
  use Claude Code.
- **"`401`"** → username must be the login slug; check `{url}/wp-admin/profile.php`.

In all cases, **fail loudly and stop** — do not improvise destructive recovery.

## Invoking helper scripts

Scripts resolve `config.json` by walking for `*/.wpm/config.json` (or via an
explicit `--site-folder`); they read the AP via `get_password()` and use the
`restcall` `--config <(...)` form internally — never `-u "$user:$pass"`.

- **First-time setup (Claude-driven)** → follow the env-specific Onboarding flow
  above. Console → `onboarding-console.md`. Desktop → `onboarding-desktop.md`.
- **First-time setup (manual / standalone scripts)** →
  `scripts/setup-macos.sh` (macOS Console) ·
  `scripts/setup-windows.ps1` (Windows Console) ·
  `scripts/setup-portable.sh` (Desktop / Linux floor) ·
  `scripts/setup-portable.ps1` (Windows floor). Each runs the network gate where
  applicable and writes into `{site_folder}/.wpm/`.
- **Capture / rotate the Application Password only (Console)** →
  `scripts/prompt-secret-macos.sh <site> <user>` (macOS) or
  `scripts/prompt-secret-windows.ps1 <site> <user>` (Windows). Pops the OS dialog,
  stores in the secret store under `norml-wp-manager-{site}`. Use this when the user
  wants to rotate the AP without re-running the full setup.
- **Test connection** → `scripts/test-connection.sh` (macOS/Linux) or
  `scripts/test-connection.ps1` (Windows). Pings `GET /wp/v2/users/me` and reports
  id + name + roles. Output references the resolved `.wpm/config.json` path + tier.
- **Rescan site** →
  `scripts/scan-site.sh --site-folder {path} --stage {0|1|2|3|4|all}` (macOS/Linux)
  or `scripts/scan-site.ps1 --SiteFolder {path} --Stage {0|1|2|3|4|all}` (Windows).
  Writes the five docs into `{site_folder}/.wpm/docs/` and appends a `[SCAN]` line
  to the top-level `changelog.md`.

After any first-run setup, the scripts emit the three **SECURITY FLAGS** above as a
required deliverable.

## Common command patterns

Examples — adapt to the user's intent. Always parse `config.json` first so you have
`$WP_USER`, `$PROD_URL`, `$SECRET_KIND`, `$SECRET_REF`, `$SITE_FOLDER`, and the
`get_password` + `restcall` helpers in scope (see "How operations work").

**Three hard rules for every command here:**

1. **Never** run a secret-bearing helper with `bash -x`; never add `set -x` to these
   scripts (xtrace guard — it would render the credential into the transcript).
2. **Never** `cat` / `echo` / print the credential to stdout — `get_password()` pipes
   it straight into curl via the `--config <(...)` FD.
3. **HTTPS only** for AP-bearing calls (`--proto '=https' --max-redirs 0`, already
   baked into `restcall`).

**Identity check (use as smoke test):**
```bash
restcall "/wp/v2/users/me?_fields=id,name,roles"
```

**List recent posts (parseable):**
```bash
restcall "/wp/v2/posts?per_page=10&_fields=id,title,status,date"
```

**Update a single post:**
```bash
restcall "/wp/v2/posts/42" -H "Content-Type: application/json" \
  -X POST -d '{"title":"New title"}'
```

**Update an ACF field value on a post (when the field group has `show_in_rest`):**
```bash
restcall "/wp/v2/posts/42" -H "Content-Type: application/json" \
  -X POST -d '{"acf":{"hero_headline":"Spring launch"}}'
```

**List installed plugins (admin-only endpoint):**
```bash
restcall "/wp/v2/plugins?_fields=plugin,name,status,version"
```

See `wordpress-guides/rest-api-cookbook.md` for the full library, including
media uploads, taxonomies, settings, and per-plugin endpoints (RankMath,
WooCommerce, ACF Pro).

## Output style

- Default to terse, factual answers. The user wants the result, not a
  tutorial.
- When you ran a request, briefly say what you ran (endpoint + method, one
  line) and then the result.
- For tabular WP output, render as Markdown tables, not raw JSON.
- For Confirm operations, **always** print the exact endpoint + method +
  body before asking — no *"I'll update some posts,"* only:
  *"I'll POST `{ "status": "trash" }` to `/wp-json/wp/v2/posts/42`. Proceed?"*
- Mention which method you used in passing for non-trivial operations —
  helps the user verify with the right tool if something goes wrong.

## What lives where (recap)

| What | Where | Why |
|---|---|---|
| The skill itself | `~/.claude/skills/norml-wp-manager/` (Console) or the desktop skill mount | Auto-loaded + auto-updated. **Never holds per-site state.** |
| Connection config | `{site_folder}/.wpm/config.json` (schema 4, chmod 600) | No secret; zero paths that escape the folder. Move/zip/delete-safe. |
| **Curated knowledge** | **`{site_folder}/project-notes.md` + `changelog.md`** (top level) | Hand/AI-editable; survives rescans; the compounding memory. |
| **Visible capability contract** | **`{site_folder}/capabilities.md`** | Generated on connect and Stage 4 rescans; read before every write. |
| **Generated scan** | **`{site_folder}/.wpm/docs/00–04`** | Do-not-hand-edit evidence; rewritten by rescan. |
| Application Password (Console) | macOS Keychain / Windows Credential Manager / Linux libsecret, service `norml-wp-manager-{site}` | OS-managed; looked up via `get_password()` at runtime. No `credential` file exists. |
| Application Password (Desktop / floor) | `{site_folder}/.wpm/credential` (born `umask 077`, gitignored) | Honest plaintext floor; protected by perms + git-exclusion + editor-role + rotation. |

There is **no `~/.config/`** and **nothing per-site in the skill folder**. Delete
the site folder and the skill forgets the site — the only off-disk state is the AP
itself, which the user revokes in wp-admin.
