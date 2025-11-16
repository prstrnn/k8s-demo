#!/usr/bin/env bash
set -euo pipefail

# Point this repo to use .githooks (idempotent)
git config core.hooksPath ".githooks"
echo "✅ Git hooks path set to .githooks (pre-commit installed)"

# === Settings you can tweak ===
CLUSTER_NAME="dev"
INFRA_DIR="$(cd ./infra && pwd)"
KIND_CFG="${INFRA_DIR}/kind-ingress.yaml"
UNIT_TMPL="${INFRA_DIR}/k8s-dashboard.service.tmpl"
UNIT_OUT="/etc/systemd/system/k8s-dashboard.service"
APP_TMPL="${INFRA_DIR}/app.yaml.tmpl"
APP_MANIFEST="${INFRA_DIR}/app.yaml"
# Dashboard will be proxied at https://<HOST-IP>:9443 by the systemd unit

# pick the user to run as:
# - If script is run with sudo, prefer the invoking user ($SUDO_USER)
# - Otherwise, use the current user
RUN_AS_USER="${DASHBOARD_USER:-${SUDO_USER:-$(whoami)}}"

# === Helpers ===
need_cmd() { command -v "$1" >/dev/null 2>&1; }
say() { printf '\n\033[1;32m%s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m%s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m%s\033[0m\n' "$*"; exit 1; }

# Detect arch for kubectl/kind
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) KARCH="amd64"; KIND_ARCH="amd64" ;;
  aarch64|arm64) KARCH="arm64"; KIND_ARCH="arm64" ;;
  *) die "Unsupported CPU arch: $ARCH";;
esac

# Require docker
need_cmd docker || die "Docker not found. Install Docker and re-run."

# Install kubectl if missing
if ! need_cmd kubectl; then
  say "Installing kubectl..."
  TMP="$(mktemp -d)"
  # Fetch latest stable kubectl
  KVER="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
  curl -L -o "${TMP}/kubectl" "https://dl.k8s.io/release/${KVER}/bin/linux/${KARCH}/kubectl"
  chmod +x "${TMP}/kubectl"
  sudo mv "${TMP}/kubectl" /usr/local/bin/kubectl
  rm -rf "${TMP}"
else
  say "kubectl already installed: $(kubectl version --client --short 2>/dev/null || echo found)"
fi

# Install kind if missing
if ! need_cmd kind; then
  say "Installing kind..."
  TMP="$(mktemp -d)"
  # Pin a widely-used recent version for reproducibility
  KIND_VER="v0.23.0"
  curl -L -o "${TMP}/kind" "https://kind.sigs.k8s.io/dl/${KIND_VER}/kind-linux-${KIND_ARCH}"
  chmod +x "${TMP}/kind"
  sudo mv "${TMP}/kind" /usr/local/bin/kind
  rm -rf "${TMP}"
else
  say "kind already installed: $(kind --version)"
fi

# Check infra files
[[ -f "$KIND_CFG" ]] || die "Missing ${KIND_CFG}"
[[ -f "$APP_TMPL" ]] || die "Missing ${APP_TMPL}"
[[ -f "$UNIT_TMPL" ]] || warn "No ${UNIT_TMPL} found (systemd unit is optional)"

# Create kind cluster if needed
if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  say "kind cluster '${CLUSTER_NAME}' already exists. Skipping creation."
else
  say "Creating kind cluster '${CLUSTER_NAME}' with ${KIND_CFG}..."
  kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CFG"
fi

# Set KUBECONFIG context to this cluster
kubectl cluster-info >/dev/null
# Wait for core components
say "Waiting for core pods in kube-system to be Ready..."
kubectl wait -n kube-system --for=condition=Ready pods --all --timeout=180s || true

# ======================
# ingress-nginx (kind provider) — CHECK BEFORE INSTALL
# ======================
ING_NS="ingress-nginx"
ING_DEP="ingress-nginx-controller"
ING_INSTALLED=false

if kubectl get ns "${ING_NS}" >/dev/null 2>&1; then
  if kubectl -n "${ING_NS}" get deploy "${ING_DEP}" >/dev/null 2>&1; then
    say "ingress-nginx already installed. Verifying rollout..."
    kubectl -n "${ING_NS}" rollout status deploy/"${ING_DEP}" --timeout=180s || true
    ING_INSTALLED=true
  fi
fi

if [[ "${ING_INSTALLED}" = false ]]; then
  say "Installing ingress-nginx (kind provider)..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
  say "Waiting for ingress-nginx controller to be Ready..."
  kubectl -n "${ING_NS}" rollout status deploy/"${ING_DEP}" --timeout=300s
fi



# ======================
# Kubernetes Dashboard — CHECK BEFORE INSTALL
# ======================
DASH_NS="kubernetes-dashboard"
DASH_SVC="kubernetes-dashboard"
DASH_DEP="kubernetes-dashboard"
DASH_INSTALLED=false
DASHBOARD_VER="v2.7.0"

