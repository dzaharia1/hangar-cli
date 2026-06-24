# Hangar CLI (`hangar-cli`)

A command-line interface and terminal user interface (TUI) to provision, deploy, monitor, and decommission a fleet of **Firebase-hosted monorepo web applications** with **Cloudflare DNS integration** and automated **GitHub Actions CI/CD workflows**.

Hangar CLI serves as the backbone runner for the **Hangar macOS application**, which shells out to these scripts. Both read and write the same git-synchronized `apps-registry.json` and `.settings` configuration, ensuring they stay perfectly in sync.

---

## Key Features

- 🏗️ **Unified Scaffolding:** Generates a clean, modular monorepo containing a Vite + React 19 + styled-components frontend, and an Express 5 backend running on Firebase Cloud Functions (Node 24, ESM).
- ☁️ **GCP/Firebase Auto-Provisioning:** Programmatically creates Firebase projects, links Google Cloud Billing, enables required APIs, registers custom domains, and sets up a defensive $10 monthly billing budget.
- 🌐 **Cloudflare DNS Automation:** Automatically registers DNS CNAME records mapping your subdomains/custom domains to Firebase Hosting endpoints.
- 🤖 **GitHub Integration & CI/CD:** Auto-creates private repositories on GitHub, sets up GitHub secrets with deployment service account keys, and configures GitHub Actions workflow files to trigger auto-deploys on `git push`.
- 🔄 **Git-Backed Shared Registry:** Manages a centralized inventory (`apps-registry.json`) synchronized automatically through its own private GitHub repository, facilitating multi-machine setups.
- 💻 **TUI & CLI Interactivity:** Run it as an interactive, arrow-key-driven terminal interface, or run scripts directly with CLI subcommands.

---

## Prerequisites

Ensure the following tools are installed and authenticated in your shell environment:

1. **GitHub CLI (`gh`)** — Used to manage repositories, secrets, and register the central registry.
   ```bash
   gh auth login
   ```
2. **Google Cloud SDK (`gcloud`)** — Used to manage projects, billing accounts, and enable APIs.
   ```bash
   gcloud auth login
   ```
3. **Firebase CLI (`firebase`)** — Used to create projects and manage hosting targets (also runs via `npx firebase-tools`).
   ```bash
   firebase login
   ```
4. **JSON Processor (`jq`)** — Used to query and modify project records.
5. **Billing Account** — A Google Cloud billing account linked to your account (needed to upgrade apps to the Firebase Blaze plan).
6. **Cloudflare Account** — Cloudflare zone permissions with Zone.DNS **Edit** credentials for automatic DNS updates.

---

## Quick Start & Setup

Clone the repository and run the host manager script. On the very first run (when no local `.settings` file exists), an interactive setup wizard will run to walk you through configuration, authenticate tools, and bootstrap your centralized registry.

```bash
./host-manager.sh
```

### The Setup Stepper Wizard
1. **Projects Directory:** The absolute local path where project directories are created (defaults to `~/Projects`).
2. **Billing Account ID:** Your Google Cloud billing account ID used to link Firebase projects to the Blaze plan.
3. **Cloudflare Domains & Zone Mappings:** One or more Apex domain mappings with their Cloudflare Zone IDs. New apps automatically receive subdomains across all zones.
4. **Cloudflare API Token:** API token with `Zone.DNS` Edit permissions.

The wizard writes the configurations directly to the `.settings` file.

### Shell Alias (Recommended)
Add this alias to your shell configuration (`~/.zshrc` or `~/.bashrc`) to run Hangar CLI from anywhere:

```bash
alias hangar-cli="/absolute/path/to/hangar-cli/host-manager.sh"
```

---

## Configuration Files

### 1. The `.settings` File
This is a git-ignored file containing key environment mappings. You can create it using the setup stepper or by copying `.settings.example` and filling in the values:

| Configuration Key | Description | Example |
| :--- | :--- | :--- |
| `LOCAL_PROJECTS_DIR` | The absolute path where applications are created | `"$HOME/Projects"` |
| `BILLING_ACCOUNT_ID` | GCP/Firebase Billing Account ID | `012345-6789AB-CDEF01` |
| `CLOUDFLARE_ZONES` | Bash array of `domain:zone_id` strings | `("domain.com:zoneid123")` |
| `CLOUDFLARE_API_TOKEN`| Cloudflare API token with Zone.DNS Edit permissions | `your-cloudflare-token` |

### 2. The Apps Registry
`apps-registry/apps-registry.json` acts as the source of truth for the entire application fleet. The registry is backed by a private GitHub repository (`<github-user>/apps-registry`). 

Hangar CLI clones the repository automatically on startup, runs `git pull` before performing operations, and commits/pushes updates when apps are created or archived.

Example registry entry:
```json
{
  "id": "my-app",
  "name": "My App",
  "domain": "my-app.domain1.com, my-app.domain2.com",
  "domains": ["my-app.domain1.com", "my-app.domain2.com"],
  "local_root": "/Users/user/Projects/My App",
  "firebase_project_id": "my-app-84729",
  "github_repo": "github.com/github-user/my-app",
  "status": "active",
  "created_at": "Wed Jun 24 18:00:00 EDT 2026"
}
```

---

## CLI & Subcommands

Run `./host-manager.sh [command] [options]`. For subcommand help, append `-h` or `--help` (e.g. `./host-manager.sh create-app --help`).

### Commands Table

