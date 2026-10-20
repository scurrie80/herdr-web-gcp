# infra/

Terraform for herdr-web-gcp, executed via **GCP Infrastructure Manager**: state
is stored and locked by the service, so no `backend` block is defined here.
Applies are driven by `../deploy.sh`.

```
infra/
├── project/   # root 1 (optional): a dedicated GCP project     (<prefix>-project)
└── service/   # root 2: everything else                        (<prefix>-service)
```

If you prefer plain `terraform` without Infra Manager, each root works as-is
with local state, or add a `backend_override.tf` (gitignored and gcloudignored)
with your own backend. `deploy.sh image` and `deploy.sh secret` are still
useful; replace `base`/`apply` with `terraform apply` in `service/`.

## Deployer service account

Infra Manager runs Terraform as a service account you provide
(`DEPLOYER_SA` in `.env`). The simplest setup, with everything in one project:

```sh
PROJECT=my-herdr-project
SA=herdr-deployer

gcloud services enable config.googleapis.com --project=$PROJECT
gcloud iam service-accounts create $SA --project=$PROJECT --display-name="herdr-web-gcp deployer"
SA_EMAIL=$SA@$PROJECT.iam.gserviceaccount.com

# Infra Manager itself needs this on the project that hosts the deployments.
gcloud projects add-iam-policy-binding $PROJECT --member=serviceAccount:$SA_EMAIL --role=roles/config.agent
# Terraform's own permissions on the workload project. Owner is the easy way;
# a least-privilege list is below.
gcloud projects add-iam-policy-binding $PROJECT --member=serviceAccount:$SA_EMAIL --role=roles/owner

# Your own account needs to drive Infra Manager and act as the deployer.
ME=$(gcloud config get-value account)
gcloud projects add-iam-policy-binding $PROJECT --member=user:$ME --role=roles/config.admin
gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL --project=$PROJECT --member=user:$ME --role=roles/iam.serviceAccountUser
```

Least-privilege alternative to `roles/owner` on the workload project for the
`service/` root: `roles/serviceusage.serviceUsageAdmin`, `roles/run.admin`,
`roles/iap.admin`, `roles/secretmanager.admin`, `roles/artifactregistry.admin`,
`roles/iam.serviceAccountAdmin`, `roles/iam.serviceAccountUser` (to deploy a
service running as the runtime SA) and `roles/viewer`.

For the optional `project/` root the deployer additionally needs
`roles/resourcemanager.projectCreator` on the parent folder or organization
and `roles/billing.user` on the billing account, and `INFRA_PROJECT` in `.env`
must be a different, existing project (Infra Manager cannot run in a project
it is about to create).

## Inputs

| Value | Source | Goes in |
|---|---|---|
| `project_id` | your existing project, or `project/` output `project_id` | `service/terraform.auto.tfvars` and `../.env` (`WORKLOAD_PROJECT`) |
| `upstream`, `iap_members` | you | `service/terraform.auto.tfvars` |
| `image` (by digest) | `../deploy.sh image` | `service/image.auto.tfvars` |

The two roots are wired by these committed values, never by reading each
other's state.

## Two phases

`service/` is applied twice the first time, because Cloud Run validates both
the image and the secret version when the service is created, and neither can
exist before the Artifact Registry repo and the secret do:

1. **Phase 1** (`./deploy.sh base`, `image.auto.tfvars` absent): APIs, service
   agents, runtime SA, secret (metadata only), Artifact Registry.
2. Push the image (`./deploy.sh image`) and add the secret version
   (`./deploy.sh secret`).
3. **Phase 2** (`./deploy.sh apply`): the Cloud Run service with IAP enabled
   and its IAM bindings.

`image.auto.tfvars` is the switch: empty or missing means no service. Keep it
committed and never pass `image` via `--input-values`; an apply that forgets
the value would destroy the service.

## What is deliberately not in Terraform

- The secret **value** (`gcloud secrets versions add`, via `deploy.sh secret`).
- The IAP custom OAuth client needed only for consumer accounts inside an
  organization: a one-time Console step (see `../README.md`).
- The tailnet policy (`../tailscale/policy-snippet.hujson`, merged by hand)
  and the Tailscale OAuth client.

## Running it

```sh
cp ../.env.example ../.env && chmod 600 ../.env                                   # fill in
cp service/terraform.auto.tfvars.example service/terraform.auto.tfvars            # fill in

../deploy.sh preview project && ../deploy.sh project   # only if creating a project
../deploy.sh preview service                           # dry run
../deploy.sh base                                      # phase 1
../deploy.sh secret                                    # Tailscale OAuth client secret
../deploy.sh image                                     # build, push, pin digest; commit image.auto.tfvars
../deploy.sh apply                                     # phase 2
../deploy.sh url
```

Every `deployments apply` is idempotent; re-run it after any change under
`infra/`. To inspect state or drift:

```sh
gcloud infra-manager deployments describe <prefix>-service --project=<INFRA_PROJECT> --location=<IM_LOCATION>
gcloud infra-manager resources list --deployment=<prefix>-service --revision=<rev> --project=<INFRA_PROJECT> --location=<IM_LOCATION>
```

## Teardown

1. Remove `service/image.auto.tfvars` and apply: destroys the service and its
   IAM members, keeps the rest.
2. `gcloud infra-manager deployments delete <prefix>-service --project=<INFRA_PROJECT> --location=<IM_LOCATION>`
   destroys phase-1 resources (the secret's versions go with it).
3. If you used `project/`: the project is intentionally hard to delete. Edit
   `project/main.tf` (`deletion_policy = "DELETE"`, drop `prevent_destroy`),
   apply, then delete the `-project` deployment. Or just leave the empty
   project; it costs nothing.
4. Revert the tailnet policy change and delete the Tailscale OAuth client.
