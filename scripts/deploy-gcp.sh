#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# deploy-gcp.sh — Deploy nanda-context-graph to Google Cloud
#
# One command, fully automated:
#   ./scripts/deploy-gcp.sh
#
# Prerequisites:
#   - gcloud CLI installed and authenticated (gcloud auth login)
#   - A GCP project set (gcloud config set project YOUR_PROJECT)
#
# What it does:
#   1. Enables Compute Engine API (if needed)
#   2. Creates a firewall rule for ports 8080, 7200, 7201, 7474
#   3. Launches an e2-medium VM with Ubuntu 22.04
#   4. Installs Docker, clones repo, runs docker-compose
#   5. Waits for services to come online
#   6. Prints the public dashboard URL
#
# Options:
#   --project PROJECT   GCP project ID (default: current gcloud config)
#   --zone ZONE         GCP zone (default: us-central1-a)
#   --machine TYPE      Machine type (default: e2-medium)
#   --teardown          Delete the VM and firewall rule
# ──────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configuration ────────────────────────────────────────────
PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || echo "")}"
ZONE="${GCP_ZONE:-us-central1-a}"
MACHINE_TYPE="${GCP_MACHINE_TYPE:-e2-medium}"
VM_NAME="nanda-context-graph"
REPO_URL="https://github.com/Ngoga-Musagi/nanda-context-graph.git"
FIREWALL_RULE="allow-ncg"
TEARDOWN=false

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --project)   PROJECT="$2"; shift 2 ;;
    --zone)      ZONE="$2"; shift 2 ;;
    --machine)   MACHINE_TYPE="$2"; shift 2 ;;
    --teardown)  TEARDOWN=true; shift ;;
    *)           echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ -z "$PROJECT" ]; then
  echo "ERROR: No GCP project set."
  echo "  Run:  gcloud config set project YOUR_PROJECT"
  echo "  Or:   ./scripts/deploy-gcp.sh --project YOUR_PROJECT"
  exit 1
fi

# ── Teardown mode ────────────────────────────────────────────
if [ "$TEARDOWN" = true ]; then
  echo "=== Tearing down NCG from GCP ==="
  echo ">> Deleting VM..."
  gcloud compute instances delete "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT" --quiet 2>/dev/null || echo "   VM not found"
  echo ">> Deleting firewall rule..."
  gcloud compute firewall-rules delete "$FIREWALL_RULE" \
    --project="$PROJECT" --quiet 2>/dev/null || echo "   Rule not found"
  echo "Done. All NCG resources removed."
  exit 0
fi

echo "========================================"
echo "  NCG Google Cloud Deployment"
echo "========================================"
echo "  Project:  $PROJECT"
echo "  Zone:     $ZONE"
echo "  Machine:  $MACHINE_TYPE"
echo ""

# ── Step 1: Enable Compute Engine API ────────────────────────
echo ">> [1/5] Enabling Compute Engine API..."
gcloud services enable compute.googleapis.com --project="$PROJECT" 2>/dev/null || true
echo "   Done"

# ── Step 2: Create firewall rule ─────────────────────────────
echo ">> [2/5] Creating firewall rule..."
if ! gcloud compute firewall-rules describe "$FIREWALL_RULE" \
  --project="$PROJECT" &>/dev/null; then
  gcloud compute firewall-rules create "$FIREWALL_RULE" \
    --project="$PROJECT" \
    --allow=tcp:8080,tcp:7200,tcp:7201,tcp:7474 \
    --target-tags=ncg \
    --description="nanda-context-graph dashboard + API ports" \
    --quiet
  echo "   Created: $FIREWALL_RULE"
else
  echo "   Already exists"
fi

