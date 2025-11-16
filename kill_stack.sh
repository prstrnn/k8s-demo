#!/usr/bin/env bash
set -euo pipefail

echo "[*] Removing kind clusters..."
kind get clusters | xargs -r -L1 kind delete cluster --name

echo "[*] Removing leftover Kubernetes state..."
sudo rm -rf /etc/kubernetes || true
sudo rm -rf /var/lib/etcd || true
sudo rm -rf /var/lib/kubelet || true
rm -rf ~/.kube || true

echo "[*] Removing kind Docker containers..."
docker ps -a --format '{{.ID}} {{.Image}}' \
  | grep 'kindest/node' \
  | awk '{print $1}' \
  | xargs -r docker rm -f

echo "[*] Cleanup done without touching your other containers."