| Subcommand | Flag Arguments | Description |
| :--- | :--- | :--- |
| **`create-app`** | `-n NAME` (Req), `-id ID`, `-urldomain DOM` | Scaffold, provision resources, and deploy a new app monorepo. |
| **`remove-app`** | `-id ID` (Req) | Decommission, delete GCP project, and remove Cloudflare DNS records. |
| **`restore-app`**| `-id ID` (Req) | Rebuild and deploy a decommissioned app using its GitHub source history. |
| **`list-apps`**  | `--status active\|removed\|all`, `--json` | Lists registered applications in standard text or JSON format. |

---

## Interactive TUI Mode

Running `./host-manager.sh` without arguments launches an interactive Terminal User Interface:
- **Arrow Keys (Up/Down):** Navigate menus and lists.
- **Enter:** Select an option, enter a menu, or view detailed metadata of an application.
- **`Ctrl+R`:** Toggle between **Active Applications** and **Archived Applications** indexes.
- **`D` (in Active details):** Trigger the decommissioning process for the selected app.
- **`R` (in Archived details):** Trigger the redeployment / restoration process for the selected app.
- **`Esc` / `q`:** Go back to the previous screen or exit the tool.

---

## Scaffolded Monorepo Anatomy

All newly created applications follow a unified structure that bundles frontend and backend configurations into a single monorepo:

```
<app-id>/
├── frontend/                     # React Single Page App
│   ├── public/                   # Static assets (manifest.json, robots.txt)
│   ├── src/                      # Source code (React 19 + styled-components)
│   ├── package.json              # Vite build setup
│   └── vite.config.js            # Frontend config with local API proxy mapping
├── backend/                      # Firebase Cloud Functions runtime environment
│   ├── functions/                # Express 5 App
│   │   ├── index.js              # onRequest API endpoint definition
│   │   └── package.json          # Server dependencies (Express, Firebase-Admin, CORS)
│   └── package.json              # Parent script runner to launch functions emulator
├── .firebaserc                   # Stores active Firebase Project mapping
├── firebase.json                 # Maps hosting path, redirects `/api/**` -> Functions API
└── .github/                      # GitHub Actions automated workflow configurations
    └── workflows/
        └── deploy.yml            # CI/CD deployment file triggered on pushes to main
```

- **Frontend:** Powered by React 19 and styled-components v6. Building output goes to `frontend/dist/` which is served by Firebase Hosting.
- **Backend:** Express 5 app exported as `api` function wrapper (`firebase-functions/v2/https`).
- **Rewrites:** Firebase Hosting redirects all `/api/**` requests directly to the functions runtime, while fallback routes serve `index.html`.

---

## Local Development & Emulators

Hangar CLI scaffolds configuration designed to run and hot-reload local services simultaneously using the Firebase Local Emulator Suite.

1. **Start the Express API Emulator:**
   Navigate to the `backend/` folder and run the function emulator:
   ```bash
   cd backend
   npm run dev
   ```
   This runs functions locally on `http://127.0.0.1:5001`.

2. **Start the Frontend Dev Server:**
   In another terminal tab, navigate to the `frontend/` folder and run the Vite dev server:
   ```bash
   cd frontend
   npm run dev
   ```
   This launches the development UI at `http://localhost:5173`. Vite is configured with a development proxy wrapper to forward `/api/**` requests directly to the Functions Emulator on port 5001.

---

## Detailed Operations Lifecycle

### Setup & Provisioning (`setup-new-app.sh`)
1. Generates local directory structure under `LOCAL_PROJECTS_DIR` and installs node packages.
2. Registers a new Google Cloud / Firebase project and links it to the configured `BILLING_ACCOUNT_ID` to activate the Blaze plan.
3. Automatically sets a $10 monthly budget cap in Google Cloud billing budgets to prevent runaway costs.
4. Registers custom domains via Firebase Hosting APIs and creates CNAME DNS records pointing to `<project>.web.app` in Cloudflare.
5. Provisions a GCP service account (`firebase-deployer`), grants deployment IAM permissions, generates a credential key, and creates a private GitHub repository.
6. Saves the key as the `FIREBASE_SERVICE_ACCOUNT_KEY` secret in the GitHub repository.
7. Commits scaffolded code and pushes to `main` to trigger the initial GitHub Action deploy.
8. Writes metadata back to the shared `apps-registry.json` database.

### Decommissioning (`remove-app.sh`)
1. Deletes the local application folder from your disk.
2. Programmatically deletes the Google Cloud / Firebase project (along with all its functions and hosted builds).
3. Deletes DNS CNAME records associated with the app from Cloudflare zones.
4. Updates the app status in `apps-registry.json` to `"removed"` and syncs it with GitHub.
5. **Important:** The GitHub repository is **not** deleted, preserving source control history.

### Restoration (`restore-app` in `host-manager.sh`)
1. Clones the application repository back from GitHub into `LOCAL_PROJECTS_DIR`.
2. Creates a fresh Firebase project (with a new unique random ID suffix) and links it to billing.
3. Configures API services and recreates the GCP billing budget limits.
4. Regenerates the `firebase-deployer` service account key, sets it on the GitHub repository secret, and updates the local `.firebaserc`.
5. Re-registers custom domains on Firebase and rebuilds CNAME DNS configurations in Cloudflare.
6. Commits configuration updates and pushes to trigger a deployment.
7. Updates the entry status back to `"active"` in the registry and syncs it with GitHub.
