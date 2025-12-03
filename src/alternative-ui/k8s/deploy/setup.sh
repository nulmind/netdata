#!/bin/bash
# Quick setup script for k0s + Netdata Alternative UI on Fly.io
#
# Usage:
#   ./setup.sh [app-name]
#
# This script will:
#   1. Generate secure credentials (API key, dashboard password)
#   2. Deploy the Alternative UI to Fly.io with authentication
#   3. Deploy the k8s-collector to your current kubectl context

set -e

APP_NAME="${1:-netdata-k0s-demo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Netdata k0s Test Cluster Setup ==="
echo ""
echo "App name: $APP_NAME"
echo "UI directory: $UI_DIR"
echo ""

# Generate random password/key
generate_random() {
    local length="${1:-32}"
    if command -v openssl &> /dev/null; then
        openssl rand -base64 "$length" | tr -dc 'a-zA-Z0-9' | head -c "$length"
    else
        head -c "$length" /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c "$length"
    fi
}

# Check prerequisites
check_prereqs() {
    local missing=0

    if ! command -v flyctl &> /dev/null; then
        echo "Error: flyctl not found. Install from https://fly.io/docs/hands-on/install-flyctl/"
        missing=1
    fi

    if ! command -v kubectl &> /dev/null; then
        echo "Error: kubectl not found. Install from https://kubernetes.io/docs/tasks/tools/"
        missing=1
    fi

    if [ $missing -eq 1 ]; then
        exit 1
    fi

    # Check flyctl auth
    if ! flyctl auth whoami &> /dev/null; then
        echo "Error: Not logged in to Fly.io. Run: flyctl auth login"
        exit 1
    fi

    # Check kubectl context
    if ! kubectl cluster-info &> /dev/null; then
        echo "Warning: kubectl not connected to a cluster."
        echo "         Will only deploy UI to Fly.io"
        NO_CLUSTER=1
    fi
}

# Configure authentication
configure_auth() {
    echo ""
    echo "=== Authentication Configuration ==="
    echo ""

    # Check for existing secrets
    if flyctl apps list 2>/dev/null | grep -q "^$APP_NAME"; then
        echo "App '$APP_NAME' exists. Checking for existing secrets..."
        EXISTING_SECRETS=$(flyctl secrets list --app "$APP_NAME" 2>/dev/null | grep -E "^(AUTH_USERNAME|AUTH_PASSWORD|API_KEY)" || true)
        if [ -n "$EXISTING_SECRETS" ]; then
            echo "Existing secrets found:"
            echo "$EXISTING_SECRETS"
            echo ""
            read -p "Do you want to keep existing secrets? [Y/n] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
                # Get API_KEY from existing secrets for Kubernetes
                API_KEY=$(flyctl secrets list --app "$APP_NAME" 2>/dev/null | grep "^API_KEY" | awk '{print "***existing***"}')
                echo "Keeping existing secrets. Note: You'll need to manually get the API_KEY for Kubernetes."
                read -p "Enter the existing API_KEY for Kubernetes deployment: " API_KEY
                return
            fi
        fi
    fi

    # Dashboard credentials
    echo "Dashboard Authentication (HTTP Basic Auth):"
    read -p "  Username [admin]: " AUTH_USERNAME
    AUTH_USERNAME="${AUTH_USERNAME:-admin}"

    if [ -t 0 ]; then
        read -s -p "  Password (leave empty to generate): " AUTH_PASSWORD
        echo
    fi

    if [ -z "$AUTH_PASSWORD" ]; then
        AUTH_PASSWORD=$(generate_random 24)
        echo "  Generated password: $AUTH_PASSWORD"
    fi

    # API Key for collectors
    echo ""
    echo "API Key (for collector authentication):"
    read -p "  API Key (leave empty to generate): " API_KEY

    if [ -z "$API_KEY" ]; then
        API_KEY=$(generate_random 32)
        echo "  Generated API key: $API_KEY"
    fi

    echo ""
    echo "=== Save These Credentials ==="
    echo ""
    echo "Dashboard URL: https://${APP_NAME}.fly.dev"
    echo "Dashboard Username: $AUTH_USERNAME"
    echo "Dashboard Password: $AUTH_PASSWORD"
    echo "API Key: $API_KEY"
    echo ""
    echo "Press Enter to continue..."
    read
}

