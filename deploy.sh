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
echo -e "${BOLD}${CYAN}║              ✦ GitOps powered by ArgoCD ✦               ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ─── Configuration ──────────────────────────────────────────────────────────────
NAMESPACE="taskmanager"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
KIND_CONFIG="${SCRIPT_DIR}/kind-config.yaml"
CLUSTER_NAME="taskmanager"
TIMEOUT="120s"
ARGOCD_VERSION="v2.11.3"  # ArgoCD release to install

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
    print_warning "This will delete the ArgoCD Application and the '${NAMESPACE}' namespace."
    print_step "Deleting ArgoCD Application 'taskmanager'..."
    kubectl delete application taskmanager -n argocd --ignore-not-found=true
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
#  GITOPS SETUP — ArgoCD Installation & Bootstrap
# ═══════════════════════════════════════════════════════════════════════════════

# ── Step 1: ArgoCD Namespace ────────────────────────────────────────────────────
echo -e "${BOLD}── Step 1/4: ArgoCD Namespace ──${NC}"
print_step "Creating argocd namespace..."
kubectl apply -f "$K8S_DIR/argocd-namespace.yaml"
print_success "ArgoCD namespace is ready."
echo ""

# ── Step 2: Install ArgoCD ──────────────────────────────────────────────────────
echo -e "${BOLD}── Step 2/4: Install ArgoCD ──${NC}"
print_step "Installing ArgoCD ${ARGOCD_VERSION}..."
kubectl apply -n argocd -f \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
echo ""
print_wait "Waiting for ArgoCD server to be ready (timeout: ${TIMEOUT})..."
kubectl wait --for=condition=available deployment/argocd-server \
  -n argocd --timeout="${TIMEOUT}" 2>/dev/null || \
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout="${TIMEOUT}"
print_success "ArgoCD server is ready."
echo ""

# ── Step 3: Bootstrap ArgoCD Application ────────────────────────────────────────
echo -e "${BOLD}── Step 3/4: Bootstrap Application ──${NC}"
print_step "Applying ArgoCD Application manifest (taskmanager)..."
kubectl apply -f "$K8S_DIR/argocd-app.yaml"
print_success "ArgoCD Application 'taskmanager' created."
print_info  "ArgoCD will now sync all manifests from Git → cluster automatically."
echo ""

# ── Step 4: Wait for Initial Sync ───────────────────────────────────────────────
echo -e "${BOLD}── Step 4/4: Waiting for Initial Sync ──${NC}"
print_wait "Waiting for ArgoCD to sync the application (this may take 2-3 minutes)..."
SYNC_TIMEOUT=300
ELAPSED=0
INTERVAL=10
while [ $ELAPSED -lt $SYNC_TIMEOUT ]; do
    SYNC_STATUS=$(kubectl get application taskmanager -n argocd \
        -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    HEALTH_STATUS=$(kubectl get application taskmanager -n argocd \
        -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

    if [ "$SYNC_STATUS" = "Synced" ] && [ "$HEALTH_STATUS" = "Healthy" ]; then
        print_success "Application is Synced and Healthy! ✅"
        break
    fi

    echo -e "   ${YELLOW}Sync: ${SYNC_STATUS} | Health: ${HEALTH_STATUS}${NC} — waiting..."
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $SYNC_TIMEOUT ]; then
    print_warning "Sync is taking longer than expected. Check ArgoCD UI for details."
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
#  DEPLOYMENT SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

# Retrieve ArgoCD admin password
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "<run: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d>")

echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║         ✅  GitOps Bootstrap Complete!                   ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Resources in namespace '${NAMESPACE}' (synced by ArgoCD):${NC}"
echo ""
kubectl get all -n "$NAMESPACE" 2>/dev/null || print_info "Resources are still syncing..."
echo ""
echo -e "${BOLD}${CYAN}── ArgoCD UI ──${NC}"
echo ""
print_info "Port-forward the ArgoCD server:"
echo -e "   ${BOLD}kubectl port-forward svc/argocd-server 8080:443 -n argocd${NC}"
echo -e "   Then open: ${BOLD}${CYAN}https://localhost:8080${NC}"
echo ""
echo -e "   Username: ${BOLD}admin${NC}"
echo -e "   Password: ${BOLD}${ARGOCD_PASSWORD}${NC}"
echo ""
echo -e "${BOLD}${CYAN}── App Access ──${NC}"
echo ""
print_info "Option 1 — Via Ingress (kind port mapping):"
echo -e "   Open: ${BOLD}${CYAN}http://localhost${NC}"
echo ""
print_info "Option 2 — Port Forward (if port 80 is occupied):"
echo -e "   ${BOLD}kubectl port-forward svc/frontend-svc 8081:80 -n ${NAMESPACE}${NC}"
echo -e "   Then open: ${BOLD}${CYAN}http://localhost:8081${NC}"
echo ""
echo -e "${BOLD}${CYAN}── GitOps Workflow ──${NC}"
echo ""
echo -e "   Edit any file in ${BOLD}k8s/${NC}  →  ${BOLD}git commit & push${NC}  →  ArgoCD auto-syncs ✅"
echo ""
echo -e "${BOLD}${CYAN}── Quick API Test ──${NC}"
echo ""
echo -e "   ${BOLD}curl http://localhost/api/tasks${NC}"
echo ""
echo -e "${BOLD}${CYAN}── Cleanup ──${NC}"
echo ""
echo -e "   ${BOLD}bash deploy.sh --cleanup${NC}   (removes ArgoCD app + taskmanager namespace)"
echo -e "   ${BOLD}bash deploy.sh --destroy${NC}   (deletes entire kind cluster)"
echo ""
