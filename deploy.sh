#!/usr/bin/env bash
# Manual deployment driver for herdr-web-gcp. Everything in GCP is created by
# the Terraform roots under infra/, applied through GCP Infrastructure Manager
# as the deployer service account; this script only sequences the gcloud and
# docker steps around them. Nothing here is automatic: each subcommand is run
# by a human, in the order README.md describes.
#
#   ./deploy.sh preview project|service  dry run (Infra Manager preview) of a root
#   ./deploy.sh project                  apply infra/project (creates a project; optional)
#   ./deploy.sh base                     phase 1 of infra/service (APIs, SA, secret, AR; no service yet)
#   ./deploy.sh secret                   add the Tailscale OAuth client secret as a secret version
#   ./deploy.sh image                    docker build + push, pin the digest in infra/service/image.auto.tfvars
#   ./deploy.sh apply                    phase 2 of infra/service (service, IAP bindings)
#   ./deploy.sh url                      print the service URL and IAP audience
#   ./deploy.sh outputs project|service  print a deployment's Terraform outputs
#
# Config comes from .env (see .env.example; gitignored).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

if [[ ! -f .env ]]; then
  echo "error: .env not found; cp .env.example .env and fill it in" >&2
  exit 1
fi
# shellcheck disable=SC1091
source .env

: "${WORKLOAD_PROJECT:?set in .env}"
: "${DEPLOYER_SA:?set in .env}"
: "${INFRA_PROJECT:=$WORKLOAD_PROJECT}"
: "${REGION:=us-central1}"
: "${IM_LOCATION:=us-central1}"
: "${DEPLOYMENT_PREFIX:=herdr-web}"

# Optionally run under a dedicated gcloud configuration without touching the
# caller's active one.
if [[ -n "${GCLOUD_CONFIG:-}" ]]; then
  export CLOUDSDK_ACTIVE_CONFIG_NAME="$GCLOUD_CONFIG"
fi

service_name="herdr-proxy"
secret_name="herdr-proxy-ts-authkey"
ar_repo="herdr-web"
image_name="herdr-iap-proxy"

usage() {
  # The header comment, up to the first blank non-comment line.
  awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"
  echo
  echo "error: unknown or missing subcommand '${1:-}'. Note: the secret is entered at a prompt, never on the command line." >&2
  exit 1
}

deployment_for() {
  case "$1" in
    project) echo "$DEPLOYMENT_PREFIX-project infra/project" ;;
    service) echo "$DEPLOYMENT_PREFIX-service infra/service" ;;
    *) echo "error: root must be project or service" >&2; exit 1 ;;
  esac
}

require_tfvars() {
  if [[ ! -f "$1/terraform.auto.tfvars" ]]; then
    echo "error: $1/terraform.auto.tfvars missing; cp $1/terraform.auto.tfvars.example $1/terraform.auto.tfvars and fill it in" >&2
    exit 1
  fi
}

im_apply() {
  read -r dep src <<<"$(deployment_for "$1")"
  require_tfvars "$src"
  echo ">> infra-manager apply $dep from $src (as $DEPLOYER_SA)"
  gcloud infra-manager deployments apply "$dep" \
    --project="$INFRA_PROJECT" \
    --location="$IM_LOCATION" \
    --local-source="$src" \
    --service-account="projects/$INFRA_PROJECT/serviceAccounts/$DEPLOYER_SA" \
    --quiet
  im_outputs "$1"
}

