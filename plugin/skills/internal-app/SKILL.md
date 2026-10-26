---
name: internal-app
description: The rules and setup for building Virtuals internal web apps (tools, dashboards, portals, admin panels) so they host on the company platform (Google Cloud Run, through projects-autodeploy). Use when starting a new internal app, when the user wants to host, deploy, publish, launch, "put it online" or share an app with the team, when moving an app off Railway or Vercel, and whenever work in such an app touches settings or secrets, the database, file uploads, sign-in, background work, the Dockerfile or GitHub Actions.
allowed-tools: Bash(node ${CLAUDE_SKILL_DIR}/scripts/check.mjs *)
---

# Virtuals internal apps

Every internal app at Virtuals is hosted the same way: one container on Google Cloud Run,
built and deployed by `Virtual-Protocol/projects-autodeploy` every time its repo's `main`
branch changes. Your job is to keep the app in that shape, so it hosts without anyone
touching Google Cloud.

The person you're working with is often **not an engineer**. Explain things in plain
language, never ask them to change cloud settings, and always finish with the short list of
things only they can do (see "Hand-off").

## How an app goes live

1. **Build it in a folder on the builder's computer.** No repo is needed yet. You add the
   platform files (templates in `${CLAUDE_SKILL_DIR}/templates/`) and keep the app to the
   rules below. `platform.yaml` names the builder, who will host it, as `owner`.
2. **When it's ready, the platform team creates its repo**: private, in the
   `Virtual-Protocol` GitHub organization, with the builder added. You push the code to it
   (`main`).
3. **The platform team adds the secrets** to the repo (only repo admins can). The builder
   sends them the values through a password manager share, never in chat or email.
4. **The builder hosts it** with **Tech requests → Host an app** in the bizops portal:
   https://bizops-912665393140.asia-southeast1.run.app/apps. It checks the repo and creates
   the app's place to run and its address, so it must come before the first deploy.
5. **Deploy:** run the repo's Deploy workflow (Actions tab), or merge to `main`. It takes
   about 3–5 minutes. After that, every merge to `main` deploys by itself.

## The rules

### Shape
- **Node.js, one container.** Builds with `npm ci && npm run build`, starts with `npm start`,
  from a clean checkout. Commit `package-lock.json`.
- **Listen on `process.env.PORT`.** `next start` already does.
- **Health check:** `healthcheck` in `platform.yaml` (default `/api/health`) answers 200 fast,
  **without login and without calling the database**. If it fails at startup, the deploy
  fails. If auth middleware exists, let this path through.
- **Requests finish within 60 seconds.** Nothing slower in a web request.

### Required files
| File | Template | Purpose |
|---|---|---|
| `platform.yaml` | `platform.yaml` | What the app is and needs. Read every comment in it |
| `Dockerfile` | `Dockerfile` | How to build the container. Adjust only if the build needs it |
| `.dockerignore` | `dockerignore` | Keeps secrets and junk out of the image |
| `.github/workflows/deploy.yml` | `deploy.yml` | Deploys on merge to `main`. Copy it unchanged |
| `.env.example` | (write it) | Every env var the app reads, with a one-line comment and a **fake** value |
| `CLAUDE.md` (section) | `CLAUDE.md` | Points future sessions in the repo at this skill |
| `.claude/settings.json` | `claude-settings.json` | Offers this plugin to anyone who opens the repo. Merge if the file exists |

### What the platform gives the app
| Variable | When | Notes |
|---|---|---|
| `PORT` | always | `port` from `platform.yaml` (default 3000) |
| `NODE_ENV` | always | `production` (set in the Dockerfile) |
| `APP_URL` | always | The app's own address, for links in emails |
| `GOOGLE_CLOUD_PROJECT` | always | For Google client libraries |
| `STORAGE_BUCKET` | `needs.storage: true` | The app's own private Cloud Storage bucket |

