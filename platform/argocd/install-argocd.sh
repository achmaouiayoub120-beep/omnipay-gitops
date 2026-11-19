#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Script d'installation Helm reproductible pour ArgoCD
# Rôle P4 : Livraison & Chaîne d'Approvisionnement
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/argocd-values.yaml"
NAMESPACE="argocd"
HELM_RELEASE="argocd"

echo "==================================================================="
echo " [P4] Déploiement d'ArgoCD GitOps Controller (OmniPay Zero-Trust)  "
echo "==================================================================="

# 1. Vérification des prérequis
command -v helm >/dev/null 2>&1 || { echo "[ERREUR] Helm n'est pas installé."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "[ERREUR] Kubectl n'est pas installé."; exit 1; }

# 2. Ajout du dépôt Helm officiel Argo
echo "--> [1/4] Ajout du dépôt Helm Argo..."
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo

# 3. Création du namespace dédié s'il n'existe pas
echo "--> [2/4] Création du namespace '${NAMESPACE}'..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 4. Déploiement ou mise à niveau d'ArgoCD
echo "--> [3/4] Déploiement du chart ArgoCD avec ApplicationSet activé..."
helm upgrade --install "${HELM_RELEASE}" argo/argo-cd \
  --namespace "${NAMESPACE}" \
  --values "${VALUES_FILE}" \
  --wait \
  --timeout 10m

# 5. Déploiement des ApplicationSets
echo "--> [4/4] Application des générateurs ApplicationSet pour OmniPay..."
kubectl apply -f "${SCRIPT_DIR}/applicationsets/applicationset-omnipay.yaml"

# 6. Récupération du mot de passe admin initial
ADMIN_PASSWORD=$(kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "(déjà réinitialisé ou indisponible)")

echo "==================================================================="
echo " ArgoCD est prêt !"
echo " URL Web : http://argocd.omnipay.local:30005"
echo " Identifiant : admin"
echo " Mot de passe initial : ${ADMIN_PASSWORD}"
echo " ApplicationSet déployé : omnipay-environments (dev, recette, prod)"
echo "==================================================================="
