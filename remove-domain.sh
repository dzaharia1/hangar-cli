#!/bin/bash

# Detach custom domain(s) from an existing active app:
#   1. Remove the domain from Firebase Hosting
#   2. Delete the Cloudflare CNAME record
#   3. Remove the domain from the synchronized apps registry

# Set up formatting
BOLD='\033[1m'
BOLD_RED='\033[1;31m'
BOLD_GREEN='\033[1;32m'
END_COLOR='\033[0m'

# Parse CLI arguments
APP_ID=""
GONE_DOMAINS=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -id|--id|--app-id) APP_ID="$2"; shift ;;
        -domain|--domain|-urldomain|--url-domain) GONE_DOMAINS="$2"; shift ;;
        -h|--help)
            echo "Usage: ./remove-domain.sh [options]"
            echo "Options:"
            echo "  -id, --id ID             App ID of an active app in the registry"
            echo "  -domain, --domain DOM    Domain(s) to remove, comma-separated"
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

if [ -z "$GONE_DOMAINS" ]; then
    read -p "Domain to remove (full domain, or prefix for default zones): " GONE_DOMAINS
fi
GONE_DOMAINS=$(echo "$GONE_DOMAINS" | tr -d '\r' | tr -d ' ')

if [ -z "$APP_ID" ] || [ -z "$GONE_DOMAINS" ]; then
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
    echo -e "${BOLD_RED}FAILED${END_COLOR} App '$APP_ID' has no firebase_project_id recorded; cannot detach domains."
    exit 1
fi

# Expand bare prefixes (no dot) across the configured zones, matching the
# -urldomain behavior of setup-new-app.sh
DOMAINS_ARRAY=()
IFS=',' read -r -a RAW_DOMAINS <<< "$GONE_DOMAINS"
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
    echo -e "${BOLD_RED}FAILED${END_COLOR} No valid domains to remove."
    exit 1
fi

echo -e "\nSummary:"
echo "App Name:            $APP_NAME"
echo "App ID:              $APP_ID"
echo "Firebase Project ID: $FIREBASE_PROJECT_ID"
echo "Domains to remove:   "
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
    echo "Removing $domain from Firebase Hosting..."
    response=$(curl -s -w "\n%{http_code}" -X DELETE "https://firebasehosting.googleapis.com/v1beta1/projects/$FIREBASE_PROJECT_ID/sites/$FIREBASE_PROJECT_ID/customDomains/$domain" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "X-Goog-User-Project: $FIREBASE_PROJECT_ID" \
        -H "Content-Type: application/json")
    code=$(echo "$response" | tail -n 1)
    body=$(echo "$response" | sed '$d')
    if [ "$code" -eq 200 ] || [ "$code" -eq 204 ]; then
        echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} Removed $domain from Firebase Hosting"
    elif [ "$code" -eq 404 ] || echo "$body" | grep -q "NOT_FOUND"; then
        echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} $domain was not registered in Firebase Hosting"
    else
        echo -e "${BOLD_RED}WARNING:${END_COLOR} Failed to remove $domain from Firebase Hosting (HTTP $code)"
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
            echo "Finding DNS record in Cloudflare for $domain..."
            record_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=CNAME&name=$domain" \
                -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
                -H "Content-Type: application/json" | jq -r '.result[0].id // empty')

            if [ -n "$record_id" ]; then
                echo "Deleting Cloudflare DNS record..."
                cf_response=$(curl -s -w "\n%{http_code}" -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$record_id" \
                    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
                    -H "Content-Type: application/json")
                cf_code=$(echo "$cf_response" | tail -n 1)
                cf_body=$(echo "$cf_response" | sed '$d')
                if [ "$cf_code" -eq 200 ]; then
                    echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} Deleted Cloudflare DNS record for $domain"
                else
                    echo -e "${BOLD_RED}WARNING:${END_COLOR} Failed to delete Cloudflare DNS record for $domain (HTTP $cf_code)"
                    echo "Details: $cf_body"
                fi
            else
                echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} No Cloudflare CNAME record found for $domain"
            fi
        else
            echo "Cloudflare automatic DNS cleanup skipped for $domain (unrecognized zone or zone ID not set)"
            echo "Delete the CNAME record for $domain manually if it exists."
        fi
    else
        echo "Cloudflare automatic DNS cleanup skipped for $domain (CLOUDFLARE_API_TOKEN not set)"
    fi
done

# Remove the domains from the synchronized registry (no-op when already absent)
echo "Removing domains from synchronized registry..."
DOMAINS_JSON=$(printf '%s\n' "${DOMAINS_ARRAY[@]}" | jq -R . | jq -s .)

cd "$SCRIPT_DIR/apps-registry"
jq --arg id "$APP_ID" --argjson gone "$DOMAINS_JSON" \
    'map(if .id == $id and .status == "active"
         then .domains = ((.domains // (if has("domain") and (.domain | type == "string") then [.domain] else [] end)) - $gone)
         else . end)' \
    apps-registry.json > apps-registry.tmp.json

if cmp -s apps-registry.json apps-registry.tmp.json; then
    rm -f apps-registry.tmp.json
    echo "Registry already had these domains removed."
else
    mv apps-registry.tmp.json apps-registry.json
    git add apps-registry.json
    git commit -m "Remove domains from $APP_ID: ${DOMAINS_ARRAY[*]}" >/dev/null 2>&1
    git push >/dev/null 2>&1
    echo -e "${BOLD_GREEN}SUCCESS${END_COLOR} Registry updated"
fi

echo -e "\n${BOLD}*** Domains detached from $APP_ID ***${END_COLOR}\n"
for domain in "${DOMAINS_ARRAY[@]}"; do
    echo -e "* $domain"
done
