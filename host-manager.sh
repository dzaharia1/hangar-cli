#!/bin/bash

# Set up formatting
BOLD='\033[1m'
BOLD_RED='\033[1;31m'
BOLD_GREEN='\033[1;32m'
BOLD_CYAN='\033[1;36m'
END_COLOR='\033[0m'

INTERACTIVE=true

press_enter_to_continue() {
    if [ "$INTERACTIVE" = true ]; then
        read -p "Press Enter to continue..."
    fi
}

# Help handlers (fast exit, no dependencies needed)
show_general_help() {
    echo -e "${BOLD_CYAN}Host Manager CLI${END_COLOR} - Automated App Deployment & Maintenance"
    echo ""
    echo -e "${BOLD}Usage:${END_COLOR}"
    echo "  ./host-manager.sh [command] [options]"
    echo ""
    echo -e "${BOLD}Commands:${END_COLOR}"
    echo "  create-app   Scaffold and deploy a new Vite/React app with custom domains,"
    echo "               GitHub repo, and Firebase Hosting."
    echo "  remove-app   Decommission and remove an active app (local folder, Firebase"
    echo "               project, Cloudflare DNS, and update registry)."
    echo "  restore-app  Redeploy and restore an archived application from GitHub."
    echo "  list-apps    List all registered applications and their metadata."
    echo ""
    echo -e "${BOLD}Help on Commands:${END_COLOR}"
    echo "  ./host-manager.sh [command] --help     Show usage details for a specific command."
    echo ""
    echo -e "${BOLD}Global Options:${END_COLOR}"
    echo "  -h, --help   Show this general help message"
    echo ""
}

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_general_help
    exit 0
fi

if [ "$1" = "create-app" ] && { [ "$2" = "-h" ] || [ "$2" = "--help" ]; }; then
    echo -e "${BOLD}Usage:${END_COLOR}"
    echo "  ./host-manager.sh create-app [options]"
    echo ""
    echo -e "${BOLD}Options:${END_COLOR}"
    echo "  -n, --name NAME             App Name (Title Case) [Required]"
    echo "  -id, --id ID                App ID (lowercase-with-hyphens) [Optional, generated from name]"
    echo "  -urldomain, --domain DOM    Custom domain(s), comma-separated [Optional]"
    echo ""
    echo -e "${BOLD}Examples:${END_COLOR}"
    echo "  ./host-manager.sh create-app -n \"My Premium App\""
    echo "  ./host-manager.sh create-app -n \"Custom Domain App\" -id \"custom-app\" -urldomain \"custom-app.com\""
    exit 0
fi

if [ "$1" = "remove-app" ] && { [ "$2" = "-h" ] || [ "$2" = "--help" ]; }; then
    echo -e "${BOLD}Usage:${END_COLOR}"
    echo "  ./host-manager.sh remove-app [options]"
    echo ""
    echo -e "${BOLD}Options:${END_COLOR}"
    echo "  -id, --id ID                App ID of the application to remove [Required]"
    echo ""
    echo -e "${BOLD}Examples:${END_COLOR}"
    echo "  ./host-manager.sh remove-app -id \"my-app\""
    exit 0
fi

if [ "$1" = "restore-app" ] && { [ "$2" = "-h" ] || [ "$2" = "--help" ]; }; then
    echo -e "${BOLD}Usage:${END_COLOR}"
    echo "  ./host-manager.sh restore-app [options]"
    echo ""
    echo -e "${BOLD}Options:${END_COLOR}"
    echo "  -id, --id ID                App ID of the application to restore [Required]"
    echo ""
    echo -e "${BOLD}Examples:${END_COLOR}"
    echo "  ./host-manager.sh restore-app -id \"my-app\""
    exit 0
fi

if [ "$1" = "list-apps" ] && { [ "$2" = "-h" ] || [ "$2" = "--help" ]; }; then
    echo -e "${BOLD}Usage:${END_COLOR}"
    echo "  ./host-manager.sh list-apps [options]"
    echo ""
    echo -e "${BOLD}Options:${END_COLOR}"
    echo "  --status active|removed|all  Filter apps by status (default: active)"
    echo "  --json                       Output the list of apps in raw JSON format"
    echo ""
    echo -e "${BOLD}Examples:${END_COLOR}"
    echo "  ./host-manager.sh list-apps"
    echo "  ./host-manager.sh list-apps --status removed"
    echo "  ./host-manager.sh list-apps --json"
    exit 0
