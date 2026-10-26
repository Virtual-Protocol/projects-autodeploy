# projects-autodeploy

Hosts Virtuals' internal apps on Google Cloud Run, so anyone who builds a tool
(usually with Claude) can put it online without touching Google Cloud.

- **Where apps run:** Cloud Run in `asia-southeast1`, project `virtuals-internal-apps`.
- **Who can open them:** anyone signed in with a `@virtuals.io` Google account.
  Google checks this (Identity-Aware Proxy) before a request reaches the app.
  The few apps built for the public, such as the support portal, are open to
  everyone instead, once approved in [`public-apps.txt`](public-apps.txt).
- **How they deploy:** every push to the app repo's `main` builds and deploys it,
  in about 3 minutes.

## How an app goes live

1. **Build it to the rules below.** Claude's `virtuals-platform` plugin
   ([`plugin/`](plugin), see "The Claude plugin") does this, and adds the files from
   [`templates/app/`](templates/app). The bizops portal's **Tech requests → Build an
   app** page walks a builder through it.
2. **Host it.** Use the **Host an app** form in the bizops portal. It runs
   [`host-app.yml`](.github/workflows/host-app.yml), which checks the request and
   creates the app's Cloud Run service, its own service account and, if asked
   for, a storage bucket. Until its first deploy, the app's address shows a
   page ([`placeholder/`](placeholder)) listing what's left to do, with links.
3. **Add its secrets** in the app repo's GitHub settings (Settings > Secrets and
   variables > Actions), using the names in its `.env.example`. Public values
   (`NEXT_PUBLIC_*`, `VITE_*`) go under Variables instead.
4. **Merge to `main`** (or run the repo's Deploy workflow). The app repo's
   `deploy.yml` calls [`deploy-app.yml`](.github/workflows/deploy-app.yml), which
   builds the image, copies the secrets into Secret Manager and deploys.

## What hosting checks

A request is refused unless all of these hold:

| Check | Why |
| --- | --- |
| The repo is in `Virtual-Protocol` | The company controls who can change it |
| The repo is private | Internal tools' code isn't public |
| `owner` in the repo's `platform.yaml` is the person asking | Only someone who can push to the repo could have written that |
| The app passes [the checker](actions/check/check.mjs) | It will deploy and run as expected |
| The app name isn't used by another repo | Names are the service's and secrets' names |
| A `public: true` app is listed in [`public-apps.txt`](public-apps.txt) | Opening an app to the internet needs a platform engineer's review |

Deploys check again that the app was hosted from the same repo, so one repo
can't deploy over another's app.

## The rules

An app is one Node.js container that:

- builds with `npm ci && npm run build` and starts with `npm start`
- listens on `process.env.PORT`
- answers its health check (`/api/health` by default) with 200, without login or
  database calls
- keeps no state on local disk: files go to Cloud Storage (`needs.storage`). An
  app that already saves files to a folder can have its bucket appear as that
  folder (`needs.storage_folder`)
- lists every env var it reads in `.env.example`, with fake values
- commits no secrets and no cloud keys: it gets Google access from its own
  service account

Not available yet, so ask the platform team: Postgres, Redis, scheduled jobs,
custom domains, anything bigger than `medium`. Public (no sign-in) apps need
the platform team to add them to [`public-apps.txt`](public-apps.txt).

## The Claude plugin

Builders work with Claude Code and the `virtuals-platform` plugin in [`plugin/`](plugin).
It teaches Claude the rules above, carries the templates and the checker, and loads by
itself when someone builds or hosts an app. Its guide is
[`plugin/skills/internal-app/SKILL.md`](plugin/skills/internal-app/SKILL.md).

- **This repo is public**, so anyone can install the plugin without being given access.
  Nothing here is secret, and nothing secret may ever be committed here: app secrets live in
  each app repo's GitHub secrets, and the platform's in this repo's GitHub secrets.
- **For everyone at once:** an Owner of the claude.ai organization adds this under
  Organization settings → Claude Code → Managed settings:

  ```json
  {
    "extraKnownMarketplaces": {
      "virtuals": {
        "source": { "source": "github", "repo": "Virtual-Protocol/projects-autodeploy" },
        "autoUpdate": true
      }
    },
    "enabledPlugins": { "virtuals-platform@virtuals": true }
  }
  ```

- **One person:** `claude plugin marketplace add Virtual-Protocol/projects-autodeploy`, then
  `claude plugin install virtuals-platform@virtuals`.
- **Per app repo:** the plugin commits `.claude/settings.json`, so anyone who opens the repo
  in Claude Code is offered the plugin.

To change the rules, edit `SKILL.md` and bump `version` in
`plugin/.claude-plugin/plugin.json`. The checker and templates live in
[`actions/check/`](actions/check) and [`templates/app/`](templates/app); the plugin keeps
copies, and the [Plugin in sync](.github/workflows/plugin-in-sync.yml) check fails a change
that updates only one.

## Security

- **No keys anywhere.** GitHub Actions gets short-lived Google credentials through
  Workload Identity Federation. Only `deploy-app.yml` and `host-app.yml` on this
  repo's `main` can get them (see [`bootstrap/setup.sh`](bootstrap/setup.sh)), so
  **changes to `main` here need a reviewer**.
- **Each app is fenced in.** It runs as its own service account, which can read
  only secrets named `<app>--*` and its own bucket.
- **The deployer can write secrets but not read them**, and the image is built
  before any credentials exist on the runner.

## One-time setup

Done once by someone who owns the Google Cloud project and administers this repo:

```bash
./bootstrap/setup.sh
```

Then create the `ORG_READ_TOKEN` secret it asks for.

## Running it

- **Logs:** Google Cloud console > Cloud Run > the app > Logs.
- **Roll back:** Cloud Run > the app > Revisions > send traffic to an earlier one,
  or re-run an earlier Deploy in the app repo.
- **Turn an app off:** `gcloud run services delete <app> --region asia-southeast1 --project virtuals-internal-apps`.
