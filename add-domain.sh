#!/bin/bash

# Attach additional custom domain(s) to an existing active app:
#   1. Register the domain with Firebase Hosting
#   2. Create the Cloudflare CNAME record pointing at <project>.web.app
#   3. Record the domain in the synchronized apps registry

# Set up formatting
BOLD='\033[1m'
BOLD_RED='\033[1;31m'
BOLD_GREEN='\033[1;32m'
END_COLOR='\033[0m'

# Parse CLI arguments
APP_ID=""
NEW_DOMAINS=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -id|--id|--app-id) APP_ID="$2"; shift ;;
        -domain|--domain|-urldomain|--url-domain) NEW_DOMAINS="$2"; shift ;;
        -h|--help)
            echo "Usage: ./add-domain.sh [options]"
            echo "Options:"
            echo "  -id, --id ID             App ID of an active app in the registry"
            echo "  -domain, --domain DOM    Domain(s) to add, comma-separated"
            echo "                           (or a bare prefix for the default zones)"
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

if [ ${#CLOUDFLARE_ZONES[@]} -eq 0 ]; then
    echo -e "${BOLD_RED}FAILED${END_COLOR} CLOUDFLARE_ZONES not set properly in .settings"
    exit 1
fi

# Validate tools
for cmd in gcloud jq; do
    if ! command -v $cmd &>/dev/null; then
        echo -e "${BOLD_RED}FAILED${END_COLOR} $cmd CLI not found. Please install it."
        exit 1
    fi
done

# Prompts
if [ -z "$APP_ID" ]; then
    read -p "App ID: " APP_ID
fi
APP_ID=$(echo "$APP_ID" | tr -d '\r')

if [ -z "$NEW_DOMAINS" ]; then
    read -p "Domain to add (full domain, or prefix for default zones): " NEW_DOMAINS
fi
NEW_DOMAINS=$(echo "$NEW_DOMAINS" | tr -d '\r' | tr -d ' ')

if [ -z "$APP_ID" ] || [ -z "$NEW_DOMAINS" ]; then
    echo -e "${BOLD_RED}FAILED${END_COLOR} App ID and domain are both required."
    exit 1
fi

# Look up the app in the registry
REGISTRY_FILE="$SCRIPT_DIR/apps-registry/apps-registry.json"
if [ ! -f "$REGISTRY_FILE" ]; then
    echo -e "${BOLD_RED}FAILED${END_COLOR} Registry file not found at $REGISTRY_FILE"
    exit 1
fi

APP_NAME=$(jq -r --arg id "$APP_ID" '.[] | select(.id == $id and .status == "active") | .name' "$REGISTRY_FILE")
FIREBASE_PROJECT_ID=$(jq -r --arg id "$APP_ID" '.[] | select(.id == $id and .status == "active") | .firebase_project_id // empty' "$REGISTRY_FILE")

if [ -z "$APP_NAME" ]; then
    echo -e "${BOLD_RED}FAILED${END_COLOR} Active app with ID '$APP_ID' not found in registry."
    exit 1
fi

if [ -z "$FIREBASE_PROJECT_ID" ] || [ "$FIREBASE_PROJECT_ID" = "null" ]; then
    echo -e "${BOLD_RED}FAILED${END_COLOR} App '$APP_ID' has no firebase_project_id recorded; cannot attach domains."
    exit 1
fi

# Expand bare prefixes (no dot) across the configured zones, matching the
# -urldomain behavior of setup-new-app.sh
DOMAINS_ARRAY=()
IFS=',' read -r -a RAW_DOMAINS <<< "$NEW_DOMAINS"
for raw in "${RAW_DOMAINS[@]}"; do
    [ -z "$raw" ] && continue
    if [[ "$raw" == *.* ]]; then
        DOMAINS_ARRAY+=("$raw")
    else
        for mapping in "${CLOUDFLARE_ZONES[@]}"; do
            base_domain="${mapping%%:*}"
            DOMAINS_ARRAY+=("$raw.$base_domain")
        done
    fi
done

if [ ${#DOMAINS_ARRAY[@]} -eq 0 ]; then
    echo -e "${BOLD_RED}FAILED${END_COLOR} No valid domains to add."
    exit 1
fi

echo -e "\nSummary:"
echo "App Name:            $APP_NAME"
echo "App ID:              $APP_ID"
echo "Firebase Project ID: $FIREBASE_PROJECT_ID"
echo "Domains to add:      "
for domain in "${DOMAINS_ARRAY[@]}"; do
    echo "                     https://$domain"
done
echo " "

ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null)
if [ -z "$ACCESS_TOKEN" ]; then
    echo -e "${BOLD_RED}FAILED${END_COLOR} Google Cloud CLI (gcloud) not authenticated."
    exit 1
fi

for domain in "${DOMAINS_ARRAY[@]}"; do
    # Firebase Hosting custom domain
    echo "Registering $domain in Firebase Hosting..."
    response=$(curl -s -w "\n%{http_code}" -X POST "https://firebasehosting.googleapis.com/v1beta1/projects/$FIREBASE_PROJECT_ID/sites/$FIREBASE_PROJECT_ID/customDomains?customDomainId=$domain" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "X-Goog-User-Project: $FIREBASE_PROJECT_ID" \
        -H "Content-Type: application/json" \
        -d "{}")
    code=$(echo "$response" | tail -n 1)
    body=$(echo "$response" | sed '$d')
    if [ "$code" -eq 200 ] || [ "$code" -eq 201 ]; then
        echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} Registered $domain in Firebase Hosting"
    elif [ "$code" -eq 409 ] || echo "$body" | grep -q "ALREADY_EXISTS"; then
        echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} $domain is already registered in Firebase Hosting"
    else
        echo -e "${BOLD_RED}WARNING:${END_COLOR} Failed to register $domain in Firebase Hosting (HTTP $code)"
        echo "Details: $body"
    fi

    # Cloudflare CNAME record
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
            cf_body=$(echo "$cf_response" | sed '$d')
            if [ "$cf_code" -eq 200 ] || [ "$cf_code" -eq 201 ]; then
                echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} Created Cloudflare DNS record (DNS-only) for $domain"
            elif echo "$cf_body" | grep -qi "already exists"; then
                echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} Cloudflare DNS record for $domain already exists"
            else
                echo -e "${BOLD_RED}WARNING:${END_COLOR} Failed to create Cloudflare DNS record for $domain (HTTP $cf_code)"
                echo "Details: $cf_body"
            fi
        else
            echo "Cloudflare automatic DNS setup skipped for $domain (unrecognized zone or zone ID not set)"
            echo "Point $domain at $FIREBASE_PROJECT_ID.web.app with a CNAME record manually."
        fi
    else
        echo "Cloudflare automatic DNS setup skipped for $domain (CLOUDFLARE_API_TOKEN not set)"
    fi
