#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Installation Helm reproductible pour Kyverno Admission Controller
# Rôle P4 : Widad El Gharzaz (Packaging, Harbor, Argo Rollouts & Kyverno)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICIES_DIR="${SCRIPT_DIR}/policies"
NAMESPACE="kyverno"
HELM_RELEASE="kyverno"

echo "==================================================================="
echo " [P4] Déploiement de Kyverno Admission Controller (OmniPay)        "
echo "==================================================================="

# 1. Vérification des outils
command -v helm >/dev/null 2>&1 || { echo "[ERREUR] Helm n'est pas installé."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "[ERREUR] Kubectl n'est pas installé."; exit 1; }

# 2. Ajout du dépôt Helm officiel Kyverno
echo "--> [1/4] Ajout du dépôt Helm Kyverno..."
helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
helm repo update kyverno

# 3. Création du namespace
echo "--> [2/4] Création du namespace '${NAMESPACE}'..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 4. Installation du chart Kyverno
echo "--> [3/4] Déploiement du chart Kyverno..."
helm upgrade --install "${HELM_RELEASE}" kyverno/kyverno \
  --namespace "${NAMESPACE}" \
  --set admissionController.replicas=1 \
  --set backgroundController.replicas=1 \
  --set cleanupController.replicas=1 \
  --set reportsController.replicas=1 \
  --wait \
  --timeout 8m

# 5. Déploiement des ClusterPolicies Zero-Trust (Admission & Runtime Hardening)
echo "--> [4/4] Application des ClusterPolicies Zero-Trust..."
kubectl apply -f "${POLICIES_DIR}/disallow-unsigned-images.yaml"
kubectl apply -f "${POLICIES_DIR}/require-non-root.yaml"
kubectl apply -f "${POLICIES_DIR}/mutate-inject-zero-trust-labels.yaml"
kubectl apply -f "${POLICIES_DIR}/disallow-host-path-and-privileged.yaml"
kubectl apply -f "${POLICIES_DIR}/require-ro-rootfs-and-drop-all.yaml"

echo "==================================================================="
echo " Kyverno Admission Controller est opérationnel et actif."
echo " - Signature Cosign : Bloquante (Enforce)"
echo " - Runtime Hardening : HostPath, Privileged et Caps interdits (Enforce)"
echo " - Immutabilité      : ReadOnlyRootFilesystem & Drop ALL imposés"
echo " - Mutation          : Injection automatique labels Zero-Trust & Seccomp"
echo "==================================================================="
