#!/usr/bin/env node
// Checks a repo against the projects-autodeploy rules (README.md, "The rules").
// Usage: node check.mjs [repo-dir]   Exit code 1 when there are errors.
// No dependencies; Node 18+. Claude's virtuals-platform plugin runs a copy of
// this file; keep the two in step.

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(process.argv[2] || ".");
const inActions = process.env.GITHUB_ACTIONS === "true";
const errors = [];
const warnings = [];
const passes = [];
const err = (msg) => errors.push(msg);
const warn = (msg) => warnings.push(msg);
const ok = (msg) => passes.push(msg);

const exists = (p) => fs.existsSync(path.join(root, p));
const read = (p) => (exists(p) ? fs.readFileSync(path.join(root, p), "utf8") : null);
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// ---------- files in the repo ----------

const SKIP_DIRS = new Set(["node_modules", ".git", ".next", "dist", "build", "coverage", ".data", ".turbo", ".vercel"]);
const CODE_EXT = /\.(c|m)?(j|t)sx?$/;

function git(args) {
  try {
    return execFileSync("git", args, { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  } catch {
    return null;
  }
}

function listFiles() {
  const out = git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"]);
  if (out !== null) return out.split("\0").filter(Boolean);
  const files = [];
  const walk = (dir) => {
    for (const e of fs.readdirSync(path.join(root, dir), { withFileTypes: true })) {
      if (SKIP_DIRS.has(e.name)) continue;
      const rel = dir ? `${dir}/${e.name}` : e.name;
      if (e.isDirectory()) walk(rel);
      else files.push(rel);
    }
  };
  walk("");
  return files;
}

const allFiles = listFiles();
const trackedOut = git(["ls-files", "-z"]);
const tracked = trackedOut === null ? null : trackedOut.split("\0").filter(Boolean);

const isAppCode = (f) =>
  CODE_EXT.test(f) &&
  !f.split("/").some((part) => SKIP_DIRS.has(part)) &&
  !/(^|\/)(scripts|tests?|__tests__|e2e|prisma\/seed)(\/|\.)|\.(test|spec)\.|(^|\/)test-[^/]*$|\.config\.|\.d\.ts$/.test(f);
const codeFiles = allFiles.filter(isAppCode);
const code = new Map();
for (const f of codeFiles) {
  try {
    const full = path.join(root, f);
    if (fs.statSync(full).size < 1_000_000) code.set(f, fs.readFileSync(full, "utf8"));
  } catch {}
}

function findInCode(re, { limit = 5 } = {}) {
  const hits = [];
  for (const [f, text] of code) {
    const lines = text.split("\n");
    for (let i = 0; i < lines.length && hits.length < limit; i++) {
      if (re.test(lines[i])) hits.push(`${f}:${i + 1}`);
    }
    if (hits.length >= limit) break;
  }
  return hits;
}

// ---------- platform.yaml ----------

function parseYaml(text) {
  const out = {};
  let section = null;
  for (const raw of text.split("\n")) {
    const line = raw.replace(/(^|\s)#.*$/, "").trimEnd();
    if (!line.trim()) continue;
    const m = line.match(/^(\s*)([A-Za-z_][\w-]*):\s*(.*)$/);
    if (!m) throw new Error(`can't read this line: "${raw.trim()}"`);
    const [, indent, key, rawVal] = m;
    let val = rawVal.trim().replace(/^(['"])(.*)\1$/, "$2");
    if (val === "true") val = true;
    else if (val === "false") val = false;
    else if (/^\d+$/.test(val)) val = Number(val);
    if (!indent) {
      if (val === "") (out[key] = {}), (section = key);
      else (out[key] = val), (section = null);
    } else {
      if (!section) throw new Error(`unexpected indented line: "${raw.trim()}"`);
      out[section][key] = val;
    }
  }
  return out;
}

let cfg = null;
const yamlText = read("platform.yaml");
if (!yamlText) {
  err("platform.yaml is missing. Copy templates/app/platform.yaml from projects-autodeploy and fill it in.");
} else {
  try {
    cfg = parseYaml(yamlText);
  } catch (e) {
    err(`platform.yaml: ${e.message}`);
  }
}

if (cfg) {
  const known = new Set(["name", "owner", "port", "healthcheck", "size", "needs"]);
  for (const k of Object.keys(cfg)) {
    if (k === "audience") warn("platform.yaml: audience isn't used. Every app is behind Google sign-in; public apps need the platform team");
    else if (!known.has(k)) warn(`platform.yaml: unknown key "${k}" (ignored)`);
  }

  const name = String(cfg.name ?? "");
  if (!/^[a-z][a-z0-9-]{1,22}[a-z0-9]$/.test(name) || name.includes("--"))
    err(`platform.yaml: name "${name}" must be 3-24 lowercase letters, digits and single dashes, starting with a letter`);
  else if (name === "my-app") err('platform.yaml: name is still the template value "my-app"');

  const owner = String(cfg.owner ?? "");
  if (!/^[^@\s]+@virtuals\.io$/.test(owner)) err(`platform.yaml: owner "${owner}" must be a @virtuals.io email`);
  else if (owner === "someone@virtuals.io") err("platform.yaml: owner is still the template value");

  cfg.port ??= 3000;
  if (!Number.isInteger(cfg.port) || cfg.port < 1024 || cfg.port > 65535) err("platform.yaml: port must be a number between 1024 and 65535");

  cfg.healthcheck ??= "/api/health";
  if (typeof cfg.healthcheck !== "string" || !cfg.healthcheck.startsWith("/")) err("platform.yaml: healthcheck must be a path starting with /");

  cfg.size ??= "small";
  if (!["small", "medium"].includes(cfg.size)) err(`platform.yaml: size must be small or medium, not "${cfg.size}"`);

  cfg.needs ??= {};
  if (typeof cfg.needs !== "object") err("platform.yaml: needs must be a section (storage: true/false)");
  else
    for (const [k, v] of Object.entries(cfg.needs)) {
      if (typeof v !== "boolean") err(`platform.yaml: needs.${k} must be true or false`);
      else if (k === "postgres" || k === "redis") {
        if (v) err(`platform.yaml: needs.${k} isn't available yet. Ask the platform team`);
      } else if (k !== "storage") err(`platform.yaml: needs.${k} isn't something the platform provides`);
    }
  if (!errors.some((e) => e.startsWith("platform.yaml"))) ok("platform.yaml is valid");
}
const needs = cfg?.needs && typeof cfg.needs === "object" ? cfg.needs : {};
const healthPath = typeof cfg?.healthcheck === "string" ? cfg.healthcheck : "/api/health";

// ---------- required files ----------

const pkgText = read("package.json");
let pkg = {};
if (!pkgText) err("package.json is missing at the repo root");
else {
  try {
    pkg = JSON.parse(pkgText);
  } catch {
    err("package.json isn't valid JSON");
  }
}
const deps = { ...(pkg.dependencies || {}), ...(pkg.devDependencies || {}) };
const scripts = pkg.scripts || {};

if (pkgText && !scripts.start) err('package.json has no "start" script. The container runs `npm start`');

if (exists("yarn.lock") || exists("pnpm-lock.yaml") || exists("bun.lockb") || exists("bun.lock"))
  err("Use npm: remove yarn/pnpm/bun lockfiles and commit package-lock.json");
else if (!exists("package-lock.json")) err("package-lock.json is missing. Run `npm install` and commit it");
else ok("package-lock.json present");

const dockerfile = read("Dockerfile");
if (!dockerfile) err("Dockerfile is missing. Copy templates/app/Dockerfile");
else {
  ok("Dockerfile present");
  if (/^\s*COPY\s+[^\n]*\.env(\s|$)/m.test(dockerfile)) err("Dockerfile copies a .env file into the image");
  if (/^\s*FROM\s+node:(1[0-9]|20)\b/im.test(dockerfile)) warn("Dockerfile uses an old Node version. The template uses node:24-slim");
}

const dockerignore = read(".dockerignore");
if (!dockerignore) err(".dockerignore is missing. Copy templates/app/dockerignore");
else if (!/node_modules/.test(dockerignore) || !/\.env/.test(dockerignore)) err(".dockerignore must exclude node_modules and .env files");
else ok(".dockerignore present");

const deployYml = read(".github/workflows/deploy.yml");
if (!deployYml) err(".github/workflows/deploy.yml is missing. Copy templates/app/deploy.yml");
else if (!deployYml.includes("Virtual-Protocol/projects-autodeploy/.github/workflows/deploy-app.yml"))
  err(".github/workflows/deploy.yml doesn't use the platform's deploy workflow. Copy templates/app/deploy.yml unchanged");
else ok("deploy workflow present");

for (const f of ["railway.toml", "railway.json", "nixpacks.toml", "vercel.json", "Procfile", "render.yaml", "netlify.toml"])
  if (exists(f)) warn(`${f} is for another host. Delete it once the app is live on Cloud Run`);

// ---------- env files & secrets ----------

const SECRETISH = /(SECRET|PRIVATE|SERVICE_ROLE|PASSWORD|PASSWD|TOKEN|CREDENTIAL)/;
const PUBLIC_PREFIX = /^(NEXT_PUBLIC_|VITE_)/;
const ALLOWED_ENV_FILES = new Set([".env.example", ".env.sample", ".env.template", ".env.production"]);
const envKeys = (text) =>
  (text || "")
    .split("\n")
    .map((l) => l.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=/)?.[1])
    .filter(Boolean);

if (tracked) {
  const badEnv = tracked.filter((f) => {
    const b = path.basename(f);
    return (b === ".env" || b.startsWith(".env.") || b.endsWith(".env")) && !ALLOWED_ENV_FILES.has(b);
  });
  for (const f of badEnv) {
    const full = path.join(root, f);
    const empty = fs.existsSync(full) && fs.statSync(full).size === 0;
    if (empty) warn(`${f} is committed to git (it's empty, so just delete it)`);
    else err(`${f} is committed to git. It may contain secrets: remove it, and tell the platform team so they can be rotated`);
  }
  const keyFiles = tracked.filter((f) => /\.json$/.test(f) && !/(^|\/)(package|package-lock|tsconfig|jsconfig)\.json$/.test(f)).filter((f) => {
    const text = read(f) || "";
    return text.includes('"service_account"') && text.includes('"private_key"');
  });
  for (const f of keyFiles) err(`${f} is a Google service account key. Remove it: the app gets Google access from its own account automatically`);
  if (!badEnv.length && !keyFiles.length) ok("no secrets committed");
} else warn("not a git repo, so committed-secrets checks were skipped");

const example = read(".env.example");
const exampleKeys = envKeys(example);
if (example === null) err(".env.example is missing. List every env var the app reads, with fake values");
else {
  for (const k of exampleKeys) {
    if (PUBLIC_PREFIX.test(k) && SECRETISH.test(k)) err(`.env.example: ${k} looks secret but its prefix sends it to every browser`);
    else if (PUBLIC_PREFIX.test(k) && /API_KEY/.test(k)) warn(`.env.example: ${k} goes to every browser. Make sure it's a browser-safe key`);
    if (k === "GOOGLE_APPLICATION_CREDENTIALS" || /^AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)$/.test(k))
      err(`.env.example: ${k}. Don't use cloud keys; the app gets Google access from its own account automatically`);
  }
}

const prodEnv = read(".env.production");
if (prodEnv !== null) {
  for (const k of envKeys(prodEnv)) {
    if (!PUBLIC_PREFIX.test(k)) err(`.env.production: ${k} isn't NEXT_PUBLIC_/VITE_. Only public build-time values belong in this committed file`);
    else if (SECRETISH.test(k)) err(`.env.production: ${k} looks secret but its prefix sends it to every browser`);
  }
}

const PLATFORM_VARS = new Set(["PORT", "NODE_ENV", "APP_URL", "STORAGE_BUCKET", "GOOGLE_CLOUD_PROJECT", "HOSTNAME", "NEXT_RUNTIME", "CI", "TZ", "K_SERVICE", "K_REVISION", "K_CONFIGURATION"]);
const readVars = new Set();
for (const text of code.values()) {
  for (const m of text.matchAll(/(?:process\.env|import\.meta\.env)(?:\.([A-Z_][A-Z0-9_]*)|\[\s*['"]([A-Z_][A-Z0-9_]*)['"]\s*\])/g)) readVars.add(m[1] || m[2]);
}
const undocumented = [...readVars].filter((v) => !PLATFORM_VARS.has(v) && !exampleKeys.includes(v) && !v.startsWith("VERCEL") && !v.startsWith("RAILWAY")).sort();
if (example !== null && undocumented.length)
  warn(`code reads env vars missing from .env.example: ${undocumented.slice(0, 12).join(", ")}${undocumented.length > 12 ? ", …" : ""}`);
const hostVars = [...readVars].filter((v) => v.startsWith("VERCEL") || v.startsWith("RAILWAY"));
if (hostVars.length) warn(`code reads another host's env vars: ${hostVars.join(", ")}. Use APP_URL / platform vars instead`);

// ---------- port & health ----------

const usesNextStart = /\bnext start\b/.test(scripts.start || "");
const hardPort = findInCode(/\.listen\(\s*\d{2,5}\s*[,)]/);
if (hardPort.length) err(`hardcoded port in .listen() (${hardPort.join(", ")}). Use process.env.PORT`);
if (!usesNextStart && !readVars.has("PORT")) err("couldn't find the app reading process.env.PORT. It must listen on PORT");
else ok(usesNextStart ? "uses `next start` (listens on PORT)" : "reads process.env.PORT");

const segs = escapeRe(healthPath.replace(/^\/|\/$/g, ""));
const nextRouteRe = new RegExp(`(^|/)(src/)?app/${segs}/route\\.(t|j)s$`);
const nextPagesRe = new RegExp(`(^|/)(src/)?pages/${segs}(/index)?\\.(t|j)sx?$`);
const healthFile = codeFiles.find((f) => nextRouteRe.test(f) || nextPagesRe.test(f));
const healthLiteral = findInCode(new RegExp(`['"\`]${escapeRe(healthPath)}['"\`]`), { limit: 1 });
if (!healthFile && !healthLiteral.length) err(`no route found for the health check ${healthPath}. Add one that returns 200 without login or database calls`);
else {
  ok(`health route found (${healthFile || healthLiteral[0]})`);
  const body = healthFile ? code.get(healthFile).replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "") : null;
  if (body && /prisma|\$queryRaw|\.query\(|supabase|redis|fetch\(/i.test(body))
    warn(`${healthFile} calls the database or another service. Keep the health check shallow, or a database blip restarts the app`);
}

for (const mw of ["middleware.ts", "middleware.js", "src/middleware.ts", "src/middleware.js"]) {
  const text = read(mw);
  if (text && !text.includes(healthPath) && !/health/i.test(text))
    warn(`${mw} doesn't mention ${healthPath}. Make sure it doesn't redirect the health check to a login page`);
}

// Browser code ("use client") can poll on a timer; only server timers matter.
const timers = findInCode(/\bsetInterval\s*\(/).filter((hit) => !/^\s*["']use client["']/.test(code.get(hit.split(":")[0])));
if (deps["node-cron"] || deps.cron || timers.length)
  warn(`scheduled work found (${deps["node-cron"] ? "node-cron" : deps.cron ? "cron" : timers.join(", ")}). Cloud Run pauses idle apps, so timers don't run reliably; ask the platform team for a schedule`);

// ---------- data & files ----------

if (deps["better-sqlite3"] || deps.sqlite3 || deps.sqlite || deps.lowdb || deps["node-json-db"]) err("SQLite / file database dependency found. Data must live in a real database");
const prismaSchema = read("prisma/schema.prisma");
if (prismaSchema && /provider\s*=\s*"sqlite"/.test(prismaSchema)) err("prisma/schema.prisma uses sqlite. Use postgresql");

for (const s of ["start", "prestart", "build", "postinstall"]) {
  if (/db push|migrate reset|accept-data-loss|force-reset/.test(scripts[s] || "")) err(`package.json "${s}" runs a destructive database command: ${scripts[s]}`);
}

const diskUploads = findInCode(/multer\.diskStorage|multer\(\s*\{\s*dest\s*:|express\.static\(\s*['"`][^'"`]*upload/i);
if (diskUploads.length) err(`files are saved to local disk (${diskUploads.join(", ")}). The disk is wiped on every deploy: use needs.storage (Cloud Storage)`);
const diskWrites = findInCode(/\bfs\.(writeFile|writeFileSync|appendFile|appendFileSync|createWriteStream|mkdirSync)\s*\(/).filter((h) => {
  const [f, line] = h.split(":");
  return !/tmpdir|['"`]\/tmp/.test(code.get(f).split("\n")[Number(line) - 1]);
});
if (diskWrites.length) warn(`writes to local disk (${diskWrites.join(", ")}). Anything that must survive a restart belongs in a database or Cloud Storage`);
if (deps["@aws-sdk/client-s3"]) warn("uses S3. On this platform, files go to Cloud Storage: set needs.storage and use @google-cloud/storage");
if (deps["@google-cloud/storage"] && !needs.storage && cfg) warn("uses Cloud Storage but needs.storage isn't true");
if (deps.bullmq || deps.ioredis || deps.redis) warn("uses Redis. Redis isn't available on the platform yet: ask the platform team");

const outside = ["@supabase/supabase-js", "@supabase/ssr", "firebase", "firebase-admin", "@vercel/kv", "@vercel/postgres", "@vercel/blob", "@neondatabase/serverless", "@upstash/redis", "@clerk/nextjs", "@auth0/nextjs-auth0", "cloudinary"].filter((d) => deps[d]);
if (outside.length) warn(`outside services that hold data need approval: ${outside.join(", ")}`);

// ---------- report ----------

if (inActions) {
  for (const e of errors) console.log(`::error::${e}`);
  for (const w of warnings) console.log(`::warning::${w}`);
}
console.log(`\nprojects-autodeploy check: ${root}\n`);
for (const e of errors) console.log(`  ✗ ${e}`);
for (const w of warnings) console.log(`  ! ${w}`);
for (const p of passes) console.log(`  ✓ ${p}`);
console.log(`\n${errors.length} error(s), ${warnings.length} warning(s), ${passes.length} passed\n`);
process.exit(errors.length ? 1 : 0);