done

# Record the domains in the synchronized registry (no-op when already present)
echo "Logging domains to synchronized registry..."
DOMAINS_JSON=$(printf '%s\n' "${DOMAINS_ARRAY[@]}" | jq -R . | jq -s .)

cd "$SCRIPT_DIR/apps-registry"
jq --arg id "$APP_ID" --argjson new "$DOMAINS_JSON" \
    'map(if .id == $id and .status == "active"
         then .domains = ((.domains // (if has("domain") and (.domain | type == "string") then [.domain] else [] end)) as $d | $d + ($new - $d))
         else . end)' \
    apps-registry.json > apps-registry.tmp.json

if cmp -s apps-registry.json apps-registry.tmp.json; then
    rm -f apps-registry.tmp.json
    echo "Registry already lists these domains."
else
    mv apps-registry.tmp.json apps-registry.json
    git add apps-registry.json
    git commit -m "Add domains to $APP_ID: ${DOMAINS_ARRAY[*]}" >/dev/null 2>&1
    git push >/dev/null 2>&1
    echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} Registry updated"
fi

echo -e "\n${BOLD}*** Domains attached to $APP_ID ***${END_COLOR}\n"
for domain in "${DOMAINS_ARRAY[@]}"; do
    echo -e "* ${BOLD}https://$domain${END_COLOR}"
done
echo -e "\nFirebase may take a few minutes to verify DNS and provision the SSL certificate."
