# design-automate

A GitHub Actions–based automation toolkit for provisioning AWS infrastructure (S3 folders + SSM Parameter Store entries) and deploying a frontend to S3/CloudFront on every push to `main`.

---

## Table of Contents

- [Why We Built This](#why-we-built-this)
- [What It Does](#what-it-does)
- [Workflows](#workflows)
  - [Design Automate (`design.yml`)](#1-design-automate-designyml)
  - [Deploy Frontend (`deploy.yml`)](#2-deploy-frontend-deployyml)
  - [Setup Script (`setup_project.sh`)](#3-setup-script-setup_projectsh)
- [Required Secrets & Variables](#required-secrets--variables)
- [Usage](#usage)
- [Security Decisions & Fixes](#security-decisions--fixes)

---

## Why We Built This

Setting up a new project on AWS manually is error-prone and slow:

- Developers had to create S3 "folders" and SSM parameters by hand each time a new project or feature branch was onboarded.
- Credentials were being managed inconsistently across teams.
- Frontend deployments required manual CLI commands, making releases fragile.

**design-automate** solves this by codifying the entire setup and deployment process as reproducible, auditable GitHub Actions workflows — eliminating manual steps and human error.

---

## What It Does

| Capability | Details |
|---|---|
| **S3 folder provisioning** | Creates `design-bucket-mb/<project>/<folder>/` on demand |
| **SSM Parameter Store** | Creates a KMS-encrypted `SecureString` at `/mb-design/<project>` |
| **Frontend deployment** | Builds a Vite app and syncs it to S3 with proper cache headers |
| **CloudFront invalidation** | Busts the CDN cache automatically on every deploy |
| **CI-safe inputs** | All secrets/variables are passed via `env:` blocks, never interpolated directly |

---

## Workflows

### 1. Design Automate (`design.yml`)

**Trigger:** Manual — click **"Run workflow"** in the **Actions** tab.

**What it does:**

1. Checks out the repository.
2. Configures AWS credentials from repository secrets.
3. Resolves and masks the `PARAM_VALUE` secret so it never appears in logs.
4. Validates that `PROJECT_NAME` and `FOLDER_NAME` variables are set.
5. Runs `setup_project.sh` to provision the AWS resources.

---

### 2. Deploy Frontend (`deploy.yml`)

**Trigger:** Automatic — every push to the `main` branch.

**What it does:**

1. Checks out code and sets up Node.js 20.
2. Installs dependencies with `npm ci`.
3. Builds the Vite frontend with the correct `--base` path (`/<project>/<folder>/`).
4. Configures AWS credentials.
5. Syncs all static assets to S3 (with `--delete` to remove stale files).
6. Syncs `index.html` **separately** with `no-cache` headers so browsers always fetch the latest HTML.
7. Creates a CloudFront invalidation for `/*` to flush the CDN.

---

### 3. Setup Script (`setup_project.sh`)

A self-contained Bash script that does the heavy lifting. It supports two modes:

**Interactive (local development):**
```bash
./setup_project.sh
# Prompts for project name, folder name, and SSM parameter value
```

**Non-interactive (CI/CD — flags):**
```bash
./setup_project.sh --project myproject --folder assets
```

**Non-interactive (CI/CD — environment variables):**
```bash
PROJECT_NAME=myproject FOLDER_NAME=assets ./setup_project.sh
```

> **Note:** `--value` / `PARAM_VALUE` is only required on the **first** run for a given project.
> If the SSM parameter already exists, the script skips creation silently.

**Script steps:**

| Step | Description |
|---|---|
| Pre-flight checks | Verifies AWS CLI is installed and credentials are valid |
| Project existence check | Checks if the S3 project folder already exists |
| S3 folder creation | Creates `<project>/` and `<project>/<folder>/` as zero-byte objects |
| SSM parameter creation | Creates a `SecureString` encrypted with `alias/aws/ssm` (default KMS key) |
| Summary | Prints what was created vs. what already existed |

---

## Required Secrets & Variables

Configure these in **Settings → Secrets and variables → Actions** before running any workflow.

### Secrets

| Name | Description |
|---|---|
| `AWS_SECRET_ACCESS_KEY` | IAM secret key for the deployment user/role |
| `PARAM_VALUE` | Value to store in SSM Parameter Store (stored as SecureString) |

### Variables

| Name | Scope | Description |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | Org or Repo | IAM access key ID |
| `AWS_REGION` | Org | AWS region (e.g. `us-east-1`) |
| `AWS_S3_BUCKET` | Org | Target S3 bucket name |
| `CF_DISTRIBUTION_ID` | Org | CloudFront distribution ID |
| `VITE_UFP_ENABLED` | Org | Feature flag for UFP |
| `VITE_UFP_PROVIDER` | Org | UFP provider name |
| `VITE_UFP_AWS_BUCKET` | Org | UFP S3 bucket |
| `VITE_UFP_AWS_IDENTITY_POOL_ID` | Org | Cognito Identity Pool ID |
| `PROJECT_NAME` | Repo | Project name (maps to S3 folder + SSM path) |
| `FOLDER_NAME` | Repo | Sub-folder name inside the project |
| `VITE_UFP_PROJECT_KEY` | Repo | UFP project key for the build |

---

## Usage

### First-time project setup

1. Set `PROJECT_NAME` and `FOLDER_NAME` as repository variables.
2. Set `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `PARAM_VALUE` as secrets.
3. Go to **Actions → Run Design Automate → Run workflow**.
4. The script creates the S3 folder structure and the SSM parameter.

### Adding a new folder to an existing project

1. Update the `FOLDER_NAME` repository variable to the new folder name.
2. Re-run **Run Design Automate** — the script detects the project already exists and only creates the new sub-folder. The SSM parameter is left unchanged.

### Deploying the frontend

Push to `main`. The **Deploy Frontend** workflow runs automatically:

```
push → npm ci → vite build → S3 sync → CloudFront invalidation
```

---

## Security Decisions & Fixes

This project explicitly addresses several common CI/CD security pitfalls.

### Fix: Script injection prevention

**Problem:** Using `${{ secrets.MY_SECRET }}` directly inside a `run:` block allows a crafted
value (e.g. containing backticks or `$()`) to execute arbitrary commands on the runner.

**Fix:** All secrets and variables are passed through an `env:` block and read as plain shell
variables (`$VAR_NAME`), never interpolated inline as `${{ ... }}` inside a script body:

```yaml
# ❌ Vulnerable — direct interpolation inside the script
run: echo "${{ secrets.PARAM_VALUE }}"

# ✅ Safe — value passed via env: block
env:
  PARAM_VALUE: ${{ secrets.PARAM_VALUE }}
run: echo "$PARAM_VALUE"
```

### Fix: Secrets masked in logs

The `PARAM_VALUE` secret is explicitly masked with `::add-mask::` before it is used anywhere,
so it can never appear in plaintext in the GitHub Actions log output:

```yaml
- name: Resolve and mask parameter value
  env:
    PARAM_VALUE_SECRET: ${{ secrets.PARAM_VALUE }}
  run: |
    VALUE="$PARAM_VALUE_SECRET"
    if [[ -n "$VALUE" ]]; then
      echo "::add-mask::$VALUE"
      echo "RESOLVED_PARAM_VALUE=$VALUE" >> "$GITHUB_ENV"
    fi
```

### Fix: SSM SecureString encryption

Parameters are stored as `SecureString` encrypted with the AWS-managed KMS key
(`alias/aws/ssm`), ensuring values are never stored in plaintext in Parameter Store.

### Fix: `index.html` cache-busting

Static assets (JS/CSS bundles) are deployed with normal long-lived caching.
`index.html` is deployed **separately** with:

```
Cache-Control: no-cache, no-store, must-revalidate
```

This ensures users always receive the latest HTML entry point — and therefore load the
correct versioned asset references — immediately after a deploy, with no manual cache
clearing required.

### Fix: Idempotent script execution

The setup script is safe to re-run at any time:
- It checks whether the S3 project folder and SSM parameter already exist **before** attempting to create them.
- Re-running never overwrites or duplicates existing resources.

### Fix: Bash strict mode

The script runs with `set -euo pipefail`:

| Flag | Effect |
|---|---|
| `-e` | Exit immediately on any command error |
| `-u` | Treat references to unset variables as errors |
| `-o pipefail` | Propagate errors through piped commands |

This prevents the script from silently continuing after a failed AWS CLI call.
