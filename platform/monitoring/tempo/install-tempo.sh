#!/usr/bin/env bash
# =============================================================================
# install-tempo.sh — OmniPay Zero-Trust | P5 Semaine 3 (S3)
# Déploiement reproductible de Grafana Tempo sur cluster K3s
# =============================================================================
set -euo pipefail

NAMESPACE="monitoring"
RELEASE_NAME="tempo"
CHART_VERSION="1.10.3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/values-tempo.yaml"
DATASOURCE_FILE="${SCRIPT_DIR}/datasource-tempo.yaml"

echo "============================================================"
echo "  OmniPay Zero-Trust — Déploiement Tracing Tempo (S3 P5)   "
echo "============================================================"

# --- 1. Vérification des prérequis ---
echo "[1/5] Vérification des outils requis (helm, kubectl)..."
command -v helm >/dev/null 2>&1 || { echo "ERREUR: helm est requis mais non installé."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERREUR: kubectl est requis mais non installé."; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "ERREUR: Impossible de joindre le cluster K3s."; exit 1; }
echo "  ✅ Prérequis validés."

# --- 2. Ajout du dépôt Helm Grafana ---
echo "[2/5] Mise à jour du dépôt Helm Grafana..."
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update grafana
echo "  ✅ Dépôt Grafana prêt."

# --- 3. Namespace monitoring ---
echo "[3/5] Vérification du namespace ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
echo "  ✅ Namespace ${NAMESPACE} prêt."

# --- 4. Déploiement de Tempo ---
echo "[4/5] Déploiement / Mise à jour de Grafana Tempo..."
if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "  ♻️  Release '${RELEASE_NAME}' existante — mise à niveau (helm upgrade)..."
  helm upgrade "${RELEASE_NAME}" grafana/tempo \
    --namespace "${NAMESPACE}" \
    --version "${CHART_VERSION}" \
    --values "${VALUES_FILE}" \
    --timeout 5m \
    --atomic
else
  echo "  🆕 Installation initiale de '${RELEASE_NAME}'..."
  helm install "${RELEASE_NAME}" grafana/tempo \
    --namespace "${NAMESPACE}" \
    --version "${CHART_VERSION}" \
    --values "${VALUES_FILE}" \
    --timeout 5m \
    --atomic
fi

# Application de la datasource Grafana
if [[ -f "${DATASOURCE_FILE}" ]]; then
  echo "  🔗 Application de la ConfigMap datasource Tempo pour Grafana..."
  kubectl apply -f "${DATASOURCE_FILE}" -n "${NAMESPACE}"
fi

# --- 5. Validation de l'état des pods ---
echo "[5/5] Attente de la disponibilité opérationnelle du pod Tempo..."
kubectl rollout status statefulset "${RELEASE_NAME}" -n "${NAMESPACE}" --timeout=180s 2>/dev/null || \
kubectl wait --for=condition=ready pod -n "${NAMESPACE}" -l "app.kubernetes.io/name=tempo" --timeout=180s

echo ""
echo "============================================================"
echo "  ✅ Grafana Tempo déployé avec succès !"
echo ""
echo "  Endpoints internes du cluster :"
echo "    - OTLP gRPC : tempo.${NAMESPACE}.svc.cluster.local:4317"
echo "    - OTLP HTTP : http://tempo.${NAMESPACE}.svc.cluster.local:4318/v1/traces"
echo "    - Jaeger    : tempo.${NAMESPACE}.svc.cluster.local:14268"
echo "    - Tempo API : http://tempo.${NAMESPACE}.svc.cluster.local:3100"
echo "============================================================"
