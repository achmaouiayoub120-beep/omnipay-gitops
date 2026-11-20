#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Bootstrap Complet de la Chaîne Supply Chain & GitOps (P4)
# Orchestre le déploiement de Harbor, SonarQube, Kyverno, Rollouts et ArgoCD
# Rôle P4 : Ingénieure Packaging, Registre Harbor & Supply Chain GitOps
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==================================================================="
echo "   OmniPay Zero-Trust — Déploiement Complet de la Chaîne P4       "
echo "==================================================================="

# 1. Génération des clés cryptographiques Cosign
echo ">>> [1/8] Initialisation des clés cryptographiques Cosign..."
bash "${SCRIPT_DIR}/platform/kyverno/keys/generate-keys.sh"

# 2. Installation de Harbor durci (port 30002)
echo ">>> [2/8] Déploiement de Harbor Enterprise Private Registry..."
bash "${SCRIPT_DIR}/platform/harbor/install-harbor.sh"

# 3. Initialisation du projet 'omnipay' et du robot CI
echo ">>> [3/8] Configuration du projet Harbor, scans Trivy et immuabilité..."
bash "${SCRIPT_DIR}/platform/harbor/init-harbor.sh"

# 4. Installation de SonarQube Community 10.x (port 30003, limites K3s 2Gi RAM / 1 CPU)
echo ">>> [4/8] Déploiement de SonarQube Community 10.x..."
bash "${SCRIPT_DIR}/platform/sonarqube/install-sonarqube.sh"

# 5. Initialisation du projet SonarQube, Quality Gate et Webhook
echo ">>> [5/8] Configuration de la Quality Gate OmniPay Zero-Trust & Webhook..."
bash "${SCRIPT_DIR}/platform/sonarqube/init-sonarqube.sh"

# 6. Installation de Kyverno et application des politiques d'admission
echo ">>> [6/8] Déploiement de Kyverno et politique d'admission Zero-Trust..."
bash "${SCRIPT_DIR}/platform/kyverno/install-kyverno.sh"

# 7. Déploiement d'Argo Rollouts (Canary)
echo ">>> [7/8] Déploiement du contrôleur Argo Rollouts..."
bash "${SCRIPT_DIR}/platform/rollouts/install-rollouts.sh"

# 8. Déploiement d'ArgoCD et des ApplicationSets GitOps
echo ">>> [8/8] Déploiement d'ArgoCD et des ApplicationSets multi-environnements..."
bash "${SCRIPT_DIR}/platform/argocd/install-argocd.sh"

echo "==================================================================="
echo " [P4] Tous les composants de livraison et sécurité sont déployés ! "
echo " - Harbor    : http://harbor.omnipay.local:30002"
echo " - SonarQube : http://sonarqube.omnipay.local:30003"
echo " - ArgoCD    : http://argocd.omnipay.local:30005"
echo " - Kyverno   : Actif (ValidationFailureAction=Enforce)"
echo " - Rollouts  : Prêt pour le Canary de transaction-service"
echo "==================================================================="
