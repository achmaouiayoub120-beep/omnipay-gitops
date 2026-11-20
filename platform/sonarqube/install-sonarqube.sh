#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Installation Reproductible de SonarQube Community 10.x
# Rôle P4 : Ingénieure Packaging, Registre Harbor & Supply Chain GitOps
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/values-sonarqube.yaml"
NAMESPACE="sonarqube"
HELM_RELEASE="sonarqube"
HELM_REPO_URL="https://SonarSource.github.io/helm-chart-sonarqube"

echo "==================================================================="
echo " [P4] Déploiement de SonarQube Community 10.x (K3s Zero-Trust)     "
echo "==================================================================="

# 1. Vérification des prérequis
command -v helm >/dev/null 2>&1 || { echo "[ERREUR] Helm n'est pas installé sur l'hôte."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "[ERREUR] Kubectl n'est pas disponible."; exit 1; }

# 2. Ajout et mise à jour du dépôt Helm officiel SonarSource
echo "--> [1/4] Ajout du dépôt Helm officiel SonarSource (${HELM_REPO_URL})..."
helm repo add sonarqube "${HELM_REPO_URL}" --force-update
helm repo update sonarqube

# 3. Création du namespace dédié s'il n'existe pas
echo "--> [2/4] Création du namespace Kubernetes '${NAMESPACE}'..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 4. Déploiement ou mise à niveau du chart SonarQube
echo "--> [3/4] Déploiement du chart sonarqube/sonarqube (NodePort 30003, limites 2Gi RAM / 1 CPU)..."
helm upgrade --install "${HELM_RELEASE}" sonarqube/sonarqube \
  --namespace "${NAMESPACE}" \
  --values "${VALUES_FILE}" \
  --wait \
  --timeout 15m

# 5. Validation de l'état des pods et services
echo "--> [4/4] Vérification de l'état des composants SonarQube..."
kubectl get pods -n "${NAMESPACE}" -l "app=sonarqube"
kubectl get svc -n "${NAMESPACE}" -l "app=sonarqube"

echo "==================================================================="
echo " SonarQube 10.x est déployé avec succès !"
echo " - Accès NodePort : http://sonarqube.omnipay.local:30003"
echo " - Accès Ingress  : http://sonarqube.omnipay.local"
echo " - Namespace     : ${NAMESPACE}"
echo " - Stockage      : local-path (PostgreSQL 5Gi + SonarQube 10Gi)"
echo ""
echo " Prochaine étape : exécuter 'platform/sonarqube/init-sonarqube.sh'"
echo " pour configurer le projet, la Quality Gate et le webhook Jenkins."
echo "==================================================================="
