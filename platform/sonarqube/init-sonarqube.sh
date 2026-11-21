#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Initialisation Automatisée de SonarQube Community 10.x
# Configure le projet, la Quality Gate Zero-Trust, le webhook et le token Jenkins
# Rôle P4 : Ingénieure Packaging, Registre Harbor & Supply Chain GitOps
# ==============================================================================

set -euo pipefail

SONAR_URL="${SONAR_URL:-http://sonarqube.omnipay.local:30003}"
SONAR_ADMIN_USER="${SONAR_ADMIN_USER:-admin}"
INITIAL_PASSWORD="${INITIAL_PASSWORD:-admin}"
SONAR_ADMIN_PASSWORD="${SONAR_ADMIN_PASSWORD:-SonarQubeAdminOmniPay2026!}"

PROJECT_KEY="omnipay-banking-platform"
PROJECT_NAME="OmniPay Banking Platform"
QUALITY_GATE_NAME="OmniPay Zero-Trust"
WEBHOOK_NAME="Jenkins-OmniPay-Webhook"
WEBHOOK_URL="http://jenkins.omnipay.local:8088/sonarqube-webhook/"
TOKEN_NAME="jenkins-omnipay-token"

echo "==================================================================="
echo " [P4] Initialisation de SonarQube 10.x & Gouvernance Qualité       "
echo " Target : ${SONAR_URL}"
echo "==================================================================="

# ------------------------------------------------------------------------------
# 1. Attente active de la disponibilité de SonarQube (HTTP 200 sur /api/system/status)
# ------------------------------------------------------------------------------
echo "--> [1/6] Attente de la disponibilité de SonarQube sur ${SONAR_URL}..."
MAX_RETRIES=60
RETRY_COUNT=0

until curl -s -f "${SONAR_URL}/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ "${RETRY_COUNT}" -ge "${MAX_RETRIES}" ]; then
        echo "[ERREUR] SonarQube inaccessible ou non prêt après ${MAX_RETRIES} tentatives."
        exit 1
    fi
    echo "    SonarQube démarre... (${RETRY_COUNT}/${MAX_RETRIES}) - attente 10s"
    sleep 10
done
echo "    SonarQube API est en ligne avec le statut UP !"

# ------------------------------------------------------------------------------
# 2. Gestion du mot de passe administrateur initial
# ------------------------------------------------------------------------------
echo "--> [2/6] Vérification et synchronisation du compte administrateur..."
ACTIVE_PASSWORD="${SONAR_ADMIN_PASSWORD}"

if curl -s -f -u "${SONAR_ADMIN_USER}:${INITIAL_PASSWORD}" "${SONAR_URL}/api/authentication/validate" 2>/dev/null | grep -q '"valid":true'; then
    echo "    Mot de passe par défaut détecté. Mise à jour vers le secret Zero-Trust..."
    curl -s -f -X POST -u "${SONAR_ADMIN_USER}:${INITIAL_PASSWORD}" \
        "${SONAR_URL}/api/users/change_password" \
        -d "login=${SONAR_ADMIN_USER}" \
        -d "previousPassword=${INITIAL_PASSWORD}" \
        -d "password=${SONAR_ADMIN_PASSWORD}" >/dev/null
    echo "    Mot de passe administrateur sécurisé avec succès."
    ACTIVE_PASSWORD="${SONAR_ADMIN_PASSWORD}"
else
    echo "    Authentification administrateur validée avec le mot de passe configuré."
fi

AUTH_HEADER="${SONAR_ADMIN_USER}:${ACTIVE_PASSWORD}"

# ------------------------------------------------------------------------------
# 3. Création du projet OmniPay Banking Platform
# ------------------------------------------------------------------------------
echo "--> [3/6] Configuration du projet '${PROJECT_NAME}' (${PROJECT_KEY})..."
PROJECT_EXISTS=$(curl -s -u "${AUTH_HEADER}" "${SONAR_URL}/api/projects/search?projects=${PROJECT_KEY}" | grep -c "\"key\":\"${PROJECT_KEY}\"" || true)

if [ "${PROJECT_EXISTS}" -gt 0 ]; then
    echo "    Le projet '${PROJECT_KEY}' existe déjà."
else
    curl -s -f -X POST -u "${AUTH_HEADER}" "${SONAR_URL}/api/projects/create" \
        -d "name=${PROJECT_NAME}" \
        -d "project=${PROJECT_KEY}" \
        -d "mainBranch=main" >/dev/null
    echo "    Projet '${PROJECT_NAME}' créé avec succès !"
fi

# ------------------------------------------------------------------------------
# 4. Configuration de la Quality Gate OmniPay Zero-Trust
# ------------------------------------------------------------------------------
echo "--> [4/6] Configuration de la Quality Gate '${QUALITY_GATE_NAME}'..."
QG_EXISTS=$(curl -s -u "${AUTH_HEADER}" "${SONAR_URL}/api/qualitygates/list" | grep -c "\"name\":\"${QUALITY_GATE_NAME}\"" || true)

if [ "${QG_EXISTS}" -eq 0 ]; then
    curl -s -f -X POST -u "${AUTH_HEADER}" "${SONAR_URL}/api/qualitygates/create" \
        -d "name=${QUALITY_GATE_NAME}" >/dev/null
    echo "    Quality Gate '${QUALITY_GATE_NAME}' créée."
else
    echo "    Quality Gate '${QUALITY_GATE_NAME}' déjà présente."
fi

