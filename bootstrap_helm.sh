#!/usr/bin/env bash
set -euo pipefail

# Point this repo to use .githooks (idempotent)
git config core.hooksPath ".githooks"
echo "Git hooks path set to .githooks (pre-commit installed)"

# === Settings you can tweak ===
CLUSTER_NAME="dev"
INFRA_DIR="$(cd ./infra && pwd)"
KIND_CFG="${INFRA_DIR}/kind-ingress.yaml"

# App deployment
APP_CHART_DIR="${INFRA_DIR}/chart"       
APP_MANIFEST="${INFRA_DIR}/app.yaml"      # Fallback for kubectl apply

# Dashboard unit templates
UNIT_TMPL="${INFRA_DIR}/k8s-dashboard.service.tmpl"
UNIT_OUT="/etc/systemd/system/k8s-dashboard.service"

RUN_AS_USER="${DASHBOARD_USER:-${SUDO_USER:-$(whoami)}}"

say() { printf "\n%s\n" "$1"; }

install_helm() {
  if command -v helm >/dev/null 2>&1; then
    say "Helm already installed"
    return
  fi

  say "Installing Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash
}

create_kind_cluster() {
  if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    say "Creating kind cluster: ${CLUSTER_NAME}"
    kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CFG}"
  else
    say "Kind cluster ${CLUSTER_NAME} already exists"
  fi
}

install_ingress() {
  say "Installing NGINX ingress controller via Helm"

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo update

  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace
}

install_k8s_dashboard() {
  say "Installing Kubernetes Dashboard via Helm"

  helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
  helm repo update

  helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
    --namespace kubernetes-dashboard \
    --create-namespace

  # Configure systemd port-forward
  say "Setting up systemd unit for dashboard port-forward xxx"
# Install systemd unit to keep port-forward alive (optional)
if [[ -f "$UNIT_TMPL" ]]; then
say "Installing systemd unit for Dashboard port-forward (8443:443)..."

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
warn "You can run manually: kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard-kong-proxy 8443:443"
fi

say "Applying admin-user via Helm chart..."
helm upgrade --install dashboard-admin "${INFRA_DIR}/dashboard" --namespace kubernetes-dashboard

}

deploy_app() {
  if [ -d "${APP_CHART_DIR}" ]; then
    say "Deploying app using Helm chart"
    helm upgrade --install myapp "${APP_CHART_DIR}" --namespace default --create-namespace
    say "Deployedd with helm"
  else
    say "Helm chart not found. Falling back to kubectl apply"
    kubectl apply -f "${APP_MANIFEST}"
  fi
}

# === Run sequence ===

install_helm
create_kind_cluster
install_ingress
install_k8s_dashboard
deploy_app

#!/bin/bash

NS="k8s-demo"

echo "Postgres password:"
kubectl get secret postgres-secret -n "$NS" \
  -o jsonpath="{.data.POSTGRES_PASSWORD}" | base64 --decode
echo

echo "Mongo root password:"
kubectl get secret mongo-secret -n "$NS" \
  -o jsonpath="{.data.MONGO_INITDB_ROOT_PASSWORD}" | base64 --decode
echo

echo "Redis password:"
kubectl get secret redis-secret -n "$NS" \
  -o jsonpath="{.data.REDIS_PASSWORD}" | base64 --decode
echo

echo "pgAdmin admin password:"
kubectl get secret pgadmin-secret -n "$NS" \
  -o jsonpath="{.data.PGADMIN_DEFAULT_PASSWORD}" | base64 --decode
echo

# Dashboard token
say "Kubernetes Dashboard token:"
set +e
kubectl -n kubernetes-dashboard create token admin-user 2>/dev/null || \
  echo "Use: kubectl -n kubernetes-dashboard create token admin-user"
set -e

say "Done
- Dashboard: https://<HOST-LAN-IP>:8443
- Ingress: http(s)://<HOST-LAN-IP>:<mapped-port>
"
