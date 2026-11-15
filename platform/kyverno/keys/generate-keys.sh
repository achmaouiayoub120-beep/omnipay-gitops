#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Génération de la paire de clés cryptographiques Cosign
# Rôle P4 : Livraison & Chaîne d'Approvisionnement
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}"
KEY_NAME="cosign"

echo "==================================================================="
echo " [P4] Génération / Rotation de la paire de clés Cosign             "
echo "==================================================================="

# 1. Vérification de la disponibilité de cosign ou openssl
if command -v cosign >/dev/null 2>&1; then
    echo "--> [1/3] Génération de la clé avec Cosign CLI..."
    export COSIGN_PASSWORD="${COSIGN_PASSWORD:-OmniPayCosignKey2026!}"
    cosign generate-key-pair
    mv cosign.key "${OUTPUT_DIR}/${KEY_NAME}.key"
    mv cosign.pub "${OUTPUT_DIR}/${KEY_NAME}.pub"
elif command -v openssl >/dev/null 2>&1; then
    echo "--> [1/3] Cosign non présent sur l'hôte, génération ECDSA P-256 avec OpenSSL..."
    openssl ecparam -name prime256v1 -genkey -noout -out "${OUTPUT_DIR}/${KEY_NAME}.key"
    openssl ec -in "${OUTPUT_DIR}/${KEY_NAME}.key" -pubout -out "${OUTPUT_DIR}/${KEY_NAME}.pub"
else
    echo "[ERREUR] Ni cosign ni openssl n'ont été trouvés dans le PATH."
    exit 1
fi

echo "--> [2/3] Clé publique générée dans : ${OUTPUT_DIR}/${KEY_NAME}.pub"
cat "${OUTPUT_DIR}/${KEY_NAME}.pub"

# 2. Injection de la clé privée dans Kubernetes pour Jenkins (namespace 'jenkins')
echo "--> [3/3] Stockage sécurisé de la clé privée dans Kubernetes pour Jenkins..."
if command -v kubectl >/dev/null 2>&1; then
    kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic cosign-signing-key \
        --namespace=jenkins \
        --from-file=cosign.key="${OUTPUT_DIR}/${KEY_NAME}.key" \
        --from-file=cosign.pub="${OUTPUT_DIR}/${KEY_NAME}.pub" \
        --from-literal=cosign-password="${COSIGN_PASSWORD:-OmniPayCosignKey2026!}" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "    Secret 'cosign-signing-key' créé dans le namespace 'jenkins'."
else
    echo "    [WARN] kubectl indisponible, saut de l'injection du secret."
fi

echo "==================================================================="
echo " Génération de la paire de clés terminée avec succès."
echo " Conservez '${KEY_NAME}.key' strictement confidentielle."
echo "==================================================================="