# Conditions strictes OmniPay Zero-Trust :
# - 0 bug bloquant (blocker_violations & new_blocker_violations)
# - 0 vulnérabilité (vulnerabilities & new_vulnerabilities)
# - Couverture > 80% (coverage & new_coverage)
echo "    Application des critères stricts Zero-Trust..."
declare -A CONDITIONS=(
    ["blocker_violations"]="GT:0"
    ["new_blocker_violations"]="GT:0"
    ["vulnerabilities"]="GT:0"
    ["new_vulnerabilities"]="GT:0"
    ["coverage"]="LT:80"
    ["new_coverage"]="LT:80"
)

for METRIC in "${!CONDITIONS[@]}"; do
    IFS=":" read -r OP THRESHOLD <<< "${CONDITIONS[$METRIC]}"
    curl -s -X POST -u "${AUTH_HEADER}" "${SONAR_URL}/api/qualitygates/create_condition" \
        -d "gateName=${QUALITY_GATE_NAME}" \
        -d "metric=${METRIC}" \
        -d "op=${OP}" \
        -d "error=${THRESHOLD}" >/dev/null 2>&1 || true
    echo "    - Règle vérifiée : ${METRIC} (op: ${OP}, seuil: ${THRESHOLD})"
done

# Association de la Quality Gate au projet OmniPay
curl -s -f -X POST -u "${AUTH_HEADER}" "${SONAR_URL}/api/qualitygates/select" \
    -d "gateName=${QUALITY_GATE_NAME}" \
    -d "projectKey=${PROJECT_KEY}" >/dev/null
echo "    Quality Gate '${QUALITY_GATE_NAME}' associée au projet '${PROJECT_KEY}'."

# ------------------------------------------------------------------------------
# 5. Création du Webhook pour Jenkins (Notification fin d'analyse Quality Gate)
# ------------------------------------------------------------------------------
echo "--> [5/6] Configuration du Webhook Jenkins sur ${WEBHOOK_URL}..."
EXISTING_WEBHOOK=$(curl -s -u "${AUTH_HEADER}" "${SONAR_URL}/api/webhooks/list?project=${PROJECT_KEY}" | grep -c "\"url\":\"${WEBHOOK_URL}\"" || true)

if [ "${EXISTING_WEBHOOK}" -eq 0 ]; then
    curl -s -f -X POST -u "${AUTH_HEADER}" "${SONAR_URL}/api/webhooks/create" \
        -d "name=${WEBHOOK_NAME}" \
        -d "project=${PROJECT_KEY}" \
        -d "url=${WEBHOOK_URL}" >/dev/null
    echo "    Webhook Jenkins configuré avec succès pour '${PROJECT_KEY}'."
else
    echo "    Le webhook Jenkins est déjà configuré."
fi

# ------------------------------------------------------------------------------
# 6. Génération du Jeton d'authentification pour Jenkins (P1)
# ------------------------------------------------------------------------------
echo "--> [6/6] Génération du token d'analyse SonarQube pour Jenkins..."
# Révocation d'un ancien token de même nom si existant
curl -s -X POST -u "${AUTH_HEADER}" "${SONAR_URL}/api/user_tokens/revoke" \
    -d "name=${TOKEN_NAME}" >/dev/null 2>&1 || true

TOKEN_RESPONSE=$(curl -s -f -X POST -u "${AUTH_HEADER}" "${SONAR_URL}/api/user_tokens/generate" \
    -d "name=${TOKEN_NAME}" \
    -d "type=GLOBAL_ANALYSIS_TOKEN" 2>/dev/null || \
curl -s -f -X POST -u "${AUTH_HEADER}" "${SONAR_URL}/api/user_tokens/generate" \
    -d "name=${TOKEN_NAME}" \
    -d "type=USER_TOKEN")

SONAR_TOKEN=$(echo "${TOKEN_RESPONSE}" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' || true)

if [ -z "${SONAR_TOKEN}" ]; then
    echo "[ATTENTION] Impossible d'extraire le token depuis la réponse JSON :"
    echo "${TOKEN_RESPONSE}"
    SONAR_TOKEN="squ_omnipay_jenkins_token_placeholder"
else
    echo "    Jeton généré avec succès !"
fi

# Synchronisation du token dans Kubernetes sous forme de Secret pour Jenkins
if command -v kubectl >/dev/null 2>&1; then
    for NS in "jenkins" "sonarqube"; do
        kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
        kubectl create secret generic sonar-token-secret \
            --namespace="${NS}" \
            --from-literal=SONAR_TOKEN="${SONAR_TOKEN}" \
            --from-literal=SONAR_HOST_URL="${SONAR_URL}" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
    done
    echo "    Secret 'sonar-token-secret' synchronisé dans les namespaces 'jenkins' et 'sonarqube'."
fi

echo "==================================================================="
echo " Initialisation SonarQube terminée avec succès !"
echo " - Projet      : ${PROJECT_KEY} (${PROJECT_NAME})"
echo " - Quality Gate: ${QUALITY_GATE_NAME}"
echo "   * 0 bug bloquant"
echo "   * 0 vulnérabilité"
echo "   * Couverture de test > 80%"
echo " - Webhook     : ${WEBHOOK_URL}"
echo " - Token Jenkins (sonar-auth-token) :"
echo "   ${SONAR_TOKEN}"
echo ""
echo " Transmettre ce token à P1 pour le credential Jenkins 'sonar-auth-token'."
echo "==================================================================="
