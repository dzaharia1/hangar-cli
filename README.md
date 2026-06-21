# Server Setup Scripts

Bash scripts that provision and manage a fleet of **Firebase-hosted web apps**. Each app is created as a single monorepo — a Vite/React frontend on Firebase Hosting plus an Express backend on Firebase Cloud Functions — wired to a private GitHub repo that auto-deploys on push. A synchronized `apps-registry` tracks every app's metadata and lifecycle status.

These scripts can be driven directly from the terminal (interactive TUI or CLI subcommands) or by the **Hangar** macOS app, which shells out to them. Both read and write the same `apps-registry.json` and `.settings`, so the two stay in sync.

> ℹ️ Earlier revisions of this repo deployed Vite/Express apps to a remote Apache/pm2 server. That model is gone — everything here now targets Firebase. The git history and the `fcc-lol/server-setup-scripts` upstream still reflect the old approach.

---

## Prerequisites

Installed **and authenticated** in your shell:

- [`gh`](https://cli.github.com/) — GitHub CLI (`gh auth login`)
- [`gcloud`](https://cloud.google.com/sdk) — Google Cloud SDK (`gcloud auth login`)
- [`firebase`](https://firebase.google.com/docs/cli) — Firebase CLI (the scripts also call `npx firebase-tools`)
- [`jq`](https://stedolan.github.io/jq/) — JSON processor
- A Firebase / Google Cloud account with a **billing account** (apps are linked to the Blaze plan)
- Your domains managed on **Cloudflare** (DNS records are created automatically)

---

## Setup

Run the host manager. On first run — when no `.settings` file exists — an interactive stepper walks you through configuration, authenticates `gh`, and bootstraps the `apps-registry`:

```bash
./host-manager.sh
```

The stepper prompts for:
1. **Local projects directory** — where app monorepos are scaffolded (default `~/Projects`)
2. **Billing Account ID** — GCP/Firebase billing account used to enable Blaze
3. **Cloudflare domains & Zone IDs** — one or more `domain:zone_id` mappings (at least one required)
4. **Cloudflare API token** — needs Zone.DNS **Edit** permission

It writes these to `.settings` (see [The `.settings` file](#the-settings-file)).

### Shell alias (optional)

```bash
alias host-manager="/absolute/path/to/server-setup-scripts/my-setup-scripts/host-manager.sh"
source ~/.zshrc   # or ~/.bashrc
```

---

## The `.settings` file

A plain **bash** file `source`d by every script. It is git-ignored — copy [`.settings.example`](./.settings.example) to `.settings` and fill in real values (or let the first-run stepper generate it).

| Key | Description |
|---|---|
| `LOCAL_PROJECTS_DIR` | Directory where app monorepos are scaffolded (e.g. `"$HOME/Projects"`) |
| `BILLING_ACCOUNT_ID` | GCP/Firebase billing account ID linked to new projects |
| `CLOUDFLARE_ZONES` | Bash array of `"domain:zone_id"` strings; new apps get a subdomain in **every** listed zone |
| `CLOUDFLARE_API_TOKEN` | Cloudflare token with Edit DNS permission |

---

## The apps registry

`apps-registry/apps-registry.json` is the **source of truth** for the fleet — an array of entries:

```json
{
  "id": "martian-os",
  "name": "Martian OS",
  "domain": "martian-os.adanmade.app, martian-os.danzaharia.com",
  "domains": ["martian-os.adanmade.app", "martian-os.danzaharia.com"],
  "local_root": "/Users/dan/Projects/martian-os",
  "firebase_project_id": "martian-os-f4b6d",
  "github_repo": "github.com/dzaharia1/martian-os",
  "status": "active",
  "created_at": "Wed Jun 17 16:14:14 EDT 2026"
}
```

`status` is `active` or `removed`. The registry is itself a **private GitHub repo** (`<github-user>/apps-registry`): `host-manager.sh` clones or creates it on first run and `git pull`s it on every run, and the create/remove/restore flows commit and push changes. The local `apps-registry/` directory is git-ignored from this repo.

---

## Commands

`host-manager.sh` is the entry point. With **no arguments** it launches an interactive arrow-key TUI (create apps, browse active/archived apps with `Ctrl+R` to toggle, delete or restore). With a **subcommand** it runs non-interactively:

| Command | Purpose |
|---|---|
| `create-app -n NAME [-id ID] [-urldomain DOM]` | Scaffold, provision, and deploy a new app (delegates to `setup-new-app.sh`) |
| `remove-app -id ID` | Archive an active app (delegates to `remove-app.sh`) |
| `restore-app -id ID` | Redeploy an archived app from its GitHub repo |
| `list-apps [--status active\|removed\|all] [--json]` | List registered apps |

Add `-h` / `--help` to the script or any subcommand for usage details.

---

## Lifecycle scripts

### `setup-new-app.sh` — provision a new app

```bash
./setup-new-app.sh -n "App Name" [-id app-id] [-urldomain dom] [-fid firebase-project-id]
```

| Flag | Meaning |
|---|---|
| `-n`, `--name` | App name (Title Case) |
| `-id`, `--id` | App ID (defaults to the lowercase-hyphenated name) |
| `-urldomain`, `--domain` | Custom domain(s). A value containing a `.` is used verbatim (comma-separated allowed); a bare word is used as the **subdomain prefix** across all Cloudflare zones |
| `-fid`, `--firebase-id` | Firebase project ID (defaults to `<app-id>-<random5>`) |

Steps:
1. Scaffold the monorepo under `$LOCAL_PROJECTS_DIR/<id>` (frontend, backend, root configs) and `npm install` both packages
2. Create the Firebase project, link billing, enable required GCP APIs (Firebase, Hosting, Cloud Functions, Cloud Run, Artifact Registry, Cloud Build, Eventarc)
3. Register custom domains in Firebase Hosting and create Cloudflare **CNAME** records pointing at `<project>.web.app`
4. Create a `firebase-deployer` service account, bind IAM roles, and generate a key
5. `git init`, create a **private** GitHub repo, store the key as the `FIREBASE_SERVICE_ACCOUNT_KEY` secret, and write `.github/workflows/deploy.yml`
6. Append the entry to `apps-registry.json` and push

Default domains are `<id>.<each configured zone domain>` (e.g. `<id>.adanmade.app` and `<id>.danzaharia.com`).

### `remove-app.sh` — archive an app

```bash
./remove-app.sh --app-id <id>
```

1. Delete the local project folder
2. Delete the GCP/Firebase project
3. Delete the Cloudflare CNAME records
4. Flip the registry entry's `status` to `removed` and push

The **GitHub repo is preserved** so the app can be restored later.

### `restore-app` (via `host-manager.sh`) — redeploy an archived app

```bash
./host-manager.sh restore-app -id <id>
```

Clones the monorepo back from GitHub, recreates the Firebase project (new `<id>-<random5>` ID) with billing + APIs, regenerates the deployer service account and GitHub secret, re-registers Firebase custom domains and Cloudflare CNAMEs, rewrites `.firebaserc` / `deploy.yml` with the new project ID, flips the registry entry back to `active`, and pushes to trigger a fresh deploy. Fails if a folder already exists at the local path.

---

## What a scaffolded app looks like

A single monorepo deployed entirely to Firebase:

```
<app-id>/
  frontend/            # Vite + React 19 + styled-components → built to frontend/dist/
    src/
    public/
  backend/
    functions/         # Firebase Cloud Functions (Node 24, ESM): Express app exported as `api`
  firebase.json        # Hosting serves frontend/dist; rewrites /api/** → the `api` function
  .firebaserc          # default project = the Firebase project ID
  .github/workflows/deploy.yml   # push to main → build frontend + deploy hosting & functions
```

- **Frontend:** Vite 5, React 19, styled-components 6. `npm run build` emits `frontend/dist/`, served by Firebase Hosting.
- **Backend:** an Express 5 app wrapped by `onRequest` and exported as the `api` function. Hosting rewrites `/api/**` to it; all other paths fall back to `index.html`.
- **CI/CD:** pushing to `main` runs the GitHub Actions workflow, which builds the frontend and runs `firebase deploy` using the `FIREBASE_SERVICE_ACCOUNT_KEY` secret.

### Local Development & Testing

To run the application locally with hot-reloading:

1. **Start the Backend Cloud Functions Emulator**:
   In one terminal tab, navigate to the `backend/` directory and run:
   ```bash
   cd backend
   npm run dev
   ```
   This starts the Firebase local emulator suite focusing only on the functions service.

2. **Start the Frontend Vite Dev Server**:
   In another terminal tab, navigate to the `frontend/` directory and run:
   ```bash
   cd frontend
   npm run dev
   ```
   This runs the Vite dev server on `http://localhost:5173`. Since the scaffolded `vite.config.js` includes a proxy mapping, any requests to `/api/**` are automatically forwarded to the local Functions emulator.

---

Prettier config applied to scaffolded apps:

```json
{ "bracketSameLine": true, "trailingComma": "all", "singleQuote": true }
```

## Conventions

- Every script accepts CLI flags and falls back to interactive `read` prompts.
- App IDs are the lowercase-hyphenated form of the Title-Case name.
- Steps print `SUCCESS` / `FAILED` / `WARNING` and generally **continue on failure** (non-fatal pattern), so a partial failure doesn't abort the whole run.
- The registry is authoritative and kept in sync through its own private GitHub repo.
