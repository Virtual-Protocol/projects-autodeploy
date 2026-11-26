#!/usr/bin/env bash
# Reads the app's platform.yaml and checks it. Anyone at the company may host an
# app; what it does (who can open it, public or not) comes only from this file,
# which only someone who can push to the repo could have written.
#   scripts/read-platform.sh <app dir>
set -euo pipefail

dir="$1"
file="$dir/platform.yaml"

fail() {
  echo "::error::$1"
  printf '### Not hosted\n\n%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  exit 1
}

# One line, no control characters: these values end up in messages.
field() { yq -r "$1 // \"\"" "$file" | tr -d '\000-\037' ; }

[[ -f "$file" ]] ||
  fail "The repo has no platform.yaml. Ask Claude to get the app ready for hosting first."

name=$(field .name)
owner=$(field .owner | tr '[:upper:]' '[:lower:]')

[[ "$name" =~ ^[a-z][a-z0-9-]{1,22}[a-z0-9]$ && "$name" != *--* ]] ||
  fail "name in platform.yaml must be 3-24 lowercase letters, digits and single dashes."

for need in postgres redis; do
  [[ "$(field ".needs.$need")" != true ]] ||
    fail "needs.$need isn't available yet. Ask the platform team."
done

storage=$(field .needs.storage)
[[ "$storage" == true ]] || storage=false

# The owner decides: public: true opens the app to anyone, with no sign-in.
public=$(field .public)
[[ "$public" == true ]] || public=false

# What the owner sets on GitHub before the first deploy, named as deploy-app.yml
# reads them from .env.example: public values are variables, the rest secrets.
keys=$(sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$dir/.env.example" 2>/dev/null |
  grep -vxE 'PORT|NODE_ENV|APP_URL|STORAGE_BUCKET|GOOGLE_CLOUD_PROJECT' | sort -u || true)
secrets=$(grep -vE '^(NEXT_PUBLIC_|VITE_)' <<<"$keys" | paste -sd, - || true)
variables=$(grep -E '^(NEXT_PUBLIC_|VITE_)' <<<"$keys" | paste -sd, - || true)

{
  echo "name=$name"
  echo "owner=$owner"
  echo "storage=$storage"
  echo "public=$public"
  echo "secrets=$secrets"
  echo "variables=$variables"
} >> "$GITHUB_OUTPUT"
echo "platform.yaml checks passed: $name, owned by $owner$([[ "$public" == true ]] && echo ", public")."
