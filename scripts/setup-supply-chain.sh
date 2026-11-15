#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Bootstrap Complet de la Plateforme de Livraison (P4)
# Orchestre le déploiement de Harbor, ArgoCD, Kyverno et Argo Rollouts
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==================================================================="
echo "   OmniPay Zero-Trust — Déploiement Complet de la Chaîne P4       "
echo "==================================================================="

# 1. Génération des clés cryptographiques Cosign
echo ">>> [1/5] Initialisation des clés cryptographiques Cosign..."
bash "${SCRIPT_DIR}/platform/kyverno/keys/generate-keys.sh"

# 2. Installation de Harbor (port 30002)
echo ">>> [2/5] Déploiement de Harbor Enterprise Private Registry..."
bash "${SCRIPT_DIR}/platform/harbor/install-harbor.sh"

# 3. Initialisation du projet 'omnipay' et du robot CI
echo ">>> [3/5] Configuration du projet Harbor et du compte Robot..."
bash "${SCRIPT_DIR}/platform/harbor/init-harbor.sh"

# 4. Installation de Kyverno et application des politiques d'admission
echo ">>> [4/5] Déploiement de Kyverno et politique d'admission Zero-Trust..."
bash "${SCRIPT_DIR}/platform/kyverno/install-kyverno.sh"

# 5. Déploiement d'Argo Rollouts (Canary)
echo ">>> [5/5] Déploiement du contrôleur Argo Rollouts..."
bash "${SCRIPT_DIR}/platform/rollouts/install-rollouts.sh"

# 6. Déploiement d'ArgoCD et des ApplicationSets
echo ">>> [6/6] Déploiement d'ArgoCD et des ApplicationSets GitOps..."
bash "${SCRIPT_DIR}/platform/argocd/install-argocd.sh"

echo "==================================================================="
echo " [P4] Tous les composants de livraison et sécurité sont déployés ! "
echo " - Harbor : http://harbor.omnipay.local:30002"
echo " - ArgoCD : http://argocd.omnipay.local:30005"
echo " - Kyverno : Actif (ValidationFailureAction=Enforce)"
echo " - Argo Rollouts : Prêt pour le Canary de transaction-service"
echo "==================================================================="
