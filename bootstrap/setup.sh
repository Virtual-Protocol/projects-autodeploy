#!/usr/bin/env bash
# One-time setup of the shared Google Cloud project and this repo's GitHub
# settings. Run once by a project Owner who is also an admin of this repo,
# after `gcloud auth login` and `gh auth login`. Safe to re-run.
#
#   ./bootstrap/setup.sh
#
# It creates two accounts GitHub Actions can act as, without keys:
#   autodeploy-deployer     used only by .github/workflows/deploy-app.yml
#   autodeploy-provisioner  used only by .github/workflows/host-app.yml
# Each is reachable only from that exact workflow file on this repo's main
# branch, so changes to main here need a reviewer.
set -euo pipefail
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

PROJECT_ID=virtuals-internal-apps
REGION=asia-southeast1
ORG=Virtual-Protocol
THIS_REPO=projects-autodeploy
POOL=github
PROVIDER=autodeploy
REGISTRY=apps
DEPLOYER=autodeploy-deployer
PROVISIONER=autodeploy-provisioner
SECRET_ROLE=autodeploySecretWriter

gcloud config set project "$PROJECT_ID" >/dev/null
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format 'value(projectNumber)')
DEPLOYER_SA="$DEPLOYER@$PROJECT_ID.iam.gserviceaccount.com"
PROVISIONER_SA="$PROVISIONER@$PROJECT_ID.iam.gserviceaccount.com"
POOL_PATH="projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL"
WORKFLOWS="$ORG/$THIS_REPO/.github/workflows"

step() { printf '\n== %s\n' "$1"; }
grant() { # member role
  gcloud projects add-iam-policy-binding "$PROJECT_ID" --condition=None \
    --member "$1" --role "$2" >/dev/null
}

step "APIs"
gcloud services enable \
  run.googleapis.com \
  cloudresourcemanager.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  iap.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  storage.googleapis.com

step "Image repository"
gcloud artifacts repositories describe "$REGISTRY" --location "$REGION" >/dev/null 2>&1 ||
  gcloud artifacts repositories create "$REGISTRY" --repository-format docker --location "$REGION" \
    --description "Internal app images"

step "Accounts for GitHub Actions"
for sa in "$DEPLOYER:deploys apps (deploy-app.yml)" "$PROVISIONER:sets up new apps (host-app.yml)"; do
  id="${sa%%:*}"
  gcloud iam service-accounts describe "$id@$PROJECT_ID.iam.gserviceaccount.com" >/dev/null 2>&1 ||
    gcloud iam service-accounts create "$id" --display-name "projects-autodeploy: ${sa#*:}"
done

step "What the deployer may do"
# Write secret values, never read them.
permissions=secretmanager.secrets.create,secretmanager.secrets.get,secretmanager.secrets.list,secretmanager.secrets.update,secretmanager.versions.add,secretmanager.versions.disable,secretmanager.versions.get,secretmanager.versions.list
if gcloud iam roles describe "$SECRET_ROLE" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam roles update "$SECRET_ROLE" --project "$PROJECT_ID" --permissions "$permissions" >/dev/null
else
  gcloud iam roles create "$SECRET_ROLE" --project "$PROJECT_ID" \
    --title "projects-autodeploy secret writer" \
    --description "Adds secret values without being able to read them" \
    --permissions "$permissions" >/dev/null
fi
grant "serviceAccount:$DEPLOYER_SA" "projects/$PROJECT_ID/roles/$SECRET_ROLE"
grant "serviceAccount:$DEPLOYER_SA" roles/run.developer
gcloud artifacts repositories add-iam-policy-binding "$REGISTRY" --location "$REGION" \
  --member "serviceAccount:$DEPLOYER_SA" --role roles/artifactregistry.writer >/dev/null
# Acting as each app's own account is granted per app, by host-app.yml.

step "What the provisioner may do"
for role in roles/run.admin roles/iam.serviceAccountAdmin roles/iam.serviceAccountUser \
  roles/resourcemanager.projectIamAdmin roles/iap.admin roles/storage.admin; do
  grant "serviceAccount:$PROVISIONER_SA" "$role"
done
# Changing an existing app's service makes Cloud Run re-read its current image,
# which needs read access to it.
gcloud artifacts repositories add-iam-policy-binding "$REGISTRY" --location "$REGION" \
  --member "serviceAccount:$PROVISIONER_SA" --role roles/artifactregistry.reader >/dev/null

step "Keyless sign-in from this repo's workflows"
gcloud iam workload-identity-pools describe "$POOL" --location global >/dev/null 2>&1 ||
  gcloud iam workload-identity-pools create "$POOL" --location global --display-name "GitHub Actions"
mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.role=assertion.job_workflow_ref == \"$WORKFLOWS/deploy-app.yml@refs/heads/main\" ? \"deployer\" : (assertion.job_workflow_ref == \"$WORKFLOWS/host-app.yml@refs/heads/main\" ? \"provisioner\" : \"none\")"
condition="assertion.repository_owner == \"$ORG\""
if gcloud iam workload-identity-pools providers describe "$PROVIDER" --workload-identity-pool "$POOL" \
  --location global >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers update-oidc "$PROVIDER" --workload-identity-pool "$POOL" \
    --location global --attribute-mapping "$mapping" --attribute-condition "$condition" >/dev/null
else
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" --workload-identity-pool "$POOL" \
    --location global --display-name "projects-autodeploy" \
    --issuer-uri "https://token.actions.githubusercontent.com" \
    --attribute-mapping "$mapping" --attribute-condition "$condition"
fi
gcloud iam service-accounts add-iam-policy-binding "$DEPLOYER_SA" --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/$POOL_PATH/attribute.role/deployer" >/dev/null
gcloud iam service-accounts add-iam-policy-binding "$PROVISIONER_SA" --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/$POOL_PATH/attribute.role/provisioner" >/dev/null

step "Google sign-in's own account"
curl -fsS -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://serviceusage.googleapis.com/v1beta1/projects/$PROJECT_NUMBER/services/iap.googleapis.com:generateServiceIdentity" \
  >/dev/null

step "GitHub: let other $ORG repos use this repo's deploy workflow"
gh api -X PUT "repos/$ORG/$THIS_REPO/actions/permissions/access" -f access_level=organization >/dev/null

cat <<EOF

Done. One thing left, which needs a person:

  Create a fine-grained GitHub token that can read the code of $ORG repos
  (Repository access: All repositories; Permissions: Contents read-only,
  Metadata read-only), then save it in this repo:

    gh secret set ORG_READ_TOKEN -R $ORG/$THIS_REPO

  host-app.yml uses it to read the repo being hosted.
EOF