im_preview() {
  read -r dep src <<<"$(deployment_for "$1")"
  require_tfvars "$src"
  local preview
  preview="prev-$(date +%Y%m%d-%H%M%S)"
  # A preview against an existing deployment diffs its state; before the
  # first apply there is nothing to diff against, so preview as a new one.
  local dep_flag=()
  if gcloud infra-manager deployments describe "$dep" \
      --project="$INFRA_PROJECT" --location="$IM_LOCATION" >/dev/null 2>&1; then
    dep_flag=(--deployment="projects/$INFRA_PROJECT/locations/$IM_LOCATION/deployments/$dep")
  else
    echo ">> $dep does not exist yet; previewing as a new deployment"
  fi
  echo ">> infra-manager preview $preview for $dep from $src"
  gcloud infra-manager previews create "$preview" \
    --project="$INFRA_PROJECT" \
    --location="$IM_LOCATION" \
    "${dep_flag[@]}" \
    --local-source="$src" \
    --service-account="projects/$INFRA_PROJECT/serviceAccounts/$DEPLOYER_SA" \
    --quiet
  # Summarise the plan (the export URLs are signed and expire in 5 minutes).
  local plan_url
  plan_url="$(gcloud infra-manager previews export "$preview" \
    --project="$INFRA_PROJECT" --location="$IM_LOCATION" --quiet \
    --format='value(result.jsonSignedUri)')"
  if [[ -n "$plan_url" ]] && command -v jq >/dev/null; then
    echo ">> planned changes:"
    curl -sfL "$plan_url" | jq -r '
      (.resource_changes // [])[]
      | select(.change.actions != ["no-op"])
      | "  \(.change.actions | join(",") | ascii_upcase)\t\(.address)"'
    echo ">> (anything not listed is unchanged)"
  else
    echo ">> preview created: $preview (install jq for a plan summary)"
  fi
}

im_outputs() {
  read -r dep _ <<<"$(deployment_for "$1")"
  local rev
  rev="$(gcloud infra-manager deployments describe "$dep" \
    --project="$INFRA_PROJECT" --location="$IM_LOCATION" \
    --format='value(latestRevision)')"
  echo ">> outputs of $rev"
  gcloud infra-manager revisions describe "$rev" \
    --project="$INFRA_PROJECT" --location="$IM_LOCATION" \
    --format='yaml(applyResults.outputs)'
}

cmd_secret() {
  local secret
  if [[ "${1:-}" == "--from-file" ]]; then
    # For runners without a TTY: write the secret to a mode-0600 file, pass
    # it here; the file is deleted after the version is added.
    local f="${2:?--from-file needs a path}"
    secret="$(tr -d '[:space:]' < "$f")"
  else
    if [[ ! -t 0 ]]; then
      echo "error: no terminal for the hidden prompt. Run this in a real terminal, or:" >&2
      echo "  (umask 077; cat > ~/.herdr-ts-secret)   # paste, Enter, Ctrl-D" >&2
      echo "  ./deploy.sh secret --from-file ~/.herdr-ts-secret" >&2
      exit 1
    fi
    echo "Paste the Tailscale OAuth client secret (tskey-client-...). It is not echoed and not stored locally."
    read -rs -p "secret: " secret; echo
  fi
  if [[ "$secret" != tskey-client-* ]]; then
    echo "error: that does not look like an OAuth client secret (expected tskey-client-...)" >&2
    exit 1
  fi
  printf '%s' "$secret" | gcloud secrets versions add "$secret_name" \
    --project="$WORKLOAD_PROJECT" --data-file=- --quiet
  unset secret
  if [[ "${1:-}" == "--from-file" ]]; then
    rm -f "$2" && echo ">> deleted $2"
  fi
  echo ">> secret version added. Cloud Run reads :latest on the next instance start."
}

cmd_image() {
  local registry="$REGION-docker.pkg.dev"
  local repo="$registry/$WORKLOAD_PROJECT/$ar_repo/$image_name"
  local tag
  tag="$(git rev-parse --short HEAD)"
  if [[ -n "$(git status --porcelain src/herdr-iap-proxy)" ]]; then
    tag="$tag-dirty"
  fi
  echo ">> building $repo:$tag"
  gcloud auth configure-docker "$registry" --quiet
  docker build --platform linux/amd64 -t "$repo:$tag" src/herdr-iap-proxy
  docker push "$repo:$tag"
  local digest
  digest="$(gcloud artifacts docker images describe "$repo:$tag" \
    --project="$WORKLOAD_PROJECT" --format='value(image_summary.digest)')"
  [[ "$digest" == sha256:* ]] || { echo "error: could not resolve digest" >&2; exit 1; }
  cat > infra/service/image.auto.tfvars <<TFV
# Written by ./deploy.sh image on $(date -u +%Y-%m-%dT%H:%M:%SZ) from git $tag.
# Pinned by digest (never a tag); commit this file. Removing it or emptying
# image makes the next apply DESTROY the Cloud Run service (count = 0).
image = "$repo@$digest"
TFV
  echo ">> wrote infra/service/image.auto.tfvars:"
  cat infra/service/image.auto.tfvars
  echo ">> commit it, then ./deploy.sh apply"
}

cmd_url() {
  gcloud run services describe "$service_name" \
    --project="$WORKLOAD_PROJECT" --region="$REGION" \
    --format='value(status.url)'
  local number
  number="$(gcloud projects describe "$WORKLOAD_PROJECT" --format='value(projectNumber)')"
  echo "IAP audience: /projects/$number/locations/$REGION/services/$service_name"
  gcloud run services describe "$service_name" \
    --project="$WORKLOAD_PROJECT" --region="$REGION" \
    --format='value(spec.template.metadata.annotations)' | tr ',' '\n' | grep -i iap || true
}

case "${1:-}" in
  preview)  im_preview "${2:-}" ;;
  project)
    if [[ "$INFRA_PROJECT" == "$WORKLOAD_PROJECT" ]]; then
      echo "error: 'project' creates WORKLOAD_PROJECT, so Infra Manager must run somewhere else: set INFRA_PROJECT in .env to an existing project" >&2
      exit 1
    fi
    im_apply project ;;
  base)
    if [[ -s infra/service/image.auto.tfvars ]]; then
      echo "note: infra/service/image.auto.tfvars exists; 'base' and 'apply' are now the same thing." >&2
    fi
    im_apply service ;;
  apply)
    if [[ ! -s infra/service/image.auto.tfvars ]]; then
      echo "error: infra/service/image.auto.tfvars missing; run ./deploy.sh image first (or use 'base' for phase 1)" >&2
      exit 1
    fi
    im_apply service ;;
  secret)   cmd_secret "${2:-}" "${3:-}" ;;
  image)    cmd_image ;;
  url)      cmd_url ;;
  outputs)  im_outputs "${2:-}" ;;
  *) usage "${1:-}" ;;
esac
