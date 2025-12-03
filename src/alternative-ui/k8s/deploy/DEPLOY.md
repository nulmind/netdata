# Deploy k0s Test Cluster with Netdata Alternative UI on Fly.io

This guide walks you through setting up a complete k0s Kubernetes cluster with Netdata monitoring, all exposed via Fly.io for easy access.

## Automatic PR Previews

When you open a PR that modifies the alternative-ui code, a GitHub Actions workflow automatically:
1. Deploys a preview environment to Fly.io
2. Generates secure credentials
3. Comments on the PR with the URL and login details

Just look for the bot comment on your PR!

> **Note:** Requires `FLY_API_TOKEN` secret to be configured in the repository.

## Quick Start

The fastest way to get started is using the setup script:

```bash
cd src/alternative-ui/k8s/deploy
./setup.sh netdata-k0s-demo
```

This will:
1. Prompt you for authentication credentials (or generate them)
2. Deploy the Alternative UI to Fly.io with authentication enabled
3. Deploy the k8s-collector to your current kubectl context

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                       Internet                               │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                  Fly.io Edge (HTTPS)                        │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │         Alternative UI Server (fly app)              │   │
│  │              https://your-app.fly.dev                │   │
│  │                                                      │   │
│  │  • Web Dashboard (/)                                 │   │
│  │  • Metrics API (/api/v1/*)                          │   │
│  │  • WebSocket (/ws)                                  │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          │ Metrics Push (HTTPS)
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                    k0s Cluster                              │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              k8s-collector (Pod)                     │   │
│  │                                                      │   │
│  │  • Collects node/pod/deployment metrics             │   │
│  │  • Detects k0s distribution                         │   │
│  │  • Monitors k0s system components                   │   │
│  │  • Pushes to Alternative UI every 10s              │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │ Controller   │  │   Worker 1   │  │   Worker 2   │     │
│  └──────────────┘  └──────────────┘  └──────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- [Fly.io CLI](https://fly.io/docs/hands-on/install-flyctl/) installed and authenticated
- A k0s cluster (see options below for creating one)
- kubectl configured to access your cluster
- Docker (for building images)

## Authentication

The Alternative UI supports two types of authentication:

| Type | Purpose | How it works |
|------|---------|--------------|
| **HTTP Basic Auth** | Protects the web dashboard | Username/password prompt in browser |
| **API Key** | Authenticates collectors | `X-API-Key` header on push requests |

### Setting up Authentication

When deploying manually (not using `setup.sh`), set these Fly.io secrets:

```bash
# Generate a secure API key
API_KEY=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)

# Set secrets in Fly.io
flyctl secrets set \
  AUTH_USERNAME=admin \
  AUTH_PASSWORD=your-secure-password \
  API_KEY=$API_KEY \
  --app netdata-k0s-demo
```

### Deploying Collector with API Key

Create a Kubernetes secret with the same API key:

```bash
kubectl create secret generic k8s-collector-secret \
  --namespace netdata-collector \
  --from-literal=API_KEY=$API_KEY
```

Then apply the manifests (the Deployment is already configured to use this secret).

## Option A: Quick Setup (Existing k0s Cluster)

If you already have a k0s cluster, follow these steps:

### Step 1: Deploy Alternative UI to Fly.io

```bash
cd src/alternative-ui

# Create new fly app (first time only)
flyctl launch --name netdata-k0s-demo --no-deploy

# Set authentication secrets
API_KEY=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
flyctl secrets set \
  AUTH_USERNAME=admin \
  AUTH_PASSWORD=your-secure-password \
  API_KEY=$API_KEY \
  --app netdata-k0s-demo

# Deploy
flyctl deploy
```

Your UI will be available at: `https://netdata-k0s-demo.fly.dev`

### Step 2: Deploy Collector to k0s Cluster

```bash
# Create the namespace and secret
kubectl create namespace netdata-collector
kubectl create secret generic k8s-collector-secret \
  --namespace netdata-collector \
  --from-literal=API_KEY=$API_KEY

# Update the PUSH_URL in the manifest to your fly app URL
sed -i 's|PUSH_URL:.*|PUSH_URL: "https://netdata-k0s-demo.fly.dev"|' k8s/deploy/manifests.yaml

# Apply manifests
kubectl apply -f k8s/deploy/manifests.yaml
```

### Step 3: Access the Dashboard

Open your browser to: `https://netdata-k0s-demo.fly.dev`

Enter your credentials (admin / your-secure-password) and you should see your k0s cluster metrics within 30 seconds.

---

## Option B: Create k0s Cluster on Fly.io Machines

Fly.io Machines can run k0s directly. This creates a complete test environment.

### Step 1: Create Fly App for k0s

```bash
# Create a new app for k0s nodes
flyctl apps create k0s-test-nodes
```

### Step 2: Create k0s Controller Machine

```bash
# Create a controller node (2GB RAM minimum for k0s controller)
flyctl machine run \
  --app k0s-test-nodes \
  --name k0s-controller \
  --region ord \
  --vm-size shared-cpu-2x \
  --vm-memory 2048 \
  docker.io/k0sproject/k0s:v1.29.1-k0s.0 \
  -- k0s controller --enable-worker
```

### Step 3: Get Kubeconfig

```bash
# SSH into the controller
flyctl ssh console --app k0s-test-nodes --select

# Inside the machine, get the kubeconfig
k0s kubeconfig admin > /tmp/kubeconfig

# Copy it out (or cat and copy)
cat /tmp/kubeconfig
```

### Step 4: Deploy Alternative UI

```bash
cd src/alternative-ui
flyctl deploy
```

### Step 5: Deploy Collector

```bash
# Export kubeconfig from previous step
export KUBECONFIG=/path/to/kubeconfig

# Apply collector manifests
kubectl apply -f k8s/deploy/manifests.yaml
```

---

## Option C: Local k0s with Fly.io UI (Recommended for Development)

The simplest approach: run k0s locally and only deploy the UI to Fly.io.

### Step 1: Install k0s Locally

```bash
# On Linux
curl -sSLf https://get.k0s.sh | sudo sh
sudo k0s install controller --enable-worker
sudo k0s start
sudo k0s kubeconfig admin > ~/.kube/config
```

### Step 2: Deploy Alternative UI to Fly.io

```bash
cd src/alternative-ui

# Set up authentication
API_KEY=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
echo "Your API key: $API_KEY"

flyctl launch --name netdata-k0s-demo --no-deploy
flyctl secrets set \
  AUTH_USERNAME=admin \
  AUTH_PASSWORD=changeme \
  API_KEY=$API_KEY \
  --app netdata-k0s-demo
flyctl deploy
```

### Step 3: Run Collector Locally

```bash
cd src/alternative-ui/k8s

# Build collector
go build -o k8s-collector .

# Run collector pointing to fly.io UI (use the API_KEY from step 2)
./k8s-collector \
  --url https://netdata-k0s-demo.fly.dev \
  --api-key $API_KEY \
  --cluster-name my-local-k0s \
  --interval 10s
```

---

## Option D: k0s on Hetzner/DigitalOcean (Production-like)

For a more production-like setup, use cheap VPS providers.

### Using k0sctl (Recommended)

```yaml
# k0sctl.yaml
apiVersion: k0sctl.k0sproject.io/v1beta1
kind: Cluster
metadata:
  name: k0s-demo
spec:
  hosts:
    - role: controller+worker
      ssh:
        address: <your-vps-ip>
        user: root
        keyPath: ~/.ssh/id_rsa
  k0s:
    version: 1.29.1+k0s.0
```

```bash
# Install k0s cluster
k0sctl apply --config k0sctl.yaml

# Get kubeconfig
k0sctl kubeconfig --config k0sctl.yaml > ~/.kube/config

# Deploy collector
kubectl apply -f k8s/deploy/manifests.yaml
```

---

## Collector Configuration

The collector supports these environment variables / flags:

| Flag | Env Var | Default | Description |
|------|---------|---------|-------------|
| `-url` | `PUSH_URL` | `http://localhost:19998` | Alternative UI server URL |
| `-cluster-name` | `CLUSTER_NAME` | `kubernetes` | Cluster identifier |
| `-interval` | `INTERVAL` | `10s` | Collection interval |
| `-api-key` | `API_KEY` | `` | API key for authentication |
| `-namespaces` | `NAMESPACES` | `` | Comma-separated namespaces (empty=all) |
| `-kubeconfig` | `KUBECONFIG` | auto | Path to kubeconfig |

---

## k0s-Specific Metrics

When the collector detects a k0s cluster, it collects additional metrics:

### Cluster Topology
- `k0s.cluster.topology` - Controller and worker node counts
- `k0s.nodes.roles` - Node role assignments

### System Components
- `k0s.system.components` - Status of k0s system pods
- `k0s.system.replicas` - Replica counts for system components

### Control Plane
- `k0s.controlplane.cpu` - CPU usage of control plane components
- `k0s.controlplane.memory` - Memory usage of control plane components

### Konnectivity (k0s networking)
- `k0s.konnectivity.status` - Konnectivity agent/server status

### Etcd
- `k0s.etcd.status` - Embedded etcd status
- `k0s.etcd.cpu` - Etcd CPU usage
- `k0s.etcd.memory` - Etcd memory usage

---

## Troubleshooting

### Collector not pushing metrics

1. Check collector logs:
   ```bash
   kubectl logs -n netdata-collector -l app.kubernetes.io/name=netdata-k8s-collector
   ```

2. Verify the PUSH_URL is accessible from the cluster:
   ```bash
   kubectl run -it --rm debug --image=curlimages/curl -- \
     curl -v https://your-app.fly.dev/api/v1/health
   ```

3. Check RBAC permissions:
   ```bash
   kubectl auth can-i list pods --as system:serviceaccount:netdata-collector:k8s-collector
   ```

### No k0s-specific metrics

1. Verify k0s detection:
   ```bash
   kubectl get nodes -o jsonpath='{.items[*].metadata.labels}' | grep k0s
   ```

2. Check for k0s labels on nodes:
   ```bash
   kubectl get nodes --show-labels | grep k0sproject
   ```

### metrics-server not available

k0s includes metrics-server by default. Verify it's running:
```bash
kubectl get pods -n kube-system | grep metrics-server
```

---

## Cleanup

```bash
# Remove collector from cluster
kubectl delete -f k8s/deploy/manifests.yaml

# Destroy fly app
flyctl apps destroy netdata-k0s-demo
```

---

## Development

### Build collector image locally

```bash
cd src/alternative-ui/k8s
docker build -t k8s-collector:dev .
```

### Build UI image locally

```bash
cd src/alternative-ui
docker build -t alternative-ui:dev .
docker run -p 19998:19998 alternative-ui:dev
```

### Test with mock data

```bash
# Push mock metrics (include API key header if authentication is enabled)
curl -X POST http://localhost:19998/api/v1/push \
  -H "Content-Type: application/json" \
  -H "X-API-Key: your-api-key" \
  -d '{
    "node_id": "test-cluster",
    "node_name": "test-cluster",
    "os": "k0s v1.29.0",
    "labels": {"distribution": "k0s"},
    "charts": [{
      "id": "k0s.cluster.topology",
      "title": "k0s Cluster Topology",
      "units": "nodes",
      "dimensions": [
        {"id": "controllers", "name": "Controllers", "value": 1},
        {"id": "workers", "name": "Workers", "value": 2}
      ]
    }],
    "timestamp": '$(date +%s000)'
  }'
```
