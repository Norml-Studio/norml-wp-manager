# {SITE_NAME} — WP management notes

> Durable knowledge about managing this site's WordPress install.
> Claude appends to this file when it learns something non-obvious during
> a session. Humans can edit freely. Survives capability rescans —
> anything that should outlive `site-architecture.md` lives here.

## Workflows specific to this site

(How to do common things on THIS site. Add as the team develops
site-specific patterns. Examples:
- *"Blog posts use category 'Updates' by default."*
- *"Featured images must be 1200×630."*
- *"RankMath title format: '{Post title} — {Site name}'."*
- *"Case studies live in the `case_study` CPT — fields in the
  `case_study_details` ACF group."*)

_— nothing yet —_

## Discovered facts

(Claude appends one-liners with dates when it learns something
non-obvious during a session. Examples:
- *"2026-05-20 — `rank_math_focus_keyword` isn't REST-writable on this
  site; theme doesn't `register_post_meta(...,'show_in_rest'=>true)`."*
- *"2026-05-20 — Homepage uses Elementor; never write to `post_content` —
  edit `_elementor_data` via the Elementor editor instead."*)

_— nothing yet —_

## Known gotchas

(Things that don't work, things to avoid, workarounds in use. Examples:
- *"Disable Wordfence's 'Application Password Brute Force Protection'
  before bulk writes — it 401-blocks the IP."*
- *"The `team_member` CPT is REST-disabled. Edits go through wp-admin
  only."*)

_— nothing yet —_

## Open questions

(Unverified assumptions, things to test next session. Examples:
- *"Is the staging URL also REST-reachable with the same Application
  Password? Try `/wp-json/wp/v2/users/me` against the staging URL."*
- *"Does the cache need to be purged after ACF value updates? Test by
  changing hero headline and watching front-end."*)

_— nothing yet —_
