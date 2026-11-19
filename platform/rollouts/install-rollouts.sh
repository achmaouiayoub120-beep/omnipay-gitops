#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Installation d'Argo Rollouts (Contrôleur Canary)
# Rôle P4 : Livraison & Chaîne d'Approvisionnement
# ==============================================================================

set -euo pipefail

NAMESPACE="argo-rollouts"

echo "==================================================================="
echo " [P4] Déploiement du contrôleur Argo Rollouts (Canary & Blue/Green)"
echo "==================================================================="

# 1. Vérification des prérequis
command -v kubectl >/dev/null 2>&1 || { echo "[ERREUR] Kubectl n'est pas installé."; exit 1; }

# 2. Création du namespace
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 3. Installation des CRDs et du contrôleur Argo Rollouts
echo "--> [1/2] Installation des manifestes officiels Argo Rollouts..."
kubectl apply -n "${NAMESPACE}" -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# 4. Attente de la disponibilité du contrôleur
echo "--> [2/2] Attente du démarrage du pod argo-rollouts..."
kubectl rollout status deployment/argo-rollouts -n "${NAMESPACE}" --timeout=180s

echo "==================================================================="
echo " Contrôleur Argo Rollouts installé avec succès !"
echo " Pour installer le plugin CLI kubectl :"
echo "   curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64"
echo "   chmod +x ./kubectl-argo-rollouts-linux-amd64"
echo "   sudo mv ./kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts"
echo "==================================================================="
