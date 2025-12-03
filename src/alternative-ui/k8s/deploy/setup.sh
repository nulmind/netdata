#!/bin/bash
# Quick setup script for k0s + Netdata Alternative UI on Fly.io
#
# Usage:
#   ./setup.sh [app-name]
#
# This script will:
#   1. Deploy the Alternative UI to Fly.io
#   2. Deploy the k8s-collector to your current kubectl context

set -e

APP_NAME="${1:-netdata-k0s-demo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Netdata k0s Test Cluster Setup ==="
echo ""
echo "App name: $APP_NAME"
echo "UI directory: $UI_DIR"
echo ""

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

    if ! command -v docker &> /dev/null; then
        echo "Warning: docker not found. You may need it for local testing."
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

# Deploy Alternative UI to Fly.io
deploy_ui() {
    echo ""
    echo "=== Step 1: Deploying Alternative UI to Fly.io ==="
    echo ""

    cd "$UI_DIR"

    # Check if app exists
    if flyctl apps list | grep -q "^$APP_NAME"; then
        echo "App '$APP_NAME' already exists, deploying update..."
        flyctl deploy --app "$APP_NAME"
    else
        echo "Creating new app '$APP_NAME'..."
        # Create app without immediate deployment
        flyctl launch --name "$APP_NAME" --no-deploy --copy-config --yes
        flyctl deploy
    fi

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

    # Update the manifest with the correct URL
    MANIFEST="$SCRIPT_DIR/manifests.yaml"
    TEMP_MANIFEST=$(mktemp)

    sed "s|PUSH_URL:.*|PUSH_URL: \"$APP_URL\"|g" "$MANIFEST" > "$TEMP_MANIFEST"

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
    echo "=== Setup Complete ==="
    echo ""
    echo "Dashboard URL: $APP_URL"
    echo ""
    echo "The k0s metrics collector is now pushing data every 10 seconds."
    echo "Open the dashboard URL in your browser to see the metrics."
    echo ""
    if [ "${NO_CLUSTER:-0}" = "1" ]; then
        echo "To deploy the collector to a cluster later:"
        echo "  1. Connect kubectl to your k0s cluster"
        echo "  2. Run: kubectl apply -f $SCRIPT_DIR/manifests.yaml"
        echo "     (update PUSH_URL in the manifest first)"
    else
        echo "To check collector status:"
        echo "  kubectl logs -n netdata-collector -l app.kubernetes.io/name=netdata-k8s-collector -f"
        echo ""
        echo "To remove collector:"
        echo "  kubectl delete -f $SCRIPT_DIR/manifests.yaml"
    fi
    echo ""
    echo "To destroy the Fly.io app:"
    echo "  flyctl apps destroy $APP_NAME"
}

# Main
main() {
    check_prereqs
    deploy_ui
    deploy_collector
    print_summary
}

main
