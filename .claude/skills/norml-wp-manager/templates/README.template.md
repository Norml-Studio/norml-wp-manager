# {SITE_NAME}

This folder is everything Claude knows about managing the WordPress site **{SITE_NAME}** (via the norml-wp-manager skill). The two Markdown files below — `project-notes.md` and `changelog.md` — are yours to read and edit. The hidden `.wpm/` folder is the tool's machinery (connection config, your saved credential, and auto-generated site scans) — don't hand-edit anything inside it; a rescan overwrites it.

**Move it:** drag or `mv` this whole folder anywhere — it keeps working (nothing inside points outside the folder). The one exception: if your password is stored in your OS keychain rather than in `.wpm/credential`, moving to a *different computer* needs a quick 3-line re-attach.

**Delete it:** delete this folder and Claude forgets the site — nothing else on your computer is affected. The only off-disk leftover is the Application Password itself, so also revoke it at `{PROD_URL}/wp-admin/profile.php`.
