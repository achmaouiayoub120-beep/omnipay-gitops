#!/usr/bin/env bash
# =============================================================================
# install-loki.sh — OmniPay Zero-Trust | P5 Semaine 2
# Déploiement Grafana Loki + Promtail dans le namespace monitoring
# =============================================================================
set -euo pipefail

NAMESPACE="monitoring"
LOKI_RELEASE="loki"
PROMTAIL_RELEASE="promtail"
LOKI_VERSION="6.6.2"
PROMTAIL_VERSION="6.16.4"
SCRIPT_DIR="$(dirname "$0")"

echo "======================================================"
echo "  OmniPay — Déploiement Loki + Promtail (Logs S2)"
echo "======================================================"

echo "[1/5] Vérification prérequis..."
command -v helm    >/dev/null 2>&1 || { echo "ERREUR: helm manquant."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERREUR: kubectl manquant."; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "ERREUR: Cluster inaccessible."; exit 1; }
echo "  OK"

echo "[2/5] Repo Helm grafana..."
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update
echo "  OK"

echo "[3/5] Déploiement Grafana Loki (SingleBinary)..."
if helm status "${LOKI_RELEASE}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "  Mise à jour Loki existant..."
  helm upgrade "${LOKI_RELEASE}" grafana/loki \
    --namespace "${NAMESPACE}" \
    --version "${LOKI_VERSION}" \
    --values "${SCRIPT_DIR}/values-loki.yaml" \
    --timeout 5m \
    --atomic
else
  echo "  Nouvelle installation Loki..."
  helm install "${LOKI_RELEASE}" grafana/loki \
    --namespace "${NAMESPACE}" \
    --version "${LOKI_VERSION}" \
    --values "${SCRIPT_DIR}/values-loki.yaml" \
    --timeout 5m \
    --atomic
fi
echo "  OK Loki déployé"

echo "[4/5] Déploiement Promtail (DaemonSet)..."
if helm status "${PROMTAIL_RELEASE}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "  Mise à jour Promtail existant..."
  helm upgrade "${PROMTAIL_RELEASE}" grafana/promtail \
    --namespace "${NAMESPACE}" \
    --version "${PROMTAIL_VERSION}" \
    --values "${SCRIPT_DIR}/values-promtail.yaml" \
    --timeout 5m \
    --atomic
else
  echo "  Nouvelle installation Promtail..."
  helm install "${PROMTAIL_RELEASE}" grafana/promtail \
    --namespace "${NAMESPACE}" \
    --version "${PROMTAIL_VERSION}" \
    --values "${SCRIPT_DIR}/values-promtail.yaml" \
    --timeout 5m \
    --atomic
fi
echo "  OK Promtail déployé"

echo "[5/5] Validation des pods..."
kubectl wait --for=condition=ready pod \
  -n "${NAMESPACE}" \
  -l "app.kubernetes.io/name=loki" \
  --timeout=180s 2>/dev/null || \
  echo "  Loki: vérifiez manuellement (kubectl get pods -n ${NAMESPACE})"

kubectl rollout status daemonset \
  -n "${NAMESPACE}" "${PROMTAIL_RELEASE}" \
  --timeout=120s 2>/dev/null || \
  echo "  Promtail: vérifiez le DaemonSet"

echo ""
echo "======================================================"
echo "  Loki + Promtail opérationnels !"
echo ""
echo "  Loki URL interne : http://loki:3100"
echo "  Dans Grafana → Explore → Datasource: Loki"
echo "  LogQL test : {namespace=\"default\",app=\"transaction-service\"}"
echo "======================================================"
