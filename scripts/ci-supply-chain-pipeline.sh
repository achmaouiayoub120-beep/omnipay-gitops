#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Script CI Supply-Chain (Syft SBOM, Push Harbor, Cosign Sign)
# Utilisé par le pipeline Jenkins (P1) pour chaque microservice
# Rôle P4 : Livraison & Chaîne d'Approvisionnement
# ==============================================================================

set -euo pipefail

# Paramètres obligatoires
SERVICE_NAME="${1:-transaction}"
IMAGE_TAG="${2:-$(git rev-parse --short HEAD 2>/dev/null || echo "latest")}"
HARBOR_REGISTRY="${HARBOR_REGISTRY:-harbor.omnipay.local:30002}"
HARBOR_PROJECT="${HARBOR_PROJECT:-omnipay}"
FULL_IMAGE_NAME="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${SERVICE_NAME}-service:${IMAGE_TAG}"
SBOM_OUTPUT_FILE="sbom-${SERVICE_NAME}-${IMAGE_TAG}.spdx.json"

COSIGN_KEY_PATH="${COSIGN_KEY_PATH:-/secrets/cosign.key}"
COSIGN_PUB_PATH="${COSIGN_PUB_PATH:-/secrets/cosign.pub}"
export COSIGN_PASSWORD="${COSIGN_PASSWORD:-OmniPayCosignKey2026!}"

echo "==================================================================="
echo " [P4] Supply Chain Security Pipeline : ${SERVICE_NAME} (${IMAGE_TAG})"
echo " Image cible : ${FULL_IMAGE_NAME}"
echo "==================================================================="

# 1. Vérification des outils nécessaires
command -v docker >/dev/null 2>&1 || { echo "[ERREUR] Docker n'est pas disponible."; exit 1; }
command -v syft >/dev/null 2>&1 || { echo "[ERREUR] Syft n'est pas installé sur l'agent."; exit 1; }
command -v cosign >/dev/null 2>&1 || { echo "[ERREUR] Cosign n'est pas installé sur l'agent."; exit 1; }

# 2. Construction de l'image Docker
echo "--> [1/5] Construction de l'image Docker..."
docker build -t "${FULL_IMAGE_NAME}" "services/${SERVICE_NAME}"

# 3. Génération du SBOM (Software Bill of Materials) avec Syft
echo "--> [2/5] Génération du SBOM SPDX avec Syft..."
syft "${FULL_IMAGE_NAME}" -o spdx-json="${SBOM_OUTPUT_FILE}"
echo "    Résumé tabulaire des composants détectés :"
syft "${FULL_IMAGE_NAME}" -o table

# 4. Publication de l'image dans Harbor
echo "--> [3/5] Publication de l'image sur Harbor (${HARBOR_REGISTRY})..."
docker push "${FULL_IMAGE_NAME}"

# 5. Attachement du SBOM et signature cryptographique avec Cosign
echo "--> [4/5] Attachement du SBOM à l'artefact OCI dans Harbor..."
cosign attach sbom --sbom "${SBOM_OUTPUT_FILE}" "${FULL_IMAGE_NAME}"

echo "--> [5/5] Signature cryptographique du conteneur avec Cosign..."
cosign sign --key "${COSIGN_KEY_PATH}" --yes "${FULL_IMAGE_NAME}"

echo "--> [Validation] Vérification immédiate de la signature Cosign..."
cosign verify --key "${COSIGN_PUB_PATH}" "${FULL_IMAGE_NAME}"

echo "==================================================================="
echo " SUCCÈS : Image signée et vérifiée avec succès !"
echo " Digest OCI signé et prêt pour le déploiement GitOps ArgoCD."
echo "==================================================================="
