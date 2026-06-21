#!/bin/bash

# Set up formatting
BOLD='\033[1m'
BOLD_RED='\033[1;31m'
BOLD_GREEN='\033[1;32m'
END_COLOR='\033[0m'

# Parse CLI arguments
APP_NAME=""
APP_ID=""
URL_DOMAIN=""
FIREBASE_PROJECT_ID=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -n|--name) APP_NAME="$2"; shift ;;
        -id|--id) APP_ID="$2"; shift ;;
        -urldomain|--url-domain|--domain) URL_DOMAIN="$2"; shift ;;
        -fid|--firebase-id) FIREBASE_PROJECT_ID="$2"; shift ;;
        -h|--help)
            echo "Usage: ./setup-new-app.sh [options]"
            echo "Options:"
            echo "  -n, --name NAME          App Name (Title Case)"
            echo "  -id, --id ID             App ID (alphanumeric with hyphens)"
            echo "  -urldomain, --domain DOM  Custom domain(s) (or prefix for default domains)"
            echo "  -fid, --firebase-id ID    Firebase Project ID (default: <app-id>-<random>)"
            echo "  -h, --help               Show this help message"
            exit 0
            ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Source settings
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS_FILE="$SCRIPT_DIR/.settings"
if [ -f "$SETTINGS_FILE" ]; then
    source "$SETTINGS_FILE"
else
    echo -e "${BOLD_RED}FAILED${END_COLOR} Cannot find settings at $SETTINGS_FILE"
    echo "Copy .settings.example to .settings and fill in values."
    exit 1
fi

