# norml-wp-manager

**Control your whole WordPress site from Claude — edit pages, publish posts, and
fix your SEO, just by asking. No developer. No clicking through wp-admin.**

A skill for **non-technical site owners**, in [Claude Code](https://claude.com/claude-code)
or the Claude desktop app. You describe a change in plain English, and Claude makes
it the same way you would in your dashboard — only faster. Your password stays on
your own computer, never in the chat. And the more you use it, the more it learns
about your site.

> **Content-only.** It edits the things you manage day to day — pages, posts, SEO,
> images, custom content. It doesn't touch your site's code, design files, or
> database; that's developer work.

## What you can do

Just say what you want:

| You want to… | Just say… |
|---|---|
| Make an edit without waiting on your dev | *"Fix the typo on my About page."* |
| Publish a post properly | *"Publish the post I wrote — add a category, a featured image, and the SEO title."* |
| Fix the SEO you keep putting off | *"Find every blog post with no meta description and write one."* |
| Aim a page at a search term | *"Rewrite my services page title to rank for 'plumbing in Denver'."* |
| Clear a backlog of drafts | *"Schedule these 6 drafts, one every Monday."* |
| Swap an image | *"Swap the homepage hero for the image I just uploaded."* |
| Manage case studies, products, portfolio | *"Add a case study with these details and tag it 'Fintech'."* |
| Stay in control of access | *"Who has admin access? I'm offboarding a contractor."* |

Anything risky, it shows you in full and asks first. And it learns your site as you
go — so next month's edits are even quicker than today's.

## Requirements

- **Claude Code** on macOS 12+ / Windows 10+ / Linux (**Console**), or the **Claude
  desktop app / Cowork** (**Desktop** — a cloud sandbox; less secure, uses a
  protected file instead of a keychain). The skill detects which one it's in.
- A **WordPress 5.6+** site (Application Passwords are built into core from 5.6)
- A **WordPress admin or editor account** on that site
- `python3` on your PATH (the read-only site scan parses REST output in Python — no
  pip packages, just the interpreter). `jq` is optional.
- **Desktop / Cowork only:** add your site domain to **Settings → Capabilities →
  Allow network egress** *before* setup. The sandbox can't reach your site until you
  allowlist it, and the skill refuses to ask for a password until it can.
- **No SSH, no WP-CLI, no developer tooling.**

## Install

```bash
git clone https://github.com/Norml-Studio/norml-wp-manager.git
mkdir -p ~/.claude/skills
cp -R norml-wp-manager/.claude/skills/norml-wp-manager ~/.claude/skills/
chmod +x ~/.claude/skills/norml-wp-manager/scripts/*.sh   # macOS only
```

On the **Claude desktop app / Cowork** there's nothing to copy — the skill is mounted
into your session automatically. Just allowlist your site domain first (see
Requirements), then run setup.

Then, in Claude: **"Set up my WordPress access."** Claude detects your environment and
walks you through onboarding in chat. On **Console** a native OS dialog captures your
Application Password straight into Keychain / Credential Manager / libsecret — you
never type it into the terminal. On **Desktop** you paste it once and it's written to
a protected, git-ignored file inside your site folder.

Full step-by-step (Console + Desktop, Windows, troubleshooting):
**[`INSTALL.md`](.claude/skills/norml-wp-manager/INSTALL.md)**.

## Everything for a site lives in one folder

There's no system-wide config directory and nothing per-site lands in the skill
folder. Each site gets **one folder you name** — readable `project-notes.md` +
`changelog.md` at the top, and a hidden `.wpm/` holding the connection `config.json`
(no secrets) and an auto-generated read-only site scan. Move it, zip it, or delete it
and the skill simply forgets that site — nothing else on your machine is touched.

## How your credentials are handled

- **Console:** your **Application Password** is stored in the **OS secret store** —
  macOS Keychain / Windows Credential Manager / Linux libsecret (service
  `norml-wp-manager-{site}`). Claude never sees it.
- **Desktop / Cowork:** no OS keychain in the sandbox, so the password lives in a
  protected, git-ignored `credential` file inside your site folder (born owner-only).
  Use an editor-role password and revoke + regenerate it at the end of a session.
- The password is handed to `curl` only through a process-substitution file
  descriptor — it never appears on a command line, in shell history, or in the chat
  transcript. All authenticated calls are HTTPS-only.
- You can revoke the Application Password from `wp-admin` at any time.

## Documentation

- **[Guide](.claude/skills/norml-wp-manager/readme.md)** — what it is, and everything you can do with it (by category). Visual one-pager: [`readme.html`](.claude/skills/norml-wp-manager/readme.html)
- **[Install guide](.claude/skills/norml-wp-manager/INSTALL.md)** — full setup, troubleshooting, "what's NOT installed"
- **Onboarding** — environment-specific runbooks: [Console / terminal](.claude/skills/norml-wp-manager/onboarding-console.md) · [Desktop app / Cowork](.claude/skills/norml-wp-manager/onboarding-desktop.md) ([chooser](.claude/skills/norml-wp-manager/onboarding.md))
- **[Changelog](.claude/skills/norml-wp-manager/changelog.md)** — skill version history (currently v1.0.0)

## License

[MIT](LICENSE) © Norml Studio
