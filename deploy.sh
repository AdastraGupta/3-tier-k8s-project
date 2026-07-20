#!/bin/bash
set -e

# ─── Color Variables ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─── Print Helpers ──────────────────────────────────────────────────────────────
print_step()    { echo -e "${BLUE}▶${NC}  $1"; }
print_success() { echo -e "${GREEN}✔${NC}  $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC}  $1"; }
print_error()   { echo -e "${RED}✖${NC}  $1"; }
print_info()    { echo -e "${CYAN}ℹ${NC}  $1"; }
print_wait()    { echo -e "${YELLOW}⏳${NC} $1"; }

# ─── Header Banner ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║        3-Tier Kubernetes Task Manager Deployer          ║${NC}"
echo -e "${BOLD}${CYAN}║        ─────────────────────────────────────            ║${NC}"
echo -e "${BOLD}${CYAN}║   Frontend (Nginx) · Backend (PostgREST) · DB (PG)     ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ─── Configuration ──────────────────────────────────────────────────────────────
NAMESPACE="taskmanager"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
KIND_CONFIG="${SCRIPT_DIR}/kind-config.yaml"
CLUSTER_NAME="taskmanager"
TIMEOUT="120s"

# ─── Verify k8s directory exists ────────────────────────────────────────────────
if [ ! -d "$K8S_DIR" ]; then
    print_error "Kubernetes manifests directory not found at: ${K8S_DIR}"
    print_info  "Make sure the 'k8s/' folder exists alongside this script."
    exit 1
fi

# ─── Cleanup Mode ───────────────────────────────────────────────────────────────
if [ "$1" == "--cleanup" ]; then
    echo -e "${BOLD}${RED}🧹 Cleanup Mode${NC}"
    echo ""
    print_warning "This will delete the entire '${NAMESPACE}' namespace and all its resources."
    print_step "Deleting namespace '${NAMESPACE}'..."
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
    echo ""
    print_success "Cleanup complete. All resources in '${NAMESPACE}' have been removed."
    echo ""
    print_info "To also delete the kind cluster:"
    echo -e "   ${BOLD}kind delete cluster --name ${CLUSTER_NAME}${NC}"
    exit 0
fi

if [ "$1" == "--destroy" ]; then
    echo -e "${BOLD}${RED}💥 Destroy Mode${NC}"
    echo ""
    print_warning "This will delete the entire kind cluster '${CLUSTER_NAME}'."
    print_step "Deleting kind cluster..."
    kind delete cluster --name "$CLUSTER_NAME"
    echo ""
    print_success "Kind cluster '${CLUSTER_NAME}' deleted."
    exit 0
fi

# ─── Pre-flight Checks ─────────────────────────────────────────────────────────
print_step "Running pre-flight checks..."

if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed or not in PATH."
    exit 1
fi

if ! command -v kind &> /dev/null; then
    print_error "kind is not installed or not in PATH."
    print_info  "Install from: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed or not in PATH."
    exit 1
fi

print_success "Pre-flight checks passed."
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
#  KIND CLUSTER SETUP
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "${BOLD}── Step 0a: Kind Cluster ──${NC}"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    print_info "Kind cluster '${CLUSTER_NAME}' already exists. Skipping creation."
else
    print_step "Creating kind cluster '${CLUSTER_NAME}' with port mappings..."
    kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
    print_success "Kind cluster '${CLUSTER_NAME}' created."
fi
echo ""

echo -e "${BOLD}── Step 0b: Nginx Ingress Controller ──${NC}"
print_step "Installing Nginx Ingress Controller for kind..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
print_wait "Waiting for ingress controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout="${TIMEOUT}" 2>/dev/null || true
print_success "Nginx Ingress Controller is ready."
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
#  DEPLOYMENT STEPS
# ═══════════════════════════════════════════════════════════════════════════════

# ── Step 1: Namespace ───────────────────────────────────────────────────────────
echo -e "${BOLD}── Step 1/10: Namespace ──${NC}"
print_step "Creating namespace '${NAMESPACE}'..."
kubectl apply -f "$K8S_DIR/namespace.yaml"
print_success "Namespace '${NAMESPACE}' is ready."
echo ""

# ── Step 2: Secrets ─────────────────────────────────────────────────────────────
echo -e "${BOLD}── Step 2/10: Secrets ──${NC}"
print_step "Applying database secrets..."
kubectl apply -f "$K8S_DIR/secret.yaml"
print_success "Secrets applied."
echo ""

