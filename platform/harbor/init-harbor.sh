#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Initialisation automatisée du projet Harbor & Robot CI
# Rôle P4 : Livraison & Chaîne d'Approvisionnement
# ==============================================================================

set -euo pipefail

HARBOR_URL="${HARBOR_URL:-http://harbor.omnipay.local:30002}"
HARBOR_ADMIN="${HARBOR_ADMIN:-admin}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:-HarborAdminOmniPay2026!}"
PROJECT_NAME="omnipay"
ROBOT_NAME="robot-omnipay-ci"

echo "==================================================================="
echo " [P4] Initialisation du projet '${PROJECT_NAME}' & Robot CI Harbor"
echo "==================================================================="

# 1. Attente de la disponibilité de l'API Harbor
echo "--> [1/5] Vérification de la disponibilité de l'API Harbor sur ${HARBOR_URL}..."
MAX_RETRIES=30
RETRY_COUNT=0
until curl -s -f -u "${HARBOR_ADMIN}:${HARBOR_PASSWORD}" "${HARBOR_URL}/api/v2.0/systeminfo" >/dev/null 2>&1; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ "${RETRY_COUNT}" -ge "${MAX_RETRIES}" ]; then
        echo "[ERREUR] Harbor API inaccessible après ${MAX_RETRIES} tentatives."
        exit 1
    fi
    echo "    Harbor en cours d'initialisation... (${RETRY_COUNT}/${MAX_RETRIES}) - attente 10s"
    sleep 10
done
echo "    Harbor API est prête !"

# 2. Création du projet 'omnipay'
echo "--> [2/5] Création du projet '${PROJECT_NAME}'..."
PROJECT_CHECK_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "${HARBOR_ADMIN}:${HARBOR_PASSWORD}" "${HARBOR_URL}/api/v2.0/projects?name=${PROJECT_NAME}")

if [ "${PROJECT_CHECK_STATUS}" -eq 200 ] && [ "$(curl -s -u "${HARBOR_ADMIN}:${HARBOR_PASSWORD}" "${HARBOR_URL}/api/v2.0/projects?name=${PROJECT_NAME}" | grep -c "\"name\":\"${PROJECT_NAME}\"")" -gt 0 ]; then
    echo "    Le projet '${PROJECT_NAME}' existe déjà."
else
    curl -s -f -X POST "${HARBOR_URL}/api/v2.0/projects" \
        -u "${HARBOR_ADMIN}:${HARBOR_PASSWORD}" \
        -H "Content-Type: application/json" \
        -d '{
            "project_name": "'"${PROJECT_NAME}"'",
            "public": true,
            "metadata": {
                "auto_scan": "true",
                "severity": "critical",
                "prevent_vul": "false"
            }
        }'
    echo "    Projet '${PROJECT_NAME}' créé avec succès."
fi

# 3. Activation de l'analyse automatique Trivy (Scan on push)
echo "--> [3/5] Configuration de l'analyse automatique Trivy (Scan on push)..."
curl -s -X PUT "${HARBOR_URL}/api/v2.0/projects/${PROJECT_NAME}" \
    -u "${HARBOR_ADMIN}:${HARBOR_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d '{
        "metadata": {
            "auto_scan": "true",
            "reuse_sys_cve_allowlist": "true"
        }
    }'
echo "    Scan automatique Trivy activé pour tout push d'image."

# 4. Création du compte Robot CI
echo "--> [4/5] Configuration du compte robot CI '${ROBOT_NAME}'..."
ROBOT_PAYLOAD=$(cat <<EOF
{
  "name": "${ROBOT_NAME}",
  "description": "Robot account for OmniPay CI/CD Pipeline (Jenkins & ArgoCD)",
  "duration": -1,
  "level": "project",
  "permissions": [
    {
      "kind": "project",
      "namespace": "${PROJECT_NAME}",
      "access": [
        {"resource": "repository", "action": "pull"},
        {"resource": "repository", "action": "push"},
        {"resource": "artifact", "action": "read"},
        {"resource": "artifact", "action": "create"},
        {"resource": "tag", "action": "create"},
        {"resource": "tag", "action": "delete"},
        {"resource": "scan", "action": "create"}
      ]
    }
  ]
}
EOF
)

# Récupération de l'ID du projet
PROJECT_ID=$(curl -s -u "${HARBOR_ADMIN}:${HARBOR_PASSWORD}" "${HARBOR_URL}/api/v2.0/projects?name=${PROJECT_NAME}" | sed -n 's/.*"project_id":\([0-9]*\).*/\1/p' | head -n 1)

ROBOT_RESPONSE=$(curl -s -X POST "${HARBOR_URL}/api/v2.0/robots" \
    -u "${HARBOR_ADMIN}:${HARBOR_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d "${ROBOT_PAYLOAD}" || true)

ROBOT_SECRET=$(echo "${ROBOT_RESPONSE}" | sed -n 's/.*"secret":"\([^"]*\)".*/\1/p')

if [ -z "${ROBOT_SECRET}" ]; then
    echo "    Le robot existe probablement déjà. Utilisation du mot de passe standard prédéfini."
    ROBOT_SECRET="RobotSecretOmniPay2026!"
else
    echo "    Compte robot créé avec succès !"
fi

FULL_ROBOT_USER="robot\$${ROBOT_NAME}"

# 5. Injection du secret Docker dans les namespaces Kubernetes
echo "--> [5/5] Création du Secret 'harbor-registry-secret' dans les namespaces K3s..."
NAMESPACES=("omnipay-dev" "omnipay-recette" "omnipay-prod" "jenkins")

for NS in "${NAMESPACES[@]}"; do
    kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret docker-registry harbor-registry-secret \
        --namespace="${NS}" \
        --docker-server="harbor.omnipay.local:30002" \
        --docker-username="${FULL_ROBOT_USER}" \
        --docker-password="${ROBOT_SECRET}" \
        --docker-email="devsecops@omnipay.local" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "    Secret synchronisé dans le namespace: ${NS}"
done

echo "==================================================================="
echo " Initialisation terminée avec succès !"
echo " Registre : harbor.omnipay.local:30002/${PROJECT_NAME}"
echo " Robot User : ${FULL_ROBOT_USER}"
echo "==================================================================="
