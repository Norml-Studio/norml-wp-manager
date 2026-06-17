# norml-wp-manager

> Control your whole WordPress site from Claude — edit pages, publish posts, and
> fix your SEO, just by asking. No developer. No clicking through wp-admin. It maps
> your site, learns it over time, and only ever does safe, content-level changes.

## The problem

You own a WordPress site, but you're not the developer. So the small stuff piles
up. A typo on the About page. A price that's out of date. A post that's been
"almost ready" for a week. You click through wp-admin one item at a time — or you
send your dev a ticket and wait.

This skill clears that backlog in plain English. You say what you want, and Claude
does it the same way you would in your dashboard — only faster. Your password
never touches the chat, and anything risky is shown to you first.

One thing to be clear about up front: this is a **content** tool, not a
development tool. It changes text, images, fields, and settings. It doesn't build
features or write code. Think *"fix it, fill it, publish it,"* not *"build me a
new site."*

## First, it maps your site

Here's what makes it work: before it changes anything, it scans your site and
learns how it's put together. Your pages and post types. Your plugins. Your custom
fields. What's editable and what isn't.

Why does that matter? Because **what you can do depends on how your site was
built** — and every site is different. A well-templated site lets Claude do a lot:
swap the text and images in fields, spin up new pages from a template, fill in
SEO. A site where everything is baked into a page builder lets it do less. Claude
doesn't guess. It checks your site, then tells you plainly what it can and can't
touch here.

So your first real question is often just: *"What can you actually change on my
site?"* — and it'll answer from the scan.

## What you can do

Describe the result you want. Claude handles the rest. Here's the range, grouped
by the job — with an honest note on what's reliable everywhere versus what depends
on your setup.

### Edit content without waiting on your developer
Works on most sites.

| You want to… | Just say… |
|---|---|
| Fix a typo or reword a line | *"Fix the typo on my About page."* |
| Update something that changed | *"Change the opening hours on my contact page to 9–5."* |
| Rewrite a headline | *"Make my homepage headline say '…'."* |
| Swap an image | *"Swap the homepage hero for the image I just uploaded."* |

### Draft in Claude, then publish to WordPress
This is the flow people love. Write and shape the content right here in the chat —
a blog post, a new page, a team bio — then send it live in one step.

| You want to… | Just say… |
|---|---|
| Publish a finished post | *"Publish the post I wrote — add a category, a featured image, and the SEO title."* |
| Start from rough notes | *"Turn these notes into a blog post and save it as a draft."* |
| Write *and* place it | *"Write a 200-word bio for our new designer and put it on a new team page."* |

### Spin up new pages from ones you already have
Great for repeatable pages — team members, services, case studies, listings. Claude
copies the structure of an existing one and fills in the new content.
*(Works when the page or post type is open to the API — Claude checks first.)*

| You want to… | Just say… |
|---|---|
| Add a new team member | *"Duplicate my team page for our new hire and fill in their bio."* |
| Add a case study | *"Add a case study with these details and tag it 'Fintech'."* |
| Build out a set | *"Create service pages for each of these five services."* |

### Fix the SEO you keep putting off
*(Reliable when your SEO plugin's fields are open to the API — many are, some need
a one-line tweak from a developer. Claude tests it and tells you.)*

| You want to… | Just say… |
|---|---|
| Fill the gaps in bulk | *"Find every blog post with no meta description and write one."* |
| Aim a page at a search term | *"Rewrite my services page title to rank for 'plumbing in Denver'."* |
| Catch the weak spots | *"Which pages have a missing or weak SEO title?"* |

### Clean up your media library
Works on most sites. A genuinely tedious job, done in one pass.

| You want to… | Just say… |
|---|---|
| Add missing alt text in bulk | *"Add alt text to every image that's missing it."* (better accessibility *and* SEO) |
| Tidy filenames and captions | *"Set proper titles and captions on the images on my homepage."* |

### Sort, tag, and organize
Works on most sites.

| You want to… | Just say… |
|---|---|
| Manage categories and tags | *"Add a 'Case Studies' category and move these 4 posts into it."* |
| Reshape your navigation | *"Reorder my main menu and add a 'Pricing' link before Contact."* |
| Schedule a backlog | *"Schedule these 6 drafts, one every Monday."* |

### Stay safe and in control
Works on most sites *(admin account needed for the access bits)*.

| You want to… | Just say… |
|---|---|
| Audit who can log in | *"Who has admin access? I'm offboarding a contractor."* |
| Add a teammate | *"Add an editor account for Sam — here's the email."* |
| Update the basics | *"Change the site tagline to '…'."* |

### Fill in your custom fields
*(Depends on your build. If your theme uses custom fields — for hero text, prices,
team bios, feature lists — and they're open to the API, Claude reads and writes
them. If not, it tells you which ones a developer needs to open up.)*

