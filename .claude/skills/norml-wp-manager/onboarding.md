# Norml WordPress Copilot — onboarding

Installed skill: `norml-wp-manager`.

Onboarding runs once per site. It collects your site basics, helps you generate a
WordPress Application Password, stores that password securely, then scans your site
(read-only) so Claude knows your theme, plugins, content model, and REST surface
before the first edit. Everything it creates lives in **one folder you name** — move
it, zip it, or delete it and the skill simply forgets that site.

**The easiest path:** open Claude in any folder and say *"set up my WordPress
access."* Claude detects where it's running and follows the right runbook below.

## Setup is environment-specific — pick your runbook

- **Claude Code, Codex, or Gemini CLI (terminal)** → **[`onboarding-console.md`](onboarding-console.md)**.
  Your machine, your network — no allowlist to configure. The Application Password
  goes into the OS secret store (macOS Keychain / Windows Credential Manager / Linux
  libsecret) and Claude never sees it.

- **Claude desktop app / Cowork** → **[`onboarding-desktop.md`](onboarding-desktop.md)**.
  Runs in a cloud sandbox. **Do the network step first** — add your site domain to
  Settings → Capabilities so the sandbox can reach it *before* any password is
  requested. The bundled local connector collects the Application Password
  outside chat, then a one-time importer moves it into a protected, git-ignored
  file inside your site folder and deletes the handoff.

Not sure which you're in? Claude figures it out automatically during setup. If
you're on **claude.ai (web or mobile)**, neither runbook applies — there's no
filesystem to write to; use Claude Code or the desktop app instead.