fi

# Source deploy secrets
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SECRETS_FILE="$SCRIPT_DIR/.deploy-secrets"
if [ -f "$DEPLOY_SECRETS_FILE" ]; then
    source "$DEPLOY_SECRETS_FILE"
else
    echo "Cannot find deploy secrets at $DEPLOY_SECRETS_FILE"
    exit 1
fi

if [ -z "$LOCAL_PROJECTS_DIR" ] || [ -z "$BILLING_ACCOUNT_ID" ]; then
    echo "LOCAL_PROJECTS_DIR or BILLING_ACCOUNT_ID not set in .deploy-secrets"
    exit 1
fi

eval LOCAL_PROJECTS_DIR="$LOCAL_PROJECTS_DIR"
REGISTRY_DIR="$SCRIPT_DIR/apps-registry"
REGISTRY_FILE="$REGISTRY_DIR/apps-registry.json"

# Validate tools
for cmd in gh gcloud jq firebase; do
    if ! command -v $cmd &>/dev/null; then
        echo "$cmd CLI not found. Please install it."
        exit 1
    fi
done

# --- Startup Sync ---
GITHUB_USER=$(gh api user --jq .login 2>/dev/null)
if [ -z "$GITHUB_USER" ]; then
    echo "GitHub CLI (gh) is not authenticated. Run 'gh auth login' first."
    exit 1
fi

if [ ! -d "$REGISTRY_DIR" ]; then
    echo "Registry repository not found locally. Searching GitHub..."
    if ! gh repo view "$GITHUB_USER/apps-registry" &>/dev/null; then
        echo "Creating private GitHub repository: apps-registry..."
        mkdir -p "$REGISTRY_DIR"
        cd "$REGISTRY_DIR"
        git init
        git checkout -b main
        echo "[]" > apps-registry.json
        git add apps-registry.json
        git commit -m "Initialize registry"
        gh repo create "apps-registry" --private --source=. --remote=origin --push >/dev/null 2>&1
        cd "$SCRIPT_DIR"
    else
        echo "Cloning apps-registry from GitHub..."
        gh repo clone "$GITHUB_USER/apps-registry" "$REGISTRY_DIR" >/dev/null 2>&1
    fi
else
    echo "Syncing registry with GitHub..."
    cd "$REGISTRY_DIR"
    git pull >/dev/null 2>&1
    cd "$SCRIPT_DIR"
fi