Google access (Cloud Storage and other Google APIs) comes from the app's own service
account automatically: Google's client libraries find it. **Never** add a service account
key, `GOOGLE_APPLICATION_CREDENTIALS`, or AWS keys.

### Who can open it, and knowing who's signed in
- **By default, only people signed in with a `@virtuals.io` Google account can open the app.**
  Google checks this before any request reaches it. **Don't build a login page, passwords or
  an admin password.**
- To know who is using it, read the email from the `x-goog-iap-jwt-assertion` header Google
  adds to every request, and **verify that JWT** (ES256, keys at
  `https://www.gstatic.com/iap/verify/public_key-jwk`, issuer `https://cloud.google.com/iap`,
  audience `/projects/912665393140/locations/asia-southeast1/services/<name>`).
  `lib/server/iap.ts` in `Virtual-Protocol/internal-bizops-tool` is a working example.
  Roles (who is an admin and so on) are the app's own business: store them in its database,
  keyed by that email.
- **Public apps** (customers outside Virtuals, like the support portal) are the exception:
  `public: true` in `platform.yaml` only works once the platform team approves the app. Then
  anyone can open it, so the app needs its own sign-in for anything private. Flag it in the
  hand-off.

### Settings and secrets
- Every env var the code reads goes in `.env.example`. At each deploy, the platform copies
  the repo's **GitHub Actions secrets** with those names into the running app. Only repo
  admins can set them, so the platform team adds them; the builder sends the values through a
  password manager share. Never ask the user to paste a secret's value to you.
- **GitHub is the one place to change them.** A value changed in Google Cloud is overwritten
  by the next deploy. After changing a secret, deploy again (Actions → Deploy → Run workflow).
- **Browser-visible values** (`NEXT_PUBLIC_*`, `VITE_*`) are baked in when the app is built.
  They go in the repo's GitHub **Variables** (same page, Variables tab), or in a committed
  `.env.production` holding only those keys. None of them may be a secret.
- `.env` and `.env.local` stay git-ignored. If one is tracked by git, stop and tell the user.

### Data
- **The platform doesn't provide a database yet** (`needs.postgres` is refused). The
  approved choice is **Postgres on Supabase**: ask the platform team for a project, created
  in the **Singapore** region (the app runs in Singapore; anywhere else makes every query
  slow). Connect with its **Session pooler** connection string as the `DATABASE_URL` secret,
  and turn its **Data API off** if the app talks to Postgres directly.
- No SQLite, no JSON files used as a database, no in-memory stores for anything that matters.
- Migrations run on start and must be safe to run twice. **Never** put `prisma db push`,
  `migrate reset`, `--accept-data-loss` or `--force-reset` in a script that runs on deploy.
  A migration that drops or renames a column or table needs an engineer's review.
- Local development uses a local or separate dev database. **Never** point local code at the
  production database.
- If the app loads lists with related rows (comments, history), fetch them in one query for
  the whole list, not one query per row: the database is over the network.

### Files
- **The container's disk is wiped on every deploy and restart.** `/tmp` is fine for scratch
  work within one request; nothing else on disk survives.
- Files go in Cloud Storage: `needs.storage: true` gives a private bucket in `STORAGE_BUCKET`.
  Use `@google-cloud/storage`; serve files through the app (checking access), never publicly.
- An app that already saves files to a folder (moving off a Railway volume, or a tool that
  writes its own files) can keep doing so: `needs.storage_folder: /app/uploads` makes the
  bucket appear as that folder. If two copies of the app would clash over those files, set
  `max_copies: 1`.

### Background work
- **Cloud Run only gives the app processing power while it's handling a request.** Work
  started after the response (emails sent "in the background", `setImmediate`, unawaited
  promises) stalls and times out. **Finish the work, then respond.**
- No `setInterval` or `node-cron` for scheduled work: the app sleeps when nobody uses it. A
  job that must run on a schedule (daily reminders, syncs) needs the platform team.

