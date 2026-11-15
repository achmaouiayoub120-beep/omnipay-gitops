#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Script d'installation Helm reproductible pour Harbor
# Port d'accès : NodePort 30002 (http://harbor.omnipay.local:30002)
# Rôle P4 : Livraison & Chaîne d'Approvisionnement
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/harbor-values.yaml"
NAMESPACE="harbor"
HELM_RELEASE="harbor"

echo "==================================================================="
echo " [P4] Déploiement de Harbor Enterprise Private Registry (OmniPay)  "
echo "==================================================================="

# 1. Vérification des prérequis
command -v helm >/dev/null 2>&1 || { echo "[ERREUR] Helm n'est pas installé."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "[ERREUR] Kubectl n'est pas installé."; exit 1; }

# 2. Ajout du dépôt Helm officiel Harbor
echo "--> [1/4] Ajout du dépôt Helm Harbor..."
helm repo add harbor https://helm.goharbor.io --force-update
helm repo update harbor

# 3. Création du namespace dédié s'il n'existe pas
echo "--> [2/4] Création du namespace '${NAMESPACE}'..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 4. Déploiement ou mise à niveau de Harbor
echo "--> [3/4] Déploiement du chart Harbor avec configuration NodePort (30002)..."
helm upgrade --install "${HELM_RELEASE}" harbor/harbor \
  --namespace "${NAMESPACE}" \
  --values "${VALUES_FILE}" \
  --wait \
  --timeout 12m

# 5. Validation de l'état des pods
echo "--> [4/4] Vérification de l'état des services Harbor..."
kubectl get pods -n "${NAMESPACE}"
kubectl get svc -n "${NAMESPACE}" -l app=harbor

echo "==================================================================="
echo " Harbor est opérationnel sur http://harbor.omnipay.local:30002"
echo " Compte administrateur initial : admin / HarborAdminOmniPay2026!"
echo " Prochaine étape : exécuter platform/harbor/init-harbor.sh pour"
echo " initialiser le projet 'omnipay' et le robot CI."
echo "==================================================================="
