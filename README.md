# __DOMAIN_TITLE__

<!-- SKELETON: replace the content, keep the structure. This is the
     human-facing walkthrough; AGENTS.md is the agent-facing one.
     Write for someone who runs this in their own project to learn, in the
     second person. Never write for a presenter. Leave out time estimates
     and cost claims. -->

> One-paragraph pitch: what this domain does, which Google Cloud products it
> uses, and why someone would look at it.

Standalone and self-contained — clone it, point it at your own GCP project, and
`tofu apply` builds everything including the data.

<!-- 3 or 4 highlight bullets, then link to docs/README.md and docs/quick.md. -->

## Architecture

<!-- One diagram that answers "what happens?" in about five boxes, with the
     product behind each. The wiring and call order go in docs/architecture.md. -->

## Prerequisites

1. **A GCP project with billing** (one-time, created out-of-band):
   ```bash
   gcloud projects create __PROJECT_ID__ --organization=<YOUR_ORG_ID>
   gcloud billing projects link __PROJECT_ID__ --billing-account=<YOUR_BILLING_ACCOUNT>
   gcloud auth login
   gcloud auth application-default login
   ```
   Tofu uses the application default credentials. `bq`, `gcloud` and the
   scripts use the CLI login.
2. **[OpenTofu](https://opentofu.org) 1.6 or later** (`tofu`). `setup.sh` runs `tofu init`.
3. `curl`, `python3`, `gsutil` — all ship with `gcloud`.

__GIT_LINK_PREREQ__

## Quickstart

```bash
./infra/scripts/setup.sh   # one-time per project: APIs + state bucket + tofu init
cd infra && tofu apply     # zero required variables — every one has a default
```

`setup.sh` handles what Terraform can't bootstrap itself: it enables the Cloud
Resource Manager / Service Usage APIs, creates a **versioned** state bucket at
`gs://__PROJECT_ID__-tfstate`, and runs `tofu init` against it. Re-running is a
safe no-op.

To deploy elsewhere, change `project_id`'s default in `infra/variables.tf` —
that one value drives everything — or pass `--project=<id>` to `setup.sh`.

> **State lives remotely** and versioned, so a bad apply is recoverable. Each
> fork gets its own bucket in its own project; nothing is shared.

## Verify

```sql
-- replace with this domain's real checks
SELECT * FROM `serving.<table>` LIMIT 10;
SELECT * FROM `assertions.<assertion>`;   -- empty = healthy
```

## Try it

<!-- Link to the step-by-step guide in docs/01-<topic>.md, with one sentence
     on what the reader does there. -->

## What gets created

| Resource | Notes |
| --- | --- |
| BigQuery datasets | one per medallion stage, plus `assertions` |
| Dataform repository | __GIT_LINK_SHORT__ |
| Runner service account | workflow invocations execute as it |
| First-run trigger | `run_pipeline_on_apply` builds everything at the end of apply |

## Data quality

`definitions/assertions/` hard-fails the workflow when a healthy pipeline would
return zero rows. `definitions/monitoring/` surfaces rows that are *expected*
sometimes — model drift, known-imperfect upstream data — without blocking a run.

## Known limitations

<!-- Only limitations you confirmed and can reproduce, each linked to its
     issue. Delete this section if there are none. -->

## Cleanup

```bash
cd infra && tofu destroy
```

Two things are deliberately left behind, because Tofu didn't create them: the
project and the state bucket. Remove them by hand if you want the project gone:

```bash
gcloud storage rm -r gs://__PROJECT_ID__-tfstate
gcloud projects delete __PROJECT_ID__
```