| You want to… | Just say… |
|---|---|
| Update field content | *"Update the hero heading and subheading on the homepage."* |
| Fix a detail in a template | *"Change the price in the 'Starter plan' block to $29."* |

## It gets smarter the more you use it

Claude doesn't start from zero every time. It remembers your site, and it keeps
learning.

The first time it connects, it takes that snapshot — your pages, your post types,
your plugins, what's editable and what isn't. The snapshot lives in your site
folder, and Claude reads it before it touches anything.

Then it keeps notes. Every change you ask for is logged with the date. Every quirk
it runs into gets written down — a section it can't reach, a rule you've set ("all
blog posts go in the News category"), the way your homepage is put together. None
of it has to be re-explained next time.

So the version you use in month three knows your site far better than the one you
started with. You give shorter instructions. It makes fewer wrong guesses. It
starts to feel like it gets you — because, in a real way, it's been taking notes
the whole time.

## A typical run

1. **First time.** You say *"set up my WordPress access."* Claude gets you a
   one-click key from WordPress, stores it safely, and scans your site.
2. **See what's possible.** You say *"what can you change on my site?"* Claude
   answers from the scan — your post types, your fields, what's open and what isn't.
3. **Ask for the thing.** *"Duplicate the team page for our new designer, Maria, and
   write her a short bio."*
4. Claude drafts the bio, shows you the new page it'll create, and waits.
5. You say yes. It's live in seconds — and logged, so you've got a record.

---

## Details

### It works in two places

**Claude Code** (the version that runs in a terminal) is the most private. Your
key goes straight into your computer's built-in password vault. It's never shown
in the chat.

**The Claude desktop app** needs one extra step the first time. You allow your
site's web address under **Settings → Capabilities**, so Claude is allowed to
reach it. Don't worry — the skill checks this for you and tells you exactly what to
click. It won't ask for your key until your site is reachable.

Either way, everything Claude knows about your site lives in one folder you name.
Move it, copy it, or delete it — it's all in one place. Delete it and Claude
forgets the site. Nothing else on your computer is touched.

To get the key, the skill hands you a one-click link. It opens a WordPress screen
that says "Authorize?" You click yes and copy the key. WordPress calls it an
*application password* — it's a key made just for this, separate from your login,
and you can cancel it any time. Use an **editor** account if you can. If that key
ever leaked, an editor can't install software or change who has access.

### Safe by default

Reads and small edits happen right away. Bigger changes get checked with you first
— anything that touches a lot of items, who can log in, or site-wide settings.
Claude shows you the full change and asks "yes or no." And a few things are
flat-out refused unless you really insist: changing your site's address, removing
your last administrator, or deleting in bulk.

When it changes a custom field or SEO value, it reads it back to confirm the change
actually stuck — so you're never told "done" when nothing happened.

### What it can't do

It works at the content level, through the same doorway your dashboard uses. That's
narrower than full developer access — on purpose, so it's safe in non-technical
hands. So it won't:

- **Build features or write code** — themes, templates, plugins, custom fields'
  *definitions*. That's developer work. It fills fields in; it doesn't create them.
- **Install or update plugins and themes** — do that in wp-admin. (There's no safe,
  reliable way to update a plugin from here, and most hosts block installs.)
- **Edit pages built on a page-builder canvas** (Elementor, Bricks, Beaver Builder)
  — that content lives in a format it can't safely touch. If those pages pull from
  fields, it can edit the *fields*; it just can't rebuild the layout.
- **Run an online store's product data** (WooCommerce prices, stock, variations) —
  that needs the store's own separate setup.
- **Change "global" bits like footer text or theme options** when they live outside
  normal pages — those often aren't reachable this way.
- **Make hundreds of edits at once** — it works one item at a time. A few dozen is
  fine. Hundreds is slow.

Ask for something it can't do, and it tells you straight — and points you to who
can (usually wp-admin or your developer). It never fails quietly.

### When something's off

| What you see | What it usually means |
|---|---|
| It asks you to "set up access" again | Your site folder moved or got deleted. Run setup again. |
| "Wrong username or password" | Your username is your **login name** — not your display name or email. Check it under your profile in wp-admin, make a fresh key, and re-run setup. |
| "Can't reach your site" (desktop app) | Your site's address isn't allowed yet. Add it under **Settings → Capabilities**. This is a Claude setting, not a problem with your site. |
| "You don't have permission" | Your WordPress role is too low for that. Use an editor or admin account. |
| A change didn't show up | Your site's cache (clear it from your host), or that part of the page isn't editable this way (a page builder, or a field a developer needs to open up). |

---

_Covers SKILL.md v1.0.0 | Last changelog entry: v1.0.0 | Generated: 2026-06-16. If
Claude does something different from what's written here, this file is stale —
trust `SKILL.md`._