# --- CLI Argument Handler ---
if [ "$#" -gt 0 ]; then
    INTERACTIVE=false
    CMD="$1"
    shift
    
    case "$CMD" in
        create-app)
            APP_NAME=""
            APP_ID=""
            URL_DOMAIN=""
            while [[ "$#" -gt 0 ]]; do
                case $1 in
                    -n|--name) APP_NAME="$2"; shift ;;
                    -id|--id) APP_ID="$2"; shift ;;
                    -urldomain|--url-domain|--domain) URL_DOMAIN="$2"; shift ;;
                    *) echo "Unknown parameter passed to create-app: $1"; exit 1 ;;
                esac
                shift
            done
            
            if [ -z "$APP_NAME" ]; then
                echo -e "${BOLD_RED}ERROR:${END_COLOR} App Name is required. Use -n or --name."
                exit 1
            fi
            
            # Call setup-new-app.sh with arguments
            ARGS=("-n" "$APP_NAME")
            if [ -n "$APP_ID" ]; then
                ARGS+=("-id" "$APP_ID")
            fi
            if [ -n "$URL_DOMAIN" ]; then
                ARGS+=("-urldomain" "$URL_DOMAIN")
            fi
            
            ./setup-new-app.sh "${ARGS[@]}"
            exit $?
            ;;
            
        remove-app)
            APP_ID=""
            while [[ "$#" -gt 0 ]]; do
                case $1 in
                    -id|--id) APP_ID="$2"; shift ;;
                    *) echo "Unknown parameter passed to remove-app: $1"; exit 1 ;;
                esac
                shift
            done
            
            if [ -z "$APP_ID" ]; then
                echo -e "${BOLD_RED}ERROR:${END_COLOR} App ID is required. Use -id or --id."
                exit 1
            fi
            
            # Check if app exists in registry first
            if [ -f "$REGISTRY_FILE" ]; then
                EXISTS=$(jq -r ".[] | select(.id == \"$APP_ID\" and .status == \"active\") | .id" "$REGISTRY_FILE")
                if [ -z "$EXISTS" ]; then
                    echo -e "${BOLD_RED}ERROR:${END_COLOR} Active app with ID '$APP_ID' not found in registry."
                    exit 1
                fi
            fi
            
            ./remove-app.sh --app-id "$APP_ID"
            exit $?
            ;;
            
        restore-app)
            APP_ID=""
            while [[ "$#" -gt 0 ]]; do
                case $1 in
                    -id|--id) APP_ID="$2"; shift ;;
                    *) echo "Unknown parameter passed to restore-app: $1"; exit 1 ;;
                esac
                shift
            done
            
            if [ -z "$APP_ID" ]; then
                echo -e "${BOLD_RED}ERROR:${END_COLOR} App ID is required. Use -id or --id."
                exit 1
            fi
            
            # Find in registry
            if [ -f "$REGISTRY_FILE" ]; then
                name=$(jq -r ".[] | select(.id == \"$APP_ID\") | .name" "$REGISTRY_FILE")
                domain=$(jq -r ".[] | select(.id == \"$APP_ID\") | .domain" "$REGISTRY_FILE")
                status=$(jq -r ".[] | select(.id == \"$APP_ID\") | .status" "$REGISTRY_FILE")
                
                if [ -z "$name" ] || [ "$name" = "null" ]; then
                    echo -e "${BOLD_RED}ERROR:${END_COLOR} App with ID '$APP_ID' not found in registry."
                    exit 1
                fi
                
                if [ "$status" = "active" ]; then
                    echo -e "${BOLD_RED}ERROR:${END_COLOR} App '$APP_ID' is already active."
                    exit 1
                fi
                
                restore_application "$APP_ID" "$name" "$domain"
                exit $?
            else
                echo -e "${BOLD_RED}ERROR:${END_COLOR} Registry file not found."
                exit 1
            fi
            ;;
            
        list-apps)
            STATUS_FILTER="active"
            OUTPUT_JSON=false
            while [[ "$#" -gt 0 ]]; do
                case $1 in
                    --status) STATUS_FILTER="$2"; shift ;;
                    --json) OUTPUT_JSON=true ;;
                    *) echo "Unknown parameter passed to list-apps: $1"; exit 1 ;;
                esac
                shift
            done
            
            if [ ! -f "$REGISTRY_FILE" ] || [ ! -s "$REGISTRY_FILE" ]; then
                if [ "$OUTPUT_JSON" = true ]; then
                    echo "[]"
                else
                    echo "No applications recorded in registry."
                fi
                exit 0
            fi
            
            if [ "$OUTPUT_JSON" = true ]; then
                if [ "$STATUS_FILTER" = "all" ]; then
                    jq '.' "$REGISTRY_FILE"
                else
                    jq --arg filter "$STATUS_FILTER" '[.[] | select(.status == $filter)]' "$REGISTRY_FILE"
                fi
            else
                echo -e "${BOLD_CYAN}=== Registered Applications (Status: $STATUS_FILTER) ===${END_COLOR}"
                echo ""
                if [ "$STATUS_FILTER" = "all" ]; then
                    jq -r '.[] | "\(.id) [\(.status)]\n  Name:   \(.name)\n  Domain: https://\(.domain)\n  Repo:   https://\(.github_repo)\n"' "$REGISTRY_FILE"
                else
                    jq -r --arg filter "$STATUS_FILTER" '.[] | select(.status == $filter) | "\(.id)\n  Name:   \(.name)\n  Domain: https://\(.domain)\n  Repo:   https://\(.github_repo)\n"' "$REGISTRY_FILE"
                fi
            fi
            exit 0
            ;;
            
        *)
            echo -e "${BOLD_RED}ERROR:${END_COLOR} Unknown command '$CMD'."
            echo "Use -h or --help for usage details."
            exit 1
            ;;
    esac
