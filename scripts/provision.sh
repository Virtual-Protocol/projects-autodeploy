#!/usr/bin/env bash
# Creates what one app needs on Google Cloud, so its repo can deploy. Runs in
# host-app.yml after the request and platform.yaml checks. Safe to re-run.
#
# Needs: NAME REPO REQUESTED_BY DATA_CLASS STORAGE
#        PROJECT_ID PROJECT_NUMBER REGION DOMAIN DEPLOYER_SA
set -euo pipefail

RUN_SA="app-$NAME@$PROJECT_ID.iam.gserviceaccount.com"
BUCKET="$PROJECT_ID-$NAME"

# Label values: lowercase letters, digits, _ and -, at most 63 characters.
label() { tr '[:upper:]' '[:lower:]' <<<"$1" | tr -c 'a-z0-9_\n-' '_' | cut -c1-63; }
repo_label=$(label "$REPO")
owner_label=$(label "${REQUESTED_BY%@*}")

fail() {
  echo "::error::$1"
  printf '### Not hosted\n\n%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  exit 1
}

# IAM can take a few seconds to see an account that was just created.
retry() {
  local attempt
  for attempt in 1 2 3 4 5 6; do
    "$@" && return 0
    sleep $((attempt * 5))
  done
  "$@"
}

step() { printf '\n== %s\n' "$1"; }

step "Is the name free?"
if current=$(gcloud run services describe "$NAME" --project "$PROJECT_ID" --region "$REGION" \
  --format 'value(metadata.labels.repo)' 2>/dev/null); then
  if [[ "$current" != "$repo_label" ]]; then
    fail "The name \"$NAME\" is already used by another app. Pick a different name in platform.yaml."
  fi
  echo "$NAME is already hosted from $REPO; checking its settings."
  exists=true
else
  exists=false
fi

step "The account the app runs as"
gcloud iam service-accounts describe "$RUN_SA" --project "$PROJECT_ID" >/dev/null 2>&1 ||
  gcloud iam service-accounts create "app-$NAME" --project "$PROJECT_ID" \
    --display-name "$NAME (runs the app)" --description "Virtual-Protocol/$REPO, owner $REQUESTED_BY"
# GitHub deploys may run the app as this account.
retry gcloud iam service-accounts add-iam-policy-binding "$RUN_SA" --project "$PROJECT_ID" \
  --member "serviceAccount:$DEPLOYER_SA" --role roles/iam.serviceAccountUser >/dev/null
# The app can read its own secrets (named "$NAME--...") and no one else's.
retry gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:$RUN_SA" --role roles/secretmanager.secretAccessor \
  --condition "expression=resource.name.startsWith(\"projects/$PROJECT_NUMBER/secrets/$NAME--\"),title=$NAME secrets only" \
  >/dev/null

if [[ "$STORAGE" == true ]]; then
  step "File storage"
  gcloud storage buckets describe "gs://$BUCKET" --project "$PROJECT_ID" >/dev/null 2>&1 ||
    gcloud storage buckets create "gs://$BUCKET" --project "$PROJECT_ID" --location "$REGION" \
      --uniform-bucket-level-access --public-access-prevention
  retry gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
    --member "serviceAccount:$RUN_SA" --role roles/storage.objectAdmin >/dev/null
fi

step "The Cloud Run service, behind Google sign-in"
labels="managed-by=projects-autodeploy,repo=$repo_label,owner=$owner_label,data=$DATA_CLASS"
if [[ "$exists" == false ]]; then
  # Google's sample page holds the name until the app's first deploy.
  retry gcloud run deploy "$NAME" --project "$PROJECT_ID" --region "$REGION" \
    --image us-docker.pkg.dev/cloudrun/container/hello \
    --service-account "$RUN_SA" \
    --no-allow-unauthenticated --iap \
    --labels "$labels"
else
  gcloud run services update "$NAME" --project "$PROJECT_ID" --region "$REGION" \
    --iap --update-labels "$labels" >/dev/null
fi
gcloud run services add-iam-policy-binding "$NAME" --project "$PROJECT_ID" --region "$REGION" \
  --member "serviceAccount:service-$PROJECT_NUMBER@gcp-sa-iap.iam.gserviceaccount.com" \
  --role roles/run.invoker >/dev/null
gcloud iap web add-iam-policy-binding --project "$PROJECT_ID" --region "$REGION" \
  --resource-type cloud-run --service "$NAME" \
  --member "domain:$DOMAIN" --role roles/iap.httpsResourceAccessor >/dev/null

url=$(gcloud run services describe "$NAME" --project "$PROJECT_ID" --region "$REGION" --format 'value(status.url)')

cat >> "$GITHUB_STEP_SUMMARY" <<EOF
### Hosted $NAME

$url (anyone with a @$DOMAIN Google account)

Next:
1. Add the app's secrets in the $REPO repo: Settings > Secrets and variables > Actions. Use the names in its .env.example.
2. Deploy: merge to main, or run the Deploy workflow from the repo's Actions tab.
EOF
echo "Hosted $NAME at $url"
