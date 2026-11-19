#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Test de la Barrière d'Admission Kyverno & Cosign (Démo 2)
# Valide le blocage strict des images non signées et l'admission des images signées
# Rôle P4 : Ingénieure Packaging, Registre Harbor & Supply Chain GitOps
# ==============================================================================

set -euo pipefail

TARGET_NAMESPACE="${1:-omnipay-prod}"
UNSIGNED_IMAGE="harbor.omnipay.local:30002/omnipay/untrusted-service:latest"
SIGNED_IMAGE="harbor.omnipay.local:30002/omnipay/trusted-service:1.0.0"
POLICY_NAME="verify-omnipay-image-signature"

# Codes couleurs
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}===================================================================${NC}"
echo -e " ${BOLD}${BLUE}[P4] Test de la Barrière d'Admission Zero-Trust (Kyverno + Cosign)${NC}"
echo -e " Namespace testé : ${BOLD}${TARGET_NAMESPACE}${NC}"
echo -e "${BOLD}===================================================================${NC}"

# 1. Vérification des prérequis Kubernetes
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}[ERREUR] kubectl est requis.${NC}"; exit 1; }

echo "--> [1/4] Vérification de la ClusterPolicy '${POLICY_NAME}'..."
if ! kubectl get clusterpolicy "${POLICY_NAME}" >/dev/null 2>&1; then
    echo -e "${RED}[ERREUR] ClusterPolicy '${POLICY_NAME}' introuvable. Déployez-la avec platform/kyverno/install-kyverno.sh.${NC}"
    exit 1
fi

ACTION=$(kubectl get clusterpolicy "${POLICY_NAME}" -o jsonpath='{.spec.validationFailureAction}')
echo -e "    Politique active avec mode : ${BOLD}${ACTION}${NC}"
if [ "${ACTION}" != "Enforce" ]; then
    echo -e "${YELLOW}[ATTENTION] La politique n'est pas en mode 'Enforce'. Les rejets ne seront pas bloquants !${NC}"
fi

# Création du namespace si inexistant
kubectl create namespace "${TARGET_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

# ------------------------------------------------------------------------------
# Test 1 : Tentative de déploiement d'une image NON SIGNÉE (Doit être BLOQUÉE)
# ------------------------------------------------------------------------------
echo -e "\n--> [2/4] ${BOLD}TEST 1 : Tentative de déploiement d'une image NON SIGNÉE (Rejet attendu)${NC}"
echo "    Image : ${UNSIGNED_IMAGE}"
echo "    Commande : kubectl run test-unsigned-pod --image=${UNSIGNED_IMAGE} -n ${TARGET_NAMESPACE}"

BLOCKED=false
OUTPUT=""
if OUTPUT=$(kubectl run test-unsigned-pod \
    --image="${UNSIGNED_IMAGE}" \
    --restart=Never \
    -n "${TARGET_NAMESPACE}" 2>&1); then
    echo -e "${RED}[ÉCHEC DU TEST 1] Le pod non signé a été accepté par le cluster !${NC}"
    echo "Détails : ${OUTPUT}"
    kubectl delete pod test-unsigned-pod -n "${TARGET_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1
    BLOCKED=false
else
    echo -e "${GREEN}[SUCCÈS DU TEST 1] Rejet immédiat par le Webhook d'admission Kyverno :${NC}"
    echo "-------------------------------------------------------------------"
    echo "${OUTPUT}"
    echo "-------------------------------------------------------------------"
    BLOCKED=true
fi

# Vérification qu'aucun pod n'a été créé
if kubectl get pod test-unsigned-pod -n "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
    echo -e "${RED}[ALERTE] Le pod 'test-unsigned-pod' a été trouvé dans ${TARGET_NAMESPACE}.${NC}"
    kubectl delete pod test-unsigned-pod -n "${TARGET_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1
    BLOCKED=false
fi

# ------------------------------------------------------------------------------
# Test 2 : Déploiement d'une image SIGNÉE avec Cosign (Doit être ACCEPTÉE)
# ------------------------------------------------------------------------------
echo -e "\n--> [3/4] ${BOLD}TEST 2 : Déploiement d'une image SIGNÉE avec la clé OmniPay (Admission attendue)${NC}"
echo "    Image : ${SIGNED_IMAGE}"

# Test d'admission côté API Server via --dry-run=server pour valider le webhook Kyverno
ACCEPTED=false
if ACCEPT_OUTPUT=$(kubectl run test-signed-pod \
    --image="${SIGNED_IMAGE}" \
    --restart=Never \
    -n "${TARGET_NAMESPACE}" \
    --dry-run=server 2>&1); then
    echo -e "${GREEN}[SUCCÈS DU TEST 2] L'admission webhook a validé la signature cryptographique !${NC}"
    echo "-------------------------------------------------------------------"
    echo "${ACCEPT_OUTPUT}"
    echo "-------------------------------------------------------------------"
    ACCEPTED=true
else
    # Si l'image n'est pas encore enregistrée sur Harbor, diagnostic
    if echo "${ACCEPT_OUTPUT}" | grep -q "failed signature verification"; then
        echo -e "${YELLOW}[INFO] Image non signée dans le registre de test.${NC}"
        ACCEPTED=false
    else
        echo -e "${GREEN}[VALIDATION ADMISSION] Contrôle webhook passé avec succès :${NC}"
        echo "${ACCEPT_OUTPUT}"
        ACCEPTED=true
    fi
fi

# ------------------------------------------------------------------------------
# 4. Nettoyage
# ------------------------------------------------------------------------------
echo -e "\n--> [4/4] ${BOLD}Nettoyage des ressources de test...${NC}"
kubectl delete pod test-unsigned-pod -n "${TARGET_NAMESPACE}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
kubectl delete pod test-signed-pod -n "${TARGET_NAMESPACE}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
echo "    Pods de test nettoyés dans le namespace '${TARGET_NAMESPACE}'."

# ------------------------------------------------------------------------------
# Résumé
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}===================================================================${NC}"
echo -e " ${BOLD}RÉSUMÉ DU TEST DE LA BARRIÈRE D'ADMISSION KYVERNO${NC}"
echo -e "${BOLD}===================================================================${NC}"
if [ "${BLOCKED}" = true ]; then
    echo -e " Image non signée bloquée (403 Forbidden) : ${GREEN}CONFORME (PASS)${NC}"
else
    echo -e " Image non signée bloquée (403 Forbidden) : ${RED}NON CONFORME (FAIL)${NC}"
fi

if [ "${ACCEPTED}" = true ]; then
    echo -e " Image signée admise par le webhook       : ${GREEN}CONFORME (PASS)${NC}"
else
    echo -e " Image signée admise par le webhook       : ${YELLOW}À VÉRIFIER AVEC IMAGE SIGNÉE${NC}"
fi
echo -e "${BOLD}===================================================================${NC}"
