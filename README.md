# projects-autodeploy

Hosts Virtuals' internal apps on Google Cloud Run, so anyone who builds a tool
(usually with Claude) can put it online without touching Google Cloud.

- **Where apps run:** Cloud Run in `asia-southeast1`, project `virtuals-internal-apps`.
- **Who can open them:** anyone signed in with a `@virtuals.io` Google account.
  Google checks this (Identity-Aware Proxy) before a request reaches the app.
- **How they deploy:** every push to the app repo's `main` builds and deploys it,
  in about 3 minutes.

## How an app goes live

1. **Build it to the rules below.** Claude's `virtuals-platform` plugin does this,
   and adds the files from [`templates/app/`](templates/app).
2. **Host it.** Use the **Host an app** form in the bizops portal. It runs
   [`host-app.yml`](.github/workflows/host-app.yml), which checks the request and
   creates the app's Cloud Run service, its own service account and, if asked
   for, a storage bucket.
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

Deploys check again that the app was hosted from the same repo, so one repo
can't deploy over another's app.

## The rules

An app is one Node.js container that:

- builds with `npm ci && npm run build` and starts with `npm start`
- listens on `process.env.PORT`
- answers its health check (`/api/health` by default) with 200, without login or
  database calls
- keeps no state on local disk: files go to Cloud Storage (`needs.storage`)
- lists every env var it reads in `.env.example`, with fake values
- commits no secrets and no cloud keys: it gets Google access from its own
  service account

Not available yet, so ask the platform team: Postgres, Redis, scheduled jobs,
public (no sign-in) apps, custom domains, anything bigger than `medium`.

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
