#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Bootstrap Complet de la Chaîne Supply Chain & GitOps (P4)
# Orchestre le déploiement de Harbor, SonarQube, Kyverno, Rollouts et ArgoCD
# Rôle P4 : Widad El Gharzaz (Packaging, Harbor, Argo Rollouts & Kyverno)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==================================================================="
echo "   OmniPay Zero-Trust — Déploiement Complet de la Chaîne P4 (S3)   "
echo "==================================================================="

# 1. Génération des clés cryptographiques Cosign
echo ">>> [1/8] Initialisation des clés cryptographiques Cosign..."
bash "${SCRIPT_DIR}/platform/kyverno/keys/generate-keys.sh"

# 2. Installation de Harbor durci (NodePort 30002)
echo ">>> [2/8] Déploiement de Harbor Enterprise Private Registry (Port 30002)..."
bash "${SCRIPT_DIR}/platform/harbor/install-harbor.sh"

# 3. Initialisation du projet 'omnipay' et du robot CI
echo ">>> [3/8] Configuration du projet Harbor, scans Trivy et immuabilité..."
bash "${SCRIPT_DIR}/platform/harbor/init-harbor.sh"

# 4. Installation de SonarQube Community 10.x (NodePort 30003)
echo ">>> [4/8] Déploiement de SonarQube Community 10.x (Port 30003)..."
bash "${SCRIPT_DIR}/platform/sonarqube/install-sonarqube.sh"

# 5. Initialisation du projet SonarQube, Quality Gate et Webhook
echo ">>> [5/8] Configuration de la Quality Gate OmniPay Zero-Trust & Webhook..."
bash "${SCRIPT_DIR}/platform/sonarqube/init-sonarqube.sh"

# 6. Installation de Kyverno et application des politiques d'admission & runtime hardening
echo ">>> [6/8] Déploiement de Kyverno et des ClusterPolicies Zero-Trust..."
bash "${SCRIPT_DIR}/platform/kyverno/install-kyverno.sh"

# 7. Déploiement d'Argo Rollouts (Contrôleur Canary & AnalysisTemplate)
echo ">>> [7/8] Déploiement du contrôleur Argo Rollouts et de l'AnalysisTemplate..."
bash "${SCRIPT_DIR}/platform/rollouts/install-rollouts.sh"
kubectl apply -f "${SCRIPT_DIR}/platform/rollouts/analysis-templates/prometheus-error-rate.yaml" 2>/dev/null || true

# 8. Déploiement d'ArgoCD et des ApplicationSets GitOps
echo ">>> [8/8] Déploiement d'ArgoCD (Port 30005) et des ApplicationSets multi-environnements..."
bash "${SCRIPT_DIR}/platform/argocd/install-argocd.sh"

echo "==================================================================="
echo " [P4] Tous les composants de livraison et sécurité sont déployés ! "
echo "==================================================================="
echo " Cartographie des ports et accès plateforme :"
echo " - Harbor Registry   : http://harbor.omnipay.local:30002"
echo " - SonarQube QG      : http://sonarqube.omnipay.local:30003"
echo " - ArgoCD UI         : http://argocd.omnipay.local:30005"
echo " - Vault UI          : http://vault.omnipay.local:30006"
echo " - Grafana SRE       : http://grafana.omnipay.local:30300"
echo " - Prometheus        : http://prometheus.omnipay.local:30900"
echo " - Argo Rollouts Dash: http://localhost:3100 (kubectl argo rollouts dashboard)"
echo " - Kyverno Webhook   : Actif (Enforce : Cosign, HostPath, Privileged, RoRootfs)"
echo " - Argo Rollouts     : Canary 10%->33%->66%->100% prêt avec Prometheus"
echo "==================================================================="