# ── Step 3: ConfigMaps ──────────────────────────────────────────────────────────
echo -e "${BOLD}── Step 3/10: ConfigMaps ──${NC}"
print_step "Applying application and database init ConfigMaps..."
kubectl apply -f "$K8S_DIR/configmap.yaml"
kubectl apply -f "$K8S_DIR/db-init-configmap.yaml"
print_success "ConfigMaps applied."
echo ""

# ── Step 4: Persistent Volume Claim ─────────────────────────────────────────────
echo -e "${BOLD}── Step 4/10: Persistent Storage ──${NC}"
print_step "Creating PersistentVolumeClaim for PostgreSQL..."
kubectl apply -f "$K8S_DIR/postgres-pvc.yaml"
print_success "PVC created."
echo ""

# ── Step 5: Database Tier ───────────────────────────────────────────────────────
echo -e "${BOLD}── Step 5/10: Database Tier (PostgreSQL) ──${NC}"
print_step "Deploying PostgreSQL..."
kubectl apply -f "$K8S_DIR/postgres-deployment.yaml"
kubectl apply -f "$K8S_DIR/postgres-service.yaml"
print_success "PostgreSQL deployment and service applied."
echo ""

# ── Step 6: Wait for Database ───────────────────────────────────────────────────
echo -e "${BOLD}── Step 6/10: Waiting for Database ──${NC}"
print_wait "Waiting for PostgreSQL pod to become ready (timeout: ${TIMEOUT})..."
kubectl wait --for=condition=ready pod -l tier=database -n "$NAMESPACE" --timeout="$TIMEOUT"
print_success "PostgreSQL is ready and accepting connections."
echo ""

# ── Step 7: Backend Tier ────────────────────────────────────────────────────────
echo -e "${BOLD}── Step 7/10: Backend Tier (PostgREST) ──${NC}"
print_step "Deploying PostgREST API server..."
kubectl apply -f "$K8S_DIR/backend-deployment.yaml"
kubectl apply -f "$K8S_DIR/backend-service.yaml"
print_success "Backend deployment and service applied."
echo ""

# ── Step 8: Wait for Backend ───────────────────────────────────────────────────
echo -e "${BOLD}── Step 8/10: Waiting for Backend ──${NC}"
print_wait "Waiting for PostgREST pod to become ready (timeout: ${TIMEOUT})..."
kubectl wait --for=condition=ready pod -l tier=backend -n "$NAMESPACE" --timeout="$TIMEOUT"
print_success "PostgREST API server is ready."
echo ""

# ── Step 9: Frontend Tier ──────────────────────────────────────────────────────
echo -e "${BOLD}── Step 9/10: Frontend Tier (Nginx) ──${NC}"
print_step "Deploying Nginx frontend..."
kubectl apply -f "$K8S_DIR/frontend-configmap.yaml"
kubectl apply -f "$K8S_DIR/frontend-deployment.yaml"
kubectl apply -f "$K8S_DIR/frontend-service.yaml"
print_wait "Waiting for Frontend pod to become ready (timeout: ${TIMEOUT})..."
kubectl wait --for=condition=ready pod -l tier=frontend -n "$NAMESPACE" --timeout="$TIMEOUT"
print_success "Frontend is ready."
echo ""

# ── Step 10: Ingress ───────────────────────────────────────────────────────────
echo -e "${BOLD}── Step 10/10: Ingress ──${NC}"
print_step "Applying Ingress resource..."
kubectl apply -f "$K8S_DIR/ingress.yaml"
print_success "Ingress applied."
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
#  DEPLOYMENT SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║            ✅  Deployment Complete!                      ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Resources deployed in namespace '${NAMESPACE}':${NC}"
echo ""
kubectl get all -n "$NAMESPACE"
echo ""
echo -e "${BOLD}${CYAN}── Access Instructions ──${NC}"
echo ""
print_info "Option 1 — Via Ingress (kind port mapping → localhost:80):"
echo -e "   Open: ${BOLD}${CYAN}http://localhost${NC}"
echo ""
print_info "Option 2 — Port Forward (if port 80 is occupied):"
echo -e "   ${BOLD}kubectl port-forward svc/frontend-svc 8080:80 -n ${NAMESPACE}${NC}"
echo -e "   Then open: ${BOLD}${CYAN}http://localhost:8080${NC}"
echo ""
echo -e "${BOLD}${CYAN}── Quick API Test ──${NC}"
echo ""
echo -e "   ${BOLD}curl http://localhost/api/tasks${NC}"
echo ""
echo -e "${BOLD}${CYAN}── Cleanup ──${NC}"
echo ""
echo -e "   ${BOLD}bash deploy.sh --cleanup${NC}   (removes namespace only)"
echo -e "   ${BOLD}bash deploy.sh --destroy${NC}   (deletes entire kind cluster)"
echo ""