# Deploy Alternative UI to Fly.io
deploy_ui() {
    echo ""
    echo "=== Step 1: Deploying Alternative UI to Fly.io ==="
    echo ""

    cd "$UI_DIR"

    # Check if app exists
    if flyctl apps list 2>/dev/null | grep -q "^$APP_NAME"; then
        echo "App '$APP_NAME' already exists, updating..."
    else
        echo "Creating new app '$APP_NAME'..."
        flyctl launch --name "$APP_NAME" --no-deploy --copy-config --yes
    fi

    # Set secrets
    echo "Setting authentication secrets..."
    flyctl secrets set \
        AUTH_USERNAME="$AUTH_USERNAME" \
        AUTH_PASSWORD="$AUTH_PASSWORD" \
        API_KEY="$API_KEY" \
        --app "$APP_NAME"

    # Deploy
    echo "Deploying application..."
    flyctl deploy --app "$APP_NAME"

    # Get the app URL
    APP_URL="https://${APP_NAME}.fly.dev"
    echo ""
    echo "UI deployed to: $APP_URL"
}

# Deploy collector to Kubernetes
deploy_collector() {
    if [ "${NO_CLUSTER:-0}" = "1" ]; then
        echo ""
        echo "=== Skipping collector deployment (no cluster) ==="
        return
    fi

    echo ""
    echo "=== Step 2: Deploying k8s-collector to Kubernetes ==="
    echo ""

    # Create namespace first
    kubectl create namespace netdata-collector --dry-run=client -o yaml | kubectl apply -f -

    # Create or update the secret with the API key
    echo "Creating API key secret..."
    kubectl create secret generic k8s-collector-secret \
        --namespace netdata-collector \
        --from-literal=API_KEY="$API_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Update the manifest with the correct URL
    MANIFEST="$SCRIPT_DIR/manifests.yaml"
    TEMP_MANIFEST=$(mktemp)

    # Update PUSH_URL and remove the secret definition (we created it above)
    sed -e "s|PUSH_URL:.*|PUSH_URL: \"$APP_URL\"|g" \
        -e '/^---$/,/^---$/{ /kind: Secret/,/API_KEY:/d }' \
        "$MANIFEST" > "$TEMP_MANIFEST"

    echo "Applying manifests to cluster..."
    kubectl apply -f "$TEMP_MANIFEST"

    rm "$TEMP_MANIFEST"

    # Wait for deployment
    echo ""
    echo "Waiting for collector to be ready..."
    kubectl rollout status deployment/k8s-collector -n netdata-collector --timeout=60s || true

    # Show logs
    echo ""
    echo "Collector logs (last 10 lines):"
    sleep 3
    kubectl logs -n netdata-collector -l app.kubernetes.io/name=netdata-k8s-collector --tail=10 || true
}

# Print summary
print_summary() {
    echo ""
    echo "=========================================="
    echo "           Setup Complete"
    echo "=========================================="
    echo ""
    echo "Dashboard URL: $APP_URL"
    echo ""
    echo "Login credentials:"
    echo "  Username: $AUTH_USERNAME"
    echo "  Password: $AUTH_PASSWORD"
    echo ""
    echo "API Key (for collectors): $API_KEY"
    echo ""
    if [ "${NO_CLUSTER:-0}" = "1" ]; then
        echo "To deploy the collector to a cluster later:"
        echo "  1. Connect kubectl to your k0s cluster"
        echo "  2. Create the secret:"
        echo "     kubectl create secret generic k8s-collector-secret \\"
        echo "       --namespace netdata-collector \\"
        echo "       --from-literal=API_KEY=$API_KEY"
        echo "  3. Apply manifests:"
        echo "     kubectl apply -f $SCRIPT_DIR/manifests.yaml"
    else
        echo "Collector status:"
        echo "  kubectl logs -n netdata-collector -l app.kubernetes.io/name=netdata-k8s-collector -f"
        echo ""
        echo "To remove collector:"
        echo "  kubectl delete -f $SCRIPT_DIR/manifests.yaml"
    fi
    echo ""
    echo "To destroy the Fly.io app:"
    echo "  flyctl apps destroy $APP_NAME"
    echo ""
    echo "=========================================="
}

# Main
main() {
    check_prereqs
    configure_auth
    deploy_ui
    deploy_collector
    print_summary
}

main