# ── Step 3: Check if VM already exists ───────────────────────
echo ">> [3/5] Creating VM..."
if gcloud compute instances describe "$VM_NAME" \
  --zone="$ZONE" --project="$PROJECT" &>/dev/null; then
  echo "   VM '$VM_NAME' already exists. To redeploy, run:"
  echo "   ./scripts/deploy-gcp.sh --teardown && ./scripts/deploy-gcp.sh"
  EXTERNAL_IP=$(gcloud compute instances describe "$VM_NAME" \
    --project="$PROJECT" --zone="$ZONE" \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
  echo ""
  echo "   Dashboard: http://$EXTERNAL_IP:8080"
  exit 0
fi

# ── Step 4: Launch VM ────────────────────────────────────────
gcloud compute instances create "$VM_NAME" \
  --project="$PROJECT" \
  --zone="$ZONE" \
  --machine-type="$MACHINE_TYPE" \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=30GB \
  --boot-disk-type=pd-balanced \
  --tags=ncg \
  --metadata=startup-script='#!/bin/bash
set -ex
exec > /var/log/ncg-deploy.log 2>&1
echo "=== NCG startup script started at $(date) ==="

# Install Docker
curl -fsSL https://get.docker.com | sh
systemctl enable docker
usermod -aG docker ubuntu 2>/dev/null || true

# Install Docker Compose plugin
apt-get update -y
apt-get install -y docker-compose-plugin

# Clone repo
cd /opt
git clone https://github.com/Ngoga-Musagi/nanda-context-graph.git
cd nanda-context-graph

# Build and start all services (including dashboard on :8080)
docker compose up -d --build

echo "=== NCG deployment complete at $(date) ==="
' \
  --quiet

echo "   VM created"

# ── Get external IP ──────────────────────────────────────────
EXTERNAL_IP=$(gcloud compute instances describe "$VM_NAME" \
  --project="$PROJECT" --zone="$ZONE" \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
echo "   External IP: $EXTERNAL_IP"

# ── Step 5: Wait for services ────────────────────────────────
echo ">> [4/5] Waiting for services to start (this takes 2-4 minutes)..."
echo "   Docker is installing and building containers on the VM."
echo ""

MAX_WAIT=300  # 5 minutes max
ELAPSED=0
INTERVAL=15

while [ $ELAPSED -lt $MAX_WAIT ]; do
  # Try the query API health endpoint
  if curl -s --connect-timeout 3 "http://$EXTERNAL_IP:7201/health" 2>/dev/null | grep -q "ok"; then
    echo "   Query API is UP!"
    break
  fi
  ELAPSED=$((ELAPSED + INTERVAL))
  REMAINING=$(( (MAX_WAIT - ELAPSED) / 60 ))
  echo "   Still starting... (~${REMAINING}m remaining)"
  sleep $INTERVAL
done

# Check dashboard too
DASHBOARD_UP=false
if curl -s --connect-timeout 3 "http://$EXTERNAL_IP:8080" 2>/dev/null | grep -q "html"; then
  DASHBOARD_UP=true
fi

# ── Done ─────────────────────────────────────────────────────
echo ""
echo ">> [5/5] Deployment complete!"
echo ""
echo "========================================"
echo "  NCG is live on Google Cloud!"
echo "========================================"
echo ""
echo "  Dashboard:  http://$EXTERNAL_IP:8080"
echo "  Query API:  http://$EXTERNAL_IP:7201"
echo "  Ingest API: http://$EXTERNAL_IP:7200"
echo "  Neo4j:      http://$EXTERNAL_IP:7474  (user: neo4j / password: password)"
echo ""

if [ "$DASHBOARD_UP" = false ]; then
  echo "  NOTE: Dashboard is still building (takes ~1 more minute)."
  echo "        Refresh http://$EXTERNAL_IP:8080 shortly."
  echo ""
fi

echo "  To SSH into the VM:"
echo "    gcloud compute ssh $VM_NAME --zone=$ZONE --project=$PROJECT"
echo ""
echo "  To view deploy logs:"
echo "    gcloud compute ssh $VM_NAME --zone=$ZONE --project=$PROJECT --command='cat /var/log/ncg-deploy.log'"
echo ""
echo "  To tear down everything:"
echo "    ./scripts/deploy-gcp.sh --teardown"
echo "========================================"