if [ -z "$LOCAL_PROJECTS_DIR" ] || [ -z "$BILLING_ACCOUNT_ID" ] || [ ${#CLOUDFLARE_ZONES[@]} -eq 0 ]; then
    echo -e "${BOLD_RED}FAILED${END_COLOR} LOCAL_PROJECTS_DIR, BILLING_ACCOUNT_ID, or CLOUDFLARE_ZONES not set properly in .settings"
    exit 1
fi

# Ensure local projects dir is expanded
eval LOCAL_PROJECTS_DIR="$LOCAL_PROJECTS_DIR"
mkdir -p "$LOCAL_PROJECTS_DIR"

# Validate tools
for cmd in gh gcloud jq firebase; do
    if ! command -v $cmd &>/dev/null; then
        echo -e "${BOLD_RED}FAILED${END_COLOR} $cmd CLI not found. Please install it."
        exit 1
    fi
done

# Check CLI authentications
GITHUB_USER=$(gh api user --jq .login 2>/dev/null)
if [ -z "$GITHUB_USER" ]; then
    echo -e "${BOLD_RED}FAILED${END_COLOR} GitHub CLI (gh) not authenticated."
    exit 1
fi

GCLOUD_ACCOUNT=$(gcloud config get-value account 2>/dev/null)
if [ -z "$GCLOUD_ACCOUNT" ]; then
    echo -e "${BOLD_RED}FAILED${END_COLOR} Google Cloud CLI (gcloud) not authenticated."
    exit 1
fi

generate_app_id() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-'
}

# Prompts
if [ -z "$APP_NAME" ]; then
    read -p "App Name (Title Case): " APP_NAME
fi

if [ -z "$APP_ID" ]; then
    DEFAULT_APP_ID=$(generate_app_id "$APP_NAME")
    read -p "App ID (Default: ${DEFAULT_APP_ID}): " APP_ID
    APP_ID=${APP_ID:-$DEFAULT_APP_ID}
fi

clean_app_id() {
    echo "$1" | tr -d '\r'
}
APP_ID=$(clean_app_id "$APP_ID")

# Firebase Project ID (guaranteed globally unique with random suffix)
# Honors a caller-provided --firebase-id; otherwise generates one.
if [ -z "$FIREBASE_PROJECT_ID" ]; then
    RANDOM_NUM=$(jot -r 1 10000 99999 2>/dev/null || shuf -i 10000-99999 -n 1 2>/dev/null || echo $((10000 + RANDOM % 90000)))
    FIREBASE_PROJECT_ID="$APP_ID-$RANDOM_NUM"
fi
FIREBASE_PROJECT_ID=$(echo "$FIREBASE_PROJECT_ID" | tr -d '\r')

# Check if app already exists in registry
REGISTRY_FILE="$SCRIPT_DIR/apps-registry/apps-registry.json"
if [ -f "$REGISTRY_FILE" ]; then
    EXISTS=$(jq -r ".[] | select(.id == \"$APP_ID\" and .status == \"active\") | .id" "$REGISTRY_FILE")
    if [ -n "$EXISTS" ]; then
        echo -e "${BOLD_RED}FAILED${END_COLOR} An active app with ID '$APP_ID' already exists in the registry."
        exit 1
    fi
fi

# Domain mapping (uses clean local app ID or custom domain input)
if [ -n "$URL_DOMAIN" ]; then
    if [[ "$URL_DOMAIN" == *.* ]]; then
        DOMAIN_NAME="$URL_DOMAIN"
    else
        DOMAIN_NAME=""
        for mapping in "${CLOUDFLARE_ZONES[@]}"; do
            base_domain="${mapping%%:*}"
            if [ -n "$DOMAIN_NAME" ]; then
                DOMAIN_NAME="$DOMAIN_NAME,"
            fi
            DOMAIN_NAME="$DOMAIN_NAME$URL_DOMAIN.$base_domain"
        done
    fi
else
    DOMAIN_NAME=""
    for mapping in "${CLOUDFLARE_ZONES[@]}"; do
        base_domain="${mapping%%:*}"
        if [ -n "$DOMAIN_NAME" ]; then
            DOMAIN_NAME="$DOMAIN_NAME,"
        fi
        DOMAIN_NAME="$DOMAIN_NAME$APP_ID.$base_domain"
    done
fi

# Split comma-separated DOMAIN_NAME into an array for easier looping later
IFS=',' read -r -a DOMAINS_ARRAY <<< "$(echo "$DOMAIN_NAME" | tr -d ' ')"

echo -e "\nSummary:"
echo "App Name:            $APP_NAME"
echo "App ID:              $APP_ID"
echo "Firebase Project ID: $FIREBASE_PROJECT_ID"
echo "Domains:             "
for domain in "${DOMAINS_ARRAY[@]}"; do
    echo "                     https://$domain"
done
echo "Local Root:          $LOCAL_PROJECTS_DIR/$APP_ID"
echo "GitHub Repo:         github.com/$GITHUB_USER/$APP_ID"
echo " "

# Create Folder Structure
ROOT_DIR="$LOCAL_PROJECTS_DIR/$APP_ID"
mkdir -p "$ROOT_DIR/frontend/src" "$ROOT_DIR/frontend/public" "$ROOT_DIR/backend/functions" "$ROOT_DIR/backend/public"

# --- SCAFFOLD FRONTEND ---
echo "Scaffolding frontend..."
# prettierrc
cat <<EOF > "$ROOT_DIR/frontend/.prettierrc"
{
  "bracketSameLine": true,
  "trailingComma": "all",
  "singleQuote": true
}
EOF

# App.jsx
cat <<EOF > "$ROOT_DIR/frontend/src/App.jsx"
import React from 'react';
import styled from 'styled-components';

const Page = styled.div\`
  display: flex;
  justify-content: center;
  align-items: center;
  height: 100vh;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: linear-gradient(135deg, #1e1b4b 0%, #0f172a 100%);
  color: #f8fafc;
\`;

const Card = styled.div\`
  background: rgba(255, 255, 255, 0.05);
  backdrop-filter: blur(12px);
  border: 1px solid rgba(255, 255, 255, 0.1);
  padding: 3rem;
  border-radius: 24px;
  text-align: center;
  box-shadow: 0 20px 40px rgba(0, 0, 0, 0.4);
\`;

const Title = styled.h1\`
  font-size: 3rem;
  margin-bottom: 0.5rem;
  background: linear-gradient(90deg, #60a5fa, #a78bfa);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
\`;

const Status = styled.p\`
  color: #94a3b8;
  font-size: 1.2rem;
\`;

const ApiButton = styled.button\`
  margin-top: 1.5rem;
  padding: 0.75rem 1.5rem;
  border: none;
  background: linear-gradient(90deg, #3b82f6, #8b5cf6);
  color: white;
  font-weight: 600;
  border-radius: 8px;
  cursor: pointer;
  transition: opacity 0.2s;
  &:hover {
    opacity: 0.9;
  }
\`;

function App() {
  const testApi = async () => {
    try {
      const res = await fetch('/api/info');
      const data = await res.json();
      alert('API Response: ' + JSON.stringify(data));
    } catch (err) {
      alert('API Error: ' + err.message);
    }
  };

  return (
    <Page>
      <Card>
        <Title>${APP_NAME}</Title>
        <Status>Frontend + Backend deployed to Firebase</Status>
        <ApiButton onClick={testApi}>Test API Endpoint</ApiButton>
      </Card>
    </Page>
  );
}

export default App;
EOF

# index.css
cat <<EOF > "$ROOT_DIR/frontend/src/index.css"
body { margin: 0; padding: 0; }
EOF

# main.jsx
cat <<EOF > "$ROOT_DIR/frontend/src/main.jsx"
import React from 'react';
import ReactDOM from 'react-dom/client';
import './index.css';
import App from './App.jsx';

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
EOF

# index.html
cat <<EOF > "$ROOT_DIR/frontend/index.html"
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>$APP_NAME</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
EOF

# manifest & robots
echo '{"short_name": "'"$APP_NAME"'", "name": "'"$APP_NAME"'", "display": "standalone"}' > "$ROOT_DIR/frontend/public/manifest.json"
echo -e "User-agent: *\nDisallow:" > "$ROOT_DIR/frontend/public/robots.txt"

# package.json
cat <<EOF > "$ROOT_DIR/frontend/package.json"
{
  "name": "$APP_ID-frontend",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "dependencies": {
    "react": "^19.0.0",
    "react-dom": "^19.0.0",
    "styled-components": "^6.1.14"
  },
  "devDependencies": {
    "@types/react": "^19.0.8",
    "@types/react-dom": "^19.0.3",
    "@vitejs/plugin-react": "^4.3.4",
    "vite": "^5.4.14"
  }
}
EOF

# vite.config.js
cat <<EOF > "$ROOT_DIR/frontend/vite.config.js"
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  build: { outDir: 'dist' },
  server: {
    proxy: {
      '/api': {
        target: 'http://127.0.0.1:5001/$FIREBASE_PROJECT_ID/us-central1/api',
        changeOrigin: true
      }
    }
  }
})
EOF


# --- SCAFFOLD BACKEND ---
echo "Scaffolding backend..."

# package.json
cat <<EOF > "$ROOT_DIR/backend/package.json"
{
  "name": "$APP_ID-backend",
  "private": true,
  "version": "1.0.0",
  "scripts": {
    "dev": "npx -y firebase-tools@latest emulators:start --only functions"
  }
}
EOF

# functions/package.json
cat <<EOF > "$ROOT_DIR/backend/functions/package.json"
{
  "name": "$APP_ID-functions",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "main": "index.js",
  "engines": {
    "node": "24"
  },
  "dependencies": {
    "firebase-admin": "^13.0.0",
    "firebase-functions": "^7.2.5",
    "express": "^5.0.1",
    "cors": "^2.8.5"
  }
}
EOF

# functions/index.js
cat <<EOF > "$ROOT_DIR/backend/functions/index.js"
import { onRequest } from "firebase-functions/v2/https";
import express from "express";
import cors from "cors";

const app = express();
app.use(cors({ origin: true }));

app.get("/api/info", (req, res) => {
  res.json({
    service: "$APP_NAME API",
    status: "online",
    timestamp: new Date().toISOString()
  });
});

export const api = onRequest({ cors: true, minInstances: 0 }, app);
EOF


# --- SCAFFOLD MONOREPO ROOT CONFIGS ---
echo "Scaffolding root config files..."

# firebase.json
cat <<EOF > "$ROOT_DIR/firebase.json"
{
  "functions": {
    "source": "backend/functions",
    "codebase": "default",
    "runtime": "nodejs24"
  },
  "hosting": {
    "public": "frontend/dist",
    "ignore": [
      "firebase.json",
      "**/.*",
      "**/node_modules/**"
    ],
    "rewrites": [
      {
        "source": "/api/**",
        "function": "api"
      },
      {
        "source": "**",
        "destination": "/index.html"
      }
    ],
    "cleanUrls": true,
    "trailingSlash": false
  }
}
EOF

# .firebaserc
cat <<EOF > "$ROOT_DIR/.firebaserc"
{
  "projects": {
    "default": "$FIREBASE_PROJECT_ID"
  }
}
EOF


# Install dependencies locally
echo "Installing Node modules locally..."
(cd "$ROOT_DIR/frontend" && npm install)
(cd "$ROOT_DIR/backend/functions" && npm install)

# --- PROVISION FIREBASE ---
echo "Creating Firebase project $FIREBASE_PROJECT_ID..."
if npx firebase-tools projects:create "$FIREBASE_PROJECT_ID" --display-name "$APP_NAME"; then
    echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} Created Firebase Project"
else
    echo -e "${BOLD_RED}FAILED${END_COLOR} Cannot create Firebase project. It might already exist."
    exit 1
fi

echo "Linking Billing Account $BILLING_ACCOUNT_ID..."
gcloud billing projects link "$FIREBASE_PROJECT_ID" --billing-account="$BILLING_ACCOUNT_ID" >/dev/null

echo "Enabling required Google Cloud APIs (Firebase, Hosting, Cloud Functions, Cloud Run, Artifact Registry, Cloud Build)..."
gcloud services enable \
    firebase.googleapis.com \
    firebasehosting.googleapis.com \
    cloudfunctions.googleapis.com \
    run.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    cloudbilling.googleapis.com \
    eventarc.googleapis.com \
    --project="$FIREBASE_PROJECT_ID" >/dev/null 2>&1

# Wait for API activation to propagate globally
echo "Waiting for API propagation..."
sleep 10

# Register custom domains
echo "Registering custom domains in Firebase Hosting..."
ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null)
for domain in "${DOMAINS_ARRAY[@]}"; do
    if [ -n "$ACCESS_TOKEN" ]; then
        echo "Registering $domain..."
        response=$(curl -s -w "\n%{http_code}" -X POST "https://firebasehosting.googleapis.com/v1beta1/projects/$FIREBASE_PROJECT_ID/sites/$FIREBASE_PROJECT_ID/customDomains?customDomainId=$domain" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "X-Goog-User-Project: $FIREBASE_PROJECT_ID" \
            -H "Content-Type: application/json" \
            -d "{}")
        code=$(echo "$response" | tail -n 1)
        body=$(echo "$response" | head -n -1)
        if [ "$code" -ne 200 ] && [ "$code" -ne 201 ]; then
            echo -e "${BOLD_RED}WARNING:${END_COLOR} Failed to register $domain (HTTP $code)"
            echo "Details: $body"
        else
            echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} Registered $domain"
        fi
    fi

    # Cloudflare CNAME record setup
    if [ -n "$CLOUDFLARE_API_TOKEN" ]; then
        ZONE_ID=""
        for mapping in "${CLOUDFLARE_ZONES[@]}"; do
            base_domain="${mapping%%:*}"
            if [[ "$domain" == *"$base_domain" ]]; then
                ZONE_ID="${mapping#*:}"
                break
            fi
        done

        if [ -n "$ZONE_ID" ]; then
            echo "Creating Cloudflare CNAME record pointing $domain to $FIREBASE_PROJECT_ID.web.app..."
            cf_response=$(curl -s -w "\n%{http_code}" -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
                -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
                -H "Content-Type: application/json" \
                --data "{\"type\":\"CNAME\",\"name\":\"$domain\",\"content\":\"$FIREBASE_PROJECT_ID.web.app\",\"ttl\":1,\"proxied\":false}")
            cf_code=$(echo "$cf_response" | tail -n 1)
            cf_body=$(echo "$cf_response" | head -n -1)
            if [ "$cf_code" -ne 200 ] && [ "$cf_code" -ne 201 ]; then
                echo -e "${BOLD_RED}WARNING:${END_COLOR} Failed to create Cloudflare DNS record for $domain (HTTP $cf_code)"
                echo "Details: $cf_body"
            else
                echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} Created Cloudflare DNS record (DNS-only) for $domain"
            fi
        else
            echo "Cloudflare automatic DNS setup skipped for $domain (unrecognized zone or zone ID not set)"
        fi
    fi
done

# --- CONFIGURE SERVICE ACCOUNTS ---
echo "Creating Google Cloud deployer Service Account..."
gcloud iam service-accounts create firebase-deployer \
    --description="Deployment Service Account" \
    --display-name="Firebase Deployer" \
    --project="$FIREBASE_PROJECT_ID" >/dev/null 2>&1

echo "Configuring IAM policy bindings for Deployer Service Account..."
for i in {1..5}; do
    if gcloud projects add-iam-policy-binding "$FIREBASE_PROJECT_ID" \
        --member="serviceAccount:firebase-deployer@$FIREBASE_PROJECT_ID.iam.gserviceaccount.com" \
        --role="roles/editor" >/dev/null 2>&1 && \
       gcloud projects add-iam-policy-binding "$FIREBASE_PROJECT_ID" \
        --member="serviceAccount:firebase-deployer@$FIREBASE_PROJECT_ID.iam.gserviceaccount.com" \
        --role="roles/iam.serviceAccountUser" >/dev/null 2>&1 && \
       gcloud projects add-iam-policy-binding "$FIREBASE_PROJECT_ID" \
        --member="serviceAccount:firebase-deployer@$FIREBASE_PROJECT_ID.iam.gserviceaccount.com" \
        --role="roles/cloudfunctions.admin" >/dev/null 2>&1 && \
       gcloud projects add-iam-policy-binding "$FIREBASE_PROJECT_ID" \
        --member="serviceAccount:firebase-deployer@$FIREBASE_PROJECT_ID.iam.gserviceaccount.com" \
        --role="roles/run.admin" >/dev/null 2>&1; then
        echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} Configured service account permissions"
        break
    fi
    echo "Waiting for service account propagation..."
    sleep 2
done

echo "Generating service account keys..."
for i in {1..5}; do
    if gcloud iam service-accounts keys create "$ROOT_DIR/firebase-key.json" \
        --iam-account="firebase-deployer@$FIREBASE_PROJECT_ID.iam.gserviceaccount.com" >/dev/null 2>&1; then
        echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} Generated service account keys"
        break
    fi
    echo "Waiting for keys creation..."
    sleep 2
done

# --- GIT & GITHUB ---
echo "Setting up unified Git Monorepo..."
cd "$ROOT_DIR"
git init
git checkout -b main

# Create root .gitignore
cat <<EOF > .gitignore
node_modules/
frontend/dist/
frontend/node_modules/
backend/functions/node_modules/
firebase-key.json
.DS_Store
EOF

git add .
git commit -m "Scaffold monorepo structure"

# Create single GitHub Repository
gh repo create "$APP_ID" --private --source=. --remote=origin
gh secret set FIREBASE_SERVICE_ACCOUNT_KEY --repo "$GITHUB_USER/$APP_ID" < "$ROOT_DIR/firebase-key.json"

# Create combined GitHub Actions deploy workflow
mkdir -p .github/workflows
cat <<EOF > .github/workflows/deploy.yml
name: Build and Deploy to Firebase

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 24
          cache: 'npm'
          cache-dependency-path: |
            frontend/package-lock.json
            backend/functions/package-lock.json

      - name: Install Frontend Dependencies
        run: npm ci
        working-directory: frontend

      - name: Build Frontend
        run: npm run build
        working-directory: frontend

      - name: Install Functions Dependencies
        run: npm ci
        working-directory: backend/functions

      - name: Authenticate to Google Cloud
        uses: google-github-actions/auth@v2
        with:
          credentials_json: \${{ secrets.FIREBASE_SERVICE_ACCOUNT_KEY }}

      - name: Deploy to Firebase
        run: npx firebase-tools deploy --project $FIREBASE_PROJECT_ID --force
EOF

git add .github/workflows/deploy.yml
git commit -m "Add monorepo deploy action"
git push -u origin main >/dev/null 2>&1

# Cleanup credentials key
rm -f "$ROOT_DIR/firebase-key.json"

# --- REGISTRY LOGGING ---
echo "Logging metadata to synchronized registry..."
# Build a JSON array of the (cleaned) domains for the richer schema.
DOMAINS_JSON=$(printf '%s\n' "${DOMAINS_ARRAY[@]}" | jq -R . | jq -s .)

NEW_ENTRY=$(jq -n \
  --arg id "$APP_ID" \
  --arg name "$APP_NAME" \
  --arg domain "$DOMAIN_NAME" \
  --argjson domains "$DOMAINS_JSON" \
  --arg local_root "$ROOT_DIR" \
  --arg f_pid "$FIREBASE_PROJECT_ID" \
  --arg gh_repo "github.com/$GITHUB_USER/$APP_ID" \
  --arg date "$(date)" \
  '{id: $id, name: $name, domain: $domain, domains: $domains, local_root: $local_root, firebase_project_id: $f_pid, github_repo: $gh_repo, status: "active", created_at: $date}')

# Load registry, add entry, write back
cd "$SCRIPT_DIR/apps-registry"
if [ ! -f "apps-registry.json" ] || [ ! -s "apps-registry.json" ]; then
    echo "[]" > apps-registry.json
fi
jq ". + [$NEW_ENTRY]" apps-registry.json > apps-registry.tmp.json && mv apps-registry.tmp.json apps-registry.json
git add apps-registry.json
git commit -m "Add active app: $APP_ID"
git push >/dev/null 2>&1

echo -e "\n------------------------------------"
echo -e "--------------- ${BOLD}DONE${END_COLOR} ---------------"
echo -e "------------------------------------ \n"
echo -e "${BOLD}*** $APP_ID is now fully set up! ***${END_COLOR}\n"
echo -e "* Raw Firebase URL:  ${BOLD}https://$FIREBASE_PROJECT_ID.web.app${END_COLOR}"
echo -e "* Custom Domains:    "
for domain in "${DOMAINS_ARRAY[@]}"; do
    echo -e "                     ${BOLD}https://$domain${END_COLOR}"
done
echo -e "* Firebase Project:  ${BOLD}https://console.firebase.google.com/project/$FIREBASE_PROJECT_ID${END_COLOR}"
echo -e "* GitHub Repo:       ${BOLD}https://github.com/$GITHUB_USER/$APP_ID${END_COLOR}"