fi

# Function to print the main menu
print_menu() {
    local header=$1
    local selected=$2
    shift 2
    local options=("$@")
    
    echo -e "\033[H\033[J" # Clear the screen
    echo -e "${BOLD_CYAN}  $header  ${END_COLOR}"
    echo " "
    
    for ((i = 0; i < ${#options[@]}; i++)); do
        if [ $i -eq $selected ]; then
            echo -e "  $(tput setaf 6)$(tput bold)→ ${options[i]}$(tput sgr0)"
        else
            echo -e "    ${options[i]}"
        fi
    done
    echo " "
}

# General TUI navigation
navigate_menu() {
    local header=$1
    shift 1
    local options=("$@")
    local selected=0

    while true; do
        print_menu "$header" $selected "${options[@]}"

        read -rsn1 input
        if [[ $input == $'\x1b' ]]; then
            read -rsn2 input # read arrow keys
            case $input in
                '[A') # Up arrow
                    ((selected--))
                    if [ $selected -lt 0 ]; then
                        selected=$(( ${#options[@]} - 1 ))
                    fi
                    ;;
                '[B') # Down arrow
                    ((selected++))
                    if [ $selected -ge ${#options[@]} ] ; then
                        selected=0
                    fi
                    ;;
            esac
        elif [[ $input == "" ]]; then # Enter key
            break
        fi
    done

    selected_option=$selected
}

# Interactive app viewing, deletion and redeployment (TUI with Ctrl+R detection)
view_apps_interactive() {
    local show_removed=false
    
    while true; do
        local filter="active"
        local header="Active Applications (Press Ctrl+R for Archives)"
        if [ "$show_removed" = true ]; then
            filter="removed"
            header="Archived Applications (Press Ctrl+R for Active)"
        fi
        
        # Load app names from registry
        if [ ! -f "$REGISTRY_FILE" ] || [ ! -s "$REGISTRY_FILE" ]; then
            echo "No applications recorded in registry."
            read -p "Press Enter to go back..."
            return
        fi
        
        local app_ids=()
        IFS=$'\n' read -rd '' -a app_ids <<<"$(jq -r ".[] | select(.status == \"$filter\") | .id" "$REGISTRY_FILE")"
        
        if [ ${#app_ids[@]} -eq 0 ] || [ "${app_ids[0]}" = "" ]; then
            app_ids=()
        fi
        
        # Draw TUI
        local selected=0
        while true; do
            echo -e "\033[H\033[J"
            echo -e "${BOLD_CYAN}  $header  ${END_COLOR}\n"
            
            if [ ${#app_ids[@]} -eq 0 ]; then
                echo "    (No applications found)"
            else
                for ((i=0; i<${#app_ids[@]}; i++)); do
                    if [ $i -eq $selected ]; then
                        echo -e "  $(tput setaf 6)$(tput bold)→ ${app_ids[i]}$(tput sgr0)"
                    else
                        echo -e "    ${app_ids[i]}"
                    fi
                done
            fi
            echo -e "\n  $(tput setaf 5)← Back$(tput sgr0)"
            
            # Read character (detecting Ctrl+R = \x12)
            read -rsn1 input
            if [[ "$input" == $'\x12' ]]; then
                # Toggle views
                if [ "$show_removed" = true ]; then
                    show_removed=false
                else
                    show_removed=true
                fi
                break # break inner loop to reload app ids
            elif [[ $input == $'\x1b' ]]; then
                read -rsn2 input
                case $input in
                    '[A')
                        ((selected--))
                        if [ $selected -lt 0 ]; then
                            selected=${#app_ids[@]}
                        fi
                        ;;
                    '[B')
                        ((selected++))
                        if [ $selected -gt ${#app_ids[@]} ]; then
                            selected=0
                        fi
                        ;;
                esac
            elif [[ $input == "" ]]; then
                # Enter selected option
                if [ $selected -eq ${#app_ids[@]} ]; then
                    return # Go Back
                fi
                
                local selected_id="${app_ids[$selected]}"
                show_details_and_actions "$selected_id" "$filter"
                break # Reload list after return from action
            fi
        done
    done
}

# Display details, delete or trigger restore
show_details_and_actions() {
    local app_id=$1
    local filter=$2
    
    while true; do
        local name=$(jq -r ".[] | select(.id == \"$app_id\") | .name" "$REGISTRY_FILE")
        local domain=$(jq -r ".[] | select(.id == \"$app_id\") | .domain" "$REGISTRY_FILE")
        local firebase_project_id=$(jq -r ".[] | select(.id == \"$app_id\") | .firebase_project_id" "$REGISTRY_FILE")
        local gh_repo=$(jq -r ".[] | select(.id == \"$app_id\") | .github_repo" "$REGISTRY_FILE")
        local date=$(jq -r ".[] | select(.id == \"$app_id\") | .created_at" "$REGISTRY_FILE")
        
        echo -e "\033[H\033[J"
        echo -e "${BOLD_CYAN}=== Application Details ===${END_COLOR}\n"
        echo -e "Name:           ${BOLD}$name${END_COLOR}"
        echo -e "ID:             $app_id"
        if [ -n "$firebase_project_id" ] && [ "$firebase_project_id" != "null" ]; then
            echo -e "Firebase Proj:  $firebase_project_id"
        fi
        echo -e "Domain:         https://$domain"
        echo -e "GitHub Repo:    https://$gh_repo"
        echo -e "Created On:     $date"
        echo -e "Status:         $filter"
        echo " "
        
        if [ "$filter" = "removed" ]; then
            echo -e "  [R] Restore / Redeploy application"
            echo -e "  [Esc] Go back to list"
            echo " "
            
            read -rsn1 input
            if [[ "$input" == $'\x1b' ]] || [[ "$input" == "q" ]] || [[ "$input" == "Q" ]]; then
                return
            elif [[ "$input" == "r" ]] || [[ "$input" == "R" ]]; then
                echo " "
                read -p "Would you like to RESTORE/REDEPLOY this application? (y/N): " CONFIRM
                if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                    restore_application "$app_id" "$name" "$domain"
                    return
                fi
            fi
        else
            echo -e "  [D] Delete / Remove application"
            echo -e "  [Esc] Go back to list"
            echo " "
            
            read -rsn1 input
            if [[ "$input" == $'\x1b' ]] || [[ "$input" == "q" ]] || [[ "$input" == "Q" ]]; then
                return
            elif [[ "$input" == "d" ]] || [[ "$input" == "D" ]]; then
                echo " "
                read -p "Would you like to DELETE/REMOVE this application? (y/N): " CONFIRM
                if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                    ./remove-app.sh --app-id "$app_id"
                    # Refresh registry after removal
                    cd "$REGISTRY_DIR" && git pull >/dev/null 2>&1 && cd "$SCRIPT_DIR"
                    read -p "Press Enter to continue..."
                    return
                fi
            fi
        fi
    done
}

# Application restoration logic
restore_application() {
    local app_id=$1
    local app_name=$2
    local domain_name=$3
    
    echo -e "\nStarting restoration for $app_id..."
    
    # 1. Clone repository back
    local app_dir="$LOCAL_PROJECTS_DIR/$app_id"
    if [ -d "$app_dir" ]; then
        echo -e "${BOLD_RED}FAILED${END_COLOR} A folder already exists at $app_dir. Move or rename it first."
        press_enter_to_continue
        return 1
    fi
    
    echo "Cloning monorepo from GitHub..."
    if ! gh repo clone "$GITHUB_USER/$app_id" "$app_dir" >/dev/null 2>&1; then
        echo -e "${BOLD_RED}FAILED${END_COLOR} Cannot clone repository."
        press_enter_to_continue
        return 1
    fi
    
    # 2. Recreate Firebase Project
    local random_num=$(jot -r 1 10000 99999 2>/dev/null || shuf -i 10000-99999 -n 1 2>/dev/null || echo $((10000 + RANDOM % 90000)))
    local firebase_project_id="$app_id-$random_num"
    
    echo "Creating Firebase project $firebase_project_id..."
    if npx firebase-tools projects:create "$firebase_project_id" --display-name "$app_name"; then
        echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} Created Firebase Project"
    else
        echo -e "${BOLD_RED}FAILED${END_COLOR} Cannot create Firebase project. It might already exist."
        rm -rf "$app_dir"
        press_enter_to_continue
        return 1
    fi
    
    echo "Linking Billing Account $BILLING_ACCOUNT_ID..."
    gcloud billing projects link "$firebase_project_id" --billing-account="$BILLING_ACCOUNT_ID" >/dev/null
    
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
        --project="$firebase_project_id" >/dev/null 2>&1
    
    # Wait for API activation to propagate globally
    echo "Waiting for API propagation..."
    sleep 10
    
    # Overwrite root configs for monorepo
    cat <<EOF > "$app_dir/.firebaserc"
{
  "projects": {
    "default": "$firebase_project_id"
  }
}
EOF
    mkdir -p "$app_dir/.github/workflows"
    cat <<EOF > "$app_dir/.github/workflows/deploy.yml"
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
        run: npx firebase-tools deploy --project $firebase_project_id --force
EOF
    
    # 3. Recreate Service Account Key
    echo "Configuring GCP service account and keys..."
    gcloud iam service-accounts create firebase-deployer \
        --description="Deployment Service Account" \
        --display-name="Firebase Deployer" \
        --project="$firebase_project_id" >/dev/null 2>&1
        
    echo "Configuring IAM policy bindings for Deployer Service Account..."
    for i in {1..5}; do
        if gcloud projects add-iam-policy-binding "$firebase_project_id" \
            --member="serviceAccount:firebase-deployer@$firebase_project_id.iam.gserviceaccount.com" \
            --role="roles/editor" >/dev/null 2>&1 && \
           gcloud projects add-iam-policy-binding "$firebase_project_id" \
            --member="serviceAccount:firebase-deployer@$firebase_project_id.iam.gserviceaccount.com" \
            --role="roles/iam.serviceAccountUser" >/dev/null 2>&1 && \
           gcloud projects add-iam-policy-binding "$firebase_project_id" \
            --member="serviceAccount:firebase-deployer@$firebase_project_id.iam.gserviceaccount.com" \
            --role="roles/cloudfunctions.admin" >/dev/null 2>&1 && \
           gcloud projects add-iam-policy-binding "$firebase_project_id" \
            --member="serviceAccount:firebase-deployer@$firebase_project_id.iam.gserviceaccount.com" \
            --role="roles/run.admin" >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
        
    echo "Generating service account keys..."
    for i in {1..5}; do
        if gcloud iam service-accounts keys create "$app_dir/firebase-key.json" \
            --iam-account="firebase-deployer@$firebase_project_id.iam.gserviceaccount.com" >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
    
    # 4. Upload keys back to GitHub Secrets
    echo "Updating secrets on GitHub repositories..."
    gh secret set FIREBASE_SERVICE_ACCOUNT_KEY --repo "$GITHUB_USER/$app_id" < "$app_dir/firebase-key.json" >/dev/null 2>&1
    rm -f "$app_dir/firebase-key.json"
    
    # 5. Connect domains on Firebase
    echo "Linking custom domains in Firebase Hosting..."
    ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null)
    if [ -n "$ACCESS_TOKEN" ]; then
        echo "Registering $app_id.danzaharia.com..."
        response_dz=$(curl -s -w "\n%{http_code}" -X POST "https://firebasehosting.googleapis.com/v1beta1/projects/$firebase_project_id/sites/$firebase_project_id/customDomains?customDomainId=$app_id.danzaharia.com" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "X-Goog-User-Project: $firebase_project_id" \
            -H "Content-Type: application/json" \
            -d "{}")
        code_dz=$(echo "$response_dz" | tail -n 1)
        body_dz=$(echo "$response_dz" | head -n -1)
        if [ "$code_dz" -ne 200 ] && [ "$code_dz" -ne 201 ]; then
            echo -e "${BOLD_RED}WARNING:${END_COLOR} Failed to register $app_id.danzaharia.com (HTTP $code_dz)"
            echo "Details: $body_dz"
        else
            echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} Registered $app_id.danzaharia.com"
        fi
            
        echo "Registering $app_id.adanmade.app..."
        response_adma=$(curl -s -w "\n%{http_code}" -X POST "https://firebasehosting.googleapis.com/v1beta1/projects/$firebase_project_id/sites/$firebase_project_id/customDomains?customDomainId=$app_id.adanmade.app" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "X-Goog-User-Project: $firebase_project_id" \
            -H "Content-Type: application/json" \
            -d "{}")
        code_adma=$(echo "$response_adma" | tail -n 1)
        body_adma=$(echo "$response_adma" | head -n -1)
        if [ "$code_adma" -ne 200 ] && [ "$code_adma" -ne 201 ]; then
            echo -e "${BOLD_RED}WARNING:${END_COLOR} Failed to register $app_id.adanmade.app (HTTP $code_adma)"
            echo "Details: $body_adma"
        else
            echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} Registered $app_id.adanmade.app"
        fi
    fi
    
    # 6. Re-configure Cloudflare records for both domains
    if [ -n "$CLOUDFLARE_API_TOKEN" ]; then
        if [ -n "$DZ_ZONE_ID" ]; then
            echo "Creating Cloudflare CNAME record for $app_id.danzaharia.com..."
            curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$DZ_ZONE_ID/dns_records" \
                -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
                -H "Content-Type: application/json" \
                --data "{
                  \"type\": \"CNAME\",
                  \"name\": \"$app_id.danzaharia.com\",
                  \"content\": \"$firebase_project_id.web.app\",
                  \"ttl\": 1,
                  \"proxied\": false
                }" > /dev/null
        fi
        if [ -n "$ADMA_ZONE_ID" ]; then
            echo "Creating Cloudflare CNAME record for $app_id.adanmade.app..."
            curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ADMA_ZONE_ID/dns_records" \
                -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
                -H "Content-Type: application/json" \
                --data "{
                  \"type\": \"CNAME\",
                  \"name\": \"$app_id.adanmade.app\",
                  \"content\": \"$firebase_project_id.web.app\",
                  \"ttl\": 1,
                  \"proxied\": false
                }" > /dev/null
        fi
    fi
    
    # 7. Update status in registry
    echo "Updating status in synchronized registry..."
    cd "$REGISTRY_DIR"
    jq --arg f_pid "$firebase_project_id" --arg app_id "$app_id" 'map(if .id == $app_id and .status == "removed" then .status = "active" | .firebase_project_id = $f_pid else . end)' apps-registry.json > apps-registry.tmp.json && mv apps-registry.tmp.json apps-registry.json
    git add apps-registry.json
    git commit -m "Restore app: $app_id"
    git push >/dev/null 2>&1
    cd "$SCRIPT_DIR"
    
    # 8. Trigger deployment push
    echo "Triggering automated deployments on GitHub..."
    (cd "$app_dir" && git add .firebaserc .github/workflows/deploy.yml && git commit -m "Update Firebase project ID for restore" && git push origin main) >/dev/null 2>&1
    
    echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} $app_id has been fully restored and is redeploying!"
    press_enter_to_continue
    return 0
}

# --- Main Program Loop ---
while true; do
    menu_options=("Create app" "View apps" "Exit")
    navigate_menu "Let Dan Code!" "${menu_options[@]}"
    selection=$selected_option

    case $selection in
        0)
            ./setup-new-app.sh
            # Pull latest registry updates after creation completes
            cd "$REGISTRY_DIR" && git pull >/dev/null 2>&1 && cd "$SCRIPT_DIR"
            read -p "Press Enter to return to menu..."
            ;;
        1)
            view_apps_interactive
            ;;
        2)
            echo "Exiting..."
            break
            ;;
    esac
done
