// The page an app shows from hosting until its first deploy replaces it: what
// is left to do, with links. scripts/provision.sh passes the app's details as
// environment variables. No dependencies.
import { createServer } from "node:http"

const { APP_NAME = "This app", REPO = "", SECRETS = "", VARIABLES = "", PORT = "8080" } = process.env

const escape = (text) => text.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)
const names = (value) => value.split(",").map((name) => name.trim()).filter(Boolean)
const codes = (list) => `<ul class="names">${list.map((name) => `<li><code>${escape(name)}</code></li>`).join("")}</ul>`

const repoUrl = `https://github.com/Virtual-Protocol/${encodeURIComponent(REPO)}`
const secrets = names(SECRETS)
const variables = names(VARIABLES)

const secretsStep = secrets.length
  ? `<li>
      <h2>Check its secrets are added</h2>
      <p>The app needs these settings on GitHub. Only the repo's admins can add them, so the platform team does: send them any missing values through a password manager share, never in chat or email.</p>
      ${codes(secrets)}
      <a class="button" href="${repoUrl}/settings/secrets/actions">Open the secrets page (admins)</a>
      ${
        variables.length
          ? `<p>These are public, so they go under the <strong>Variables</strong> tab instead:</p>
             ${codes(variables)}
             <a class="button secondary" href="${repoUrl}/settings/variables/actions">Open the variables page (admins)</a>`
          : ""
      }
    </li>`
  : ""

const page = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${escape(APP_NAME)}: not live yet</title>
<style>
  :root { --bg: #f6f7f9; --card: #fff; --text: #1d2330; --muted: #5b6475; --line: #dfe3ea; --accent: #2457d6; --accent-text: #fff; }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #11141a; --card: #1a1f28; --text: #e8ebf1; --muted: #9aa3b5; --line: #2c3340; --accent: #6d95ff; --accent-text: #0b1020; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text); font: 16px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif; }
  main { max-width: 640px; margin: 0 auto; padding: 48px 16px; }
  .tag { display: inline-block; font-size: 13px; color: var(--muted); border: 1px solid var(--line); border-radius: 999px; padding: 2px 10px; }
  h1 { font-size: 28px; line-height: 1.25; margin: 12px 0 8px; }
  .lead { color: var(--muted); margin: 0 0 28px; }
  ol.steps { list-style: none; counter-reset: step; padding: 0; margin: 0; }
  ol.steps > li { counter-increment: step; background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 20px 20px 20px 64px; margin-bottom: 14px; position: relative; }
  ol.steps > li::before { content: counter(step); position: absolute; left: 20px; top: 18px; width: 28px; height: 28px; border-radius: 50%; background: var(--accent); color: var(--accent-text); display: grid; place-items: center; font-weight: 600; font-size: 14px; }
  h2 { font-size: 17px; margin: 0 0 6px; }
  p { margin: 0 0 10px; }
  ul.names { margin: 0 0 14px; padding-left: 20px; }
  code { font: 14px ui-monospace, SFMono-Regular, Menlo, monospace; overflow-wrap: anywhere; }
  .button { display: inline-block; background: var(--accent); color: var(--accent-text); text-decoration: none; font-weight: 600; padding: 8px 14px; border-radius: 8px; margin: 2px 0 6px; }
  .button.secondary { background: transparent; color: var(--accent); border: 1px solid var(--accent); }
  .foot { color: var(--muted); font-size: 14px; margin-top: 24px; }
</style>
</head>
<body>
<main>
  <span class="tag">Not live yet</span>
  <h1>${escape(APP_NAME)} is set up, but not deployed yet</h1>
  <p class="lead">This address is ready. Once the steps below are done, the app replaces this page.</p>
  <ol class="steps">
    ${secretsStep}
    <li>
      <h2>Deploy it</h2>
      <p>Open the Deploy workflow, click <strong>Run workflow</strong>, then the green <strong>Run workflow</strong> button. Merging any change to the main branch does the same.</p>
      <a class="button" href="${repoUrl}/actions/workflows/deploy.yml">Open the Deploy workflow</a>
    </li>
    <li>
      <h2>Come back in about 3 minutes</h2>
      <p>Reload this page. If the deploy fails, GitHub emails you and its page says why. Claude can help fix it.</p>
    </li>
  </ol>
  <p class="foot">Hosted with projects-autodeploy. Stuck? Ask the platform team.</p>
</main>
</body>
</html>`

createServer((_request, response) => {
  response.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" })
  response.end(page)
}).listen(Number(PORT))
