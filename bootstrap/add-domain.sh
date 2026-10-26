#!/usr/bin/env bash
# Gives a hosted app its own domain (e.g. support.virtuals.io), through one
# load balancer that every app with a domain shares; it's created on first use.
# Run by a platform engineer, with gcloud signed in as a project owner:
#
#   bootstrap/add-domain.sh <app name> <domain>
#
# It prints the DNS records to add. The HTTPS certificate is issued before the
# domain is switched over, so visitors never see a certificate warning. Safe
# to re-run: it skips what exists and reports the certificate's status.
#
# Once the domain points at the load balancer and works, send all of the app's
# traffic through it (run.app addresses then stop answering):
#
#   bootstrap/add-domain.sh <app name> <domain> --only-through-domain
set -euo pipefail

APP="${1:?usage: bootstrap/add-domain.sh <app name> <domain> [--only-through-domain]}"
DOMAIN="${2:?usage: bootstrap/add-domain.sh <app name> <domain> [--only-through-domain]}"
MODE="${3:-}"

PROJECT_ID=virtuals-internal-apps
REGION=asia-southeast1
LB=apps-lb
export CLOUDSDK_CORE_DISABLE_PROMPTS=1 CLOUDSDK_CORE_PROJECT="$PROJECT_ID"

# Resource names: lowercase letters, digits and dashes.
domain_id=$(tr '[:upper:].' '[:lower:]-' <<<"$DOMAIN")

step() { printf '\n== %s\n' "$1"; }
exists() { "$@" >/dev/null 2>&1; }

gcloud run services describe "$APP" --region "$REGION" >/dev/null ||
  { echo "No Cloud Run service \"$APP\". Host the app first." >&2; exit 1; }

if [[ "$MODE" == --only-through-domain ]]; then
  step "Only the load balancer can reach $APP now"
  gcloud run services update "$APP" --region "$REGION" --ingress internal-and-cloud-load-balancing >/dev/null
  echo "Done. $APP answers only at https://$DOMAIN."
  exit 0
fi

step "The shared load balancer"
gcloud services enable compute.googleapis.com certificatemanager.googleapis.com
exists gcloud compute addresses describe "$LB-ip" --global ||
  gcloud compute addresses create "$LB-ip" --global
exists gcloud certificate-manager maps describe "$LB-certs" ||
  gcloud certificate-manager maps create "$LB-certs"
redirect_map=$(mktemp)
trap 'rm -f "$redirect_map"' EXIT
if ! exists gcloud compute url-maps describe "$LB" --global; then
  # Hosts it doesn't know go to the company site.
  printf 'name: %s\ndefaultUrlRedirect:\n  hostRedirect: virtuals.io\n  stripQuery: true\n' "$LB" > "$redirect_map"
  gcloud compute url-maps import "$LB" --global --source "$redirect_map"
fi
exists gcloud compute target-https-proxies describe "$LB-https" --global ||
  gcloud compute target-https-proxies create "$LB-https" --global --url-map "$LB" --certificate-map "$LB-certs"
exists gcloud compute forwarding-rules describe "$LB-https" --global ||
  gcloud compute forwarding-rules create "$LB-https" --global --load-balancing-scheme EXTERNAL_MANAGED \
    --address "$LB-ip" --target-https-proxy "$LB-https" --ports 443
# Plain http:// is sent to https://.
if ! exists gcloud compute url-maps describe "$LB-http" --global; then
  printf 'name: %s-http\ndefaultUrlRedirect:\n  httpsRedirect: true\n  redirectResponseCode: MOVED_PERMANENTLY_DEFAULT\n' "$LB" > "$redirect_map"
  gcloud compute url-maps import "$LB-http" --global --source "$redirect_map"
fi
exists gcloud compute target-http-proxies describe "$LB-http" --global ||
  gcloud compute target-http-proxies create "$LB-http" --global --url-map "$LB-http"
exists gcloud compute forwarding-rules describe "$LB-http" --global ||
  gcloud compute forwarding-rules create "$LB-http" --global --load-balancing-scheme EXTERNAL_MANAGED \
    --address "$LB-ip" --target-http-proxy "$LB-http" --ports 80

step "$APP behind it"
exists gcloud compute network-endpoint-groups describe "$APP-neg" --region "$REGION" ||
  gcloud compute network-endpoint-groups create "$APP-neg" --region "$REGION" \
    --network-endpoint-type serverless --cloud-run-service "$APP"
if ! exists gcloud compute backend-services describe "$APP-backend" --global; then
  gcloud compute backend-services create "$APP-backend" --global --load-balancing-scheme EXTERNAL_MANAGED
  gcloud compute backend-services add-backend "$APP-backend" --global \
    --network-endpoint-group "$APP-neg" --network-endpoint-group-region "$REGION"
fi
if ! gcloud compute url-maps describe "$LB" --global --format json | jq -e --arg d "$DOMAIN" 'any(.hostRules[]?.hosts[]; . == $d)' >/dev/null; then
  gcloud compute url-maps add-path-matcher "$LB" --global --path-matcher-name "$domain_id" \
    --default-service "$APP-backend" --new-hosts "$DOMAIN"
fi

step "HTTPS certificate for $DOMAIN"
exists gcloud certificate-manager dns-authorizations describe "$domain_id" ||
  gcloud certificate-manager dns-authorizations create "$domain_id" --domain "$DOMAIN"
exists gcloud certificate-manager certificates describe "$domain_id" ||
  gcloud certificate-manager certificates create "$domain_id" --domains "$DOMAIN" --dns-authorizations "$domain_id"
exists gcloud certificate-manager maps entries describe "$domain_id" --map "$LB-certs" ||
  gcloud certificate-manager maps entries create "$domain_id" --map "$LB-certs" \
    --certificates "$domain_id" --hostname "$DOMAIN"

ip=$(gcloud compute addresses describe "$LB-ip" --global --format 'value(address)')
challenge_name=$(gcloud certificate-manager dns-authorizations describe "$domain_id" --format 'value(dnsResourceRecord.name)')
challenge_value=$(gcloud certificate-manager dns-authorizations describe "$domain_id" --format 'value(dnsResourceRecord.data)')
state=$(gcloud certificate-manager certificates describe "$domain_id" --format 'value(managed.state)')

cat <<EOF

DNS records for $DOMAIN (in Cloudflare: DNS only, grey cloud):

  1. Add now. Proves the domain is ours; the live site isn't affected.
       CNAME  ${challenge_name%.}  ->  ${challenge_value%.}

  2. When the certificate is ACTIVE (it's $state now; re-run this to check),
     point the domain here instead of its old host:
       A      $DOMAIN  ->  $ip

Then, once https://$DOMAIN works:
  bootstrap/add-domain.sh $APP $DOMAIN --only-through-domain
EOF