### Size
`size: small` (1 vCPU, 1 GB, up to 3 copies) suits nearly every internal tool. `medium` is
2 vCPU / 2 GB, up to 5. The app sleeps when unused and wakes on the next request, which can
take a few seconds.

### Outside services
- **Fine:** calling APIs with a key (Google, OpenAI, Anthropic, Slack, Redash…). The key is
  a secret.
- **Ask first:** anything new that would *hold Virtuals data* (another database, file host or
  auth provider) or *host the app* (Railway, Vercel, Render, Netlify…).

### Never
- Never create, change or delete anything in Google Cloud, run `gcloud` against the company
  project, or ask for Google or AWS keys. The platform does all of it.
- Never edit `.github/workflows/deploy.yml` beyond the template.
- Never change `name` in `platform.yaml` once hosted. It names the app's service and secrets.
- Never host the app somewhere else "for now".
- Never commit `.env` files, keys or tokens.

## How to work

### Starting a new app
1. Ask what it's for and who uses it. Pick a `name`: 3–24 lowercase letters, digits and
   single dashes, starting with a letter.
2. Default stack, unless the user already has one: **Next.js (App Router) + TypeScript**,
   plus Postgres on Supabase if it needs a database.
3. Work in a folder on the user's computer and `git init` it; the repo on GitHub comes when
   it's ready to host. Copy the templates in. Fill in `platform.yaml` (`owner` is the user's
   `@virtuals.io` email), add the health route, write `.env.example`, and add the `CLAUDE.md`
   section and `.claude/settings.json`.
4. Build the features within the rules above, and run the app locally so the user can try it.

### Getting an existing app ready (including moving off Railway or Vercel)
1. Run the checker (below) and read every error and warning.
2. Common fixes:
   - No `Dockerfile`: copy the template. Railway's Nixpacks builds don't exist here.
   - Its own login: on an internal app, Google sign-in replaces it. Read the signed-in email
     instead (see "Who can open it").
   - Uploads on disk: Cloud Storage, or `needs.storage_folder` to keep the folder.
   - Emails or other work after responding: do it before responding.
   - Port hardcoded: read `process.env.PORT`.
   - Health check missing, or it hits the database: add a plain one.
3. Leave `railway.toml`, `nixpacks.toml` and `vercel.json` until the app is live here, then
   delete them.
4. Moving data (a database, uploaded files) needs a plan with the owner and usually the
   platform team. Don't copy production data on your own.

### Checking your work
Run the checker on the repo root. Every deploy runs the same one:

```bash
node ${CLAUDE_SKILL_DIR}/scripts/check.mjs .
```

Fix every ✗. Fix each ! too, or tell the user why it doesn't apply. Then build and start the
app the way the Dockerfile does, and confirm the health check answers.

## Hand-off

Always end with a short **"What you need to do"** list in plain language, with only what
applies:

1. **No repo yet?** "Ask the platform team for a repository for this app (its name, and your
   GitHub username). Once they've added you, ask me to push the app to it." Otherwise:
   **merge** the changes into `main` on GitHub.
2. **Secrets:** "Send the platform team these, through a password manager share (never chat or
   email), so they can add them to the repo: `FOO` (what it is and where to get it), …". Never
   show real values.
3. **First time only, host it:** in the bizops portal, open **Tech requests → Host an app**
   (https://bizops-912665393140.asia-southeast1.run.app/apps) and enter the repo. It takes
   2–3 minutes and gives the app's address.
4. **Deploy:** "Open Actions → Deploy → Run workflow in the repo, or merge to `main`. It's live
   about 5 minutes later." After the first time, every merge deploys by itself.
5. **Needs the platform team:** a database, a public app, a schedule, a custom domain, or a
   migration that drops or renames data.
6. **Problems found:** a tracked `.env` file, secrets in code, or anything you couldn't fix.