if kubectl get ns "${DASH_NS}" >/dev/null 2>&1; then
  if kubectl -n "${DASH_NS}" get deploy "${DASH_DEP}" >/dev/null 2>&1; then
    say "Kubernetes Dashboard already installed. Verifying rollout..."
    kubectl -n "${DASH_NS}" rollout status deploy/"${DASH_DEP}" --timeout=180s || true
    DASH_INSTALLED=true
  fi
fi

if [[ "${DASH_INSTALLED}" = false ]]; then
  say "Installing Kubernetes Dashboard (${DASHBOARD_VER})..."
  kubectl apply -f "https://raw.githubusercontent.com/kubernetes/dashboard/${DASHBOARD_VER}/aio/deploy/recommended.yaml"
  say "Waiting for Dashboard to be Ready..."
  kubectl -n "${DASH_NS}" rollout status deploy/"${DASH_DEP}" --timeout=300s
fi

# Admin SA + binding (idempotent)
if ! kubectl -n "${DASH_NS}" get sa admin-user >/dev/null 2>&1; then
  kubectl -n "${DASH_NS}" create serviceaccount admin-user
fi
if ! kubectl get clusterrolebinding admin-user-binding >/dev/null 2>&1; then
  kubectl create clusterrolebinding admin-user-binding \
    --clusterrole=cluster-admin \
    --serviceaccount="${DASH_NS}:admin-user"
fi

# Create admin ServiceAccount + ClusterRoleBinding (idempotent)
if ! kubectl -n kubernetes-dashboard get sa admin-user >/dev/null 2>&1; then
  kubectl -n kubernetes-dashboard create serviceaccount admin-user
fi
if ! kubectl get clusterrolebinding admin-user-binding >/dev/null 2>&1; then
  kubectl create clusterrolebinding admin-user-binding \
    --clusterrole=cluster-admin \
    --serviceaccount=kubernetes-dashboard:admin-user
fi

# Install systemd unit to keep port-forward alive (optional)
if [[ -f "$UNIT_TMPL" ]]; then
  say "Installing systemd unit for Dashboard port-forward (9443:443)..."

  # render template → systemd location (use sudo for system path)
  sudo sh -c "sed -e 's|__USER__|${RUN_AS_USER}|g' '${UNIT_TMPL}' > '${UNIT_OUT}'"

  # Substitute full path to kubectl if the unit uses a generic name (optional robustness)
  KBIN="$(command -v kubectl)"
  # Ensure ExecStart points to a valid kubectl; if not, user can edit their unit file
  sudo systemctl daemon-reload
  sudo systemctl enable k8s-dashboard.service
  sudo systemctl restart k8s-dashboard.service
  sleep 2
  sudo systemctl --no-pager --full status k8s-dashboard.service || true
else
  warn "Skipping systemd unit install; ${UNIT_OUT} not present."
  warn "You can run manually: kubectl -n kubernetes-dashboard port-forward --address=0.0.0.0 svc/kubernetes-dashboard 9443:443"
fi

# Prompt or take from env
POSTGRES_PASS="${POSTGRES_PASS:-$(openssl rand -hex 16)}"
PGADMIN_PASS="${PGADMIN_PASS:-$(openssl rand -hex 16)}"
MONGO_PASS="${MONGO_PASS:-$(openssl rand -hex 16)}"
REDIS_PASS="${REDIS_PASS:-$(openssl rand -hex 16)}"

# Substitute
sed -e "s|<postgres-password>|${POSTGRES_PASS}|g" \
    -e "s|<postgres-ui-password>|${PGADMIN_PASS}|g" \
    -e "s|<mongo-password>|${MONGO_PASS}|g" \
    -e "s|<redis-password>|${REDIS_PASS}|g" \
    "$APP_TMPL" > "$APP_MANIFEST"

# Apply your app
say "Applying ${APP_MANIFEST} ..."
kubectl apply -f "$APP_MANIFEST"

# Optional: wait for your common workloads to come up (best-effort)
say "Waiting for workloads (best-effort)..."
# Adjust labels/namespaces to your manifests if needed
kubectl get ns k8s-demo >/dev/null 2>&1 && {
  kubectl wait -n k8s-demo --for=condition=Ready pods --all --timeout=240s || true
}

# Print Dashboard access info
say "Kubernetes Dashboard token (save this):"
set +e
kubectl -n kubernetes-dashboard create token admin-user 2>/dev/null || \
  echo "Use: kubectl -n kubernetes-dashboard create token admin-user"
set -e

say "Done ✅
- Dashboard (via systemd port-forward): https://<HOST-LAN-IP>:9443
- Ingress (per your kind-ingress.yaml mappings): use http(s)://<HOST-LAN-IP>:<mapped-port>
- Your app was applied from: ${APP_MANIFEST}
"
