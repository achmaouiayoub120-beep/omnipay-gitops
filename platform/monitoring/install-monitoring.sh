#!/usr/bin/env bash
# =============================================================================
# install-monitoring.sh — OmniPay Zero-Trust | P5 Semaine 2
# Déploiement automatisé de kube-prometheus-stack sur K3s
# =============================================================================
set -euo pipefail

NAMESPACE="monitoring"
RELEASE_NAME="kube-prometheus-stack"
CHART_VERSION="61.3.2"
VALUES_FILE="$(dirname "$0")/values-prometheus.yaml"
SERVICEMONITOR_FILE="$(dirname "$0")/servicemonitor-omnipay.yaml"

echo "======================================================"
echo "  OmniPay Zero-Trust — Déploiement Observabilité S2  "
echo "======================================================"

# --- 1. Vérification des prérequis ---
echo "[1/6] Vérification des prérequis..."
command -v helm  >/dev/null 2>&1 || { echo "ERREUR: helm non installé."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERREUR: kubectl non installé."; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "ERREUR: Impossible de joindre le cluster K3s."; exit 1; }
echo "  ✅ Prérequis OK"

# --- 2. Ajout du repo Helm ---
echo "[2/6] Ajout du repo prometheus-community..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update
echo "  ✅ Repo Helm à jour"

# --- 3. Création du namespace ---
echo "[3/6] Création du namespace $NAMESPACE..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
echo "  ✅ Namespace $NAMESPACE prêt"

# --- 4. Installation / Mise à jour kube-prometheus-stack ---
echo "[4/6] Déploiement kube-prometheus-stack (version $CHART_VERSION)..."
if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "  ♻️  Release existante — mise à jour (helm upgrade)..."
  helm upgrade "$RELEASE_NAME" prometheus-community/kube-prometheus-stack \
    --namespace "$NAMESPACE" \
    --version "$CHART_VERSION" \
    --values "$VALUES_FILE" \
    --timeout 10m \
    --atomic \
    --cleanup-on-fail
else
  echo "  🆕 Nouvelle installation (helm install)..."
  helm install "$RELEASE_NAME" prometheus-community/kube-prometheus-stack \
    --namespace "$NAMESPACE" \
    --version "$CHART_VERSION" \
    --values "$VALUES_FILE" \
    --timeout 10m \
    --atomic \
    --cleanup-on-fail
fi
echo "  ✅ kube-prometheus-stack déployé"

# --- 5. Application du ServiceMonitor ---
echo "[5/6] Application du ServiceMonitor OmniPay..."
kubectl apply -f "$SERVICEMONITOR_FILE" -n "$NAMESPACE"
echo "  ✅ ServiceMonitor appliqué"

# --- 6. Attente de la disponibilité des pods ---
echo "[6/6] Attente disponibilité Prometheus et Grafana..."

echo "  ⏳ Prometheus StatefulSet..."
kubectl rollout status statefulset -n "$NAMESPACE" -l "app.kubernetes.io/name=prometheus" --timeout=300s 2>/dev/null || \
  kubectl wait --for=condition=ready pod -n "$NAMESPACE" -l "app.kubernetes.io/name=prometheus" --timeout=300s

echo "  ⏳ Grafana Deployment..."
kubectl rollout status deployment -n "$NAMESPACE" -l "app.kubernetes.io/name=grafana" --timeout=300s 2>/dev/null || \
  kubectl wait --for=condition=ready pod -n "$NAMESPACE" -l "app.kubernetes.io/name=grafana" --timeout=300s

echo ""
echo "======================================================"
echo "  ✅ Déploiement TERMINÉ avec succès !"
echo ""
echo "  Accès Grafana     : http://<NODE_IP>:30300"
echo "  Accès Prometheus  : http://<NODE_IP>:30900"
echo "  Login Grafana     : admin / GrafanaOmniPay2026!"
echo "======================================================"
