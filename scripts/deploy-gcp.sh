#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# deploy-gcp.sh — Deploy nanda-context-graph to Google Cloud
#
# Prerequisites:
#   - gcloud CLI installed and authenticated (gcloud auth login)
#   - A GCP project set (gcloud config set project YOUR_PROJECT)
#   - Compute Engine API enabled
#
# Usage:
#   chmod +x scripts/deploy-gcp.sh
#   ./scripts/deploy-gcp.sh                      # uses defaults
#   ./scripts/deploy-gcp.sh --project my-proj     # custom project
#
# What it does:
#   1. Creates a firewall rule for ports 8080, 7200, 7201
#   2. Launches an e2-medium VM with Ubuntu 22.04
#   3. Installs Docker, clones repo, starts docker-compose
#   4. Prints the public URL for the dashboard
# ──────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configuration ────────────────────────────────────────────
PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
ZONE="${GCP_ZONE:-us-central1-a}"
MACHINE_TYPE="${GCP_MACHINE_TYPE:-e2-medium}"
VM_NAME="nanda-context-graph"
REPO_URL="https://github.com/Ngoga-Musagi/nanda-context-graph.git"
FIREWALL_RULE="allow-ncg"

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --project)  PROJECT="$2"; shift 2 ;;
    --zone)     ZONE="$2"; shift 2 ;;
    --machine)  MACHINE_TYPE="$2"; shift 2 ;;
    *)          echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ -z "$PROJECT" ]; then
  echo "ERROR: No GCP project set. Run: gcloud config set project YOUR_PROJECT"
  exit 1
fi

echo "=== NCG Google Cloud Deployment ==="
echo "Project:  $PROJECT"
echo "Zone:     $ZONE"
echo "Machine:  $MACHINE_TYPE"
echo ""

# ── Create firewall rule ─────────────────────────────────────
echo ">> Creating firewall rule..."
if ! gcloud compute firewall-rules describe "$FIREWALL_RULE" \
  --project="$PROJECT" &>/dev/null; then
  gcloud compute firewall-rules create "$FIREWALL_RULE" \
    --project="$PROJECT" \
    --allow=tcp:8080,tcp:7200,tcp:7201,tcp:7474 \
    --target-tags=ncg \
    --description="nanda-context-graph dashboard + API ports"
  echo "   Created firewall rule: $FIREWALL_RULE"
else
  echo "   Firewall rule already exists"
fi

# ── Startup script ───────────────────────────────────────────
STARTUP_SCRIPT=$(cat <<STARTUP
#!/bin/bash
set -ex

# Install Docker
curl -fsSL https://get.docker.com | sh
systemctl enable docker

# Install Docker Compose plugin
apt-get update -y
apt-get install -y docker-compose-plugin

# Clone and start
cd /opt
git clone $REPO_URL nanda-context-graph
cd nanda-context-graph
docker compose up -d --build

echo "NCG deployment complete at \$(date)" >> /var/log/ncg-deploy.log
STARTUP
)

# ── Create VM ────────────────────────────────────────────────
echo ">> Creating VM instance..."
gcloud compute instances create "$VM_NAME" \
  --project="$PROJECT" \
  --zone="$ZONE" \
  --machine-type="$MACHINE_TYPE" \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=30GB \
  --boot-disk-type=pd-balanced \
  --tags=ncg \
  --metadata=startup-script="$STARTUP_SCRIPT"

# ── Get external IP ──────────────────────────────────────────
echo ">> Fetching external IP..."
EXTERNAL_IP=$(gcloud compute instances describe "$VM_NAME" \
  --project="$PROJECT" \
  --zone="$ZONE" \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)')

echo ""
echo "========================================"
echo "  NCG deployed to Google Cloud!"
echo "========================================"
echo ""
echo "  Dashboard:  http://$EXTERNAL_IP:8080"
echo "  Query API:  http://$EXTERNAL_IP:7201"
echo "  Ingest API: http://$EXTERNAL_IP:7200"
echo "  Neo4j:      http://$EXTERNAL_IP:7474"
echo ""
echo "  SSH:  gcloud compute ssh $VM_NAME --zone=$ZONE --project=$PROJECT"
echo ""
echo "  NOTE: Services take ~2-3 minutes to start after boot."
echo "        Check progress: SSH in, then: tail -f /var/log/ncg-deploy.log"
echo ""
echo "  To tear down:"
echo "    gcloud compute instances delete $VM_NAME --zone=$ZONE --project=$PROJECT"
echo "    gcloud compute firewall-rules delete $FIREWALL_RULE --project=$PROJECT"
echo "========================================"
