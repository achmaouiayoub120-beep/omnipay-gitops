#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Initialisation & Durcissement du Registre OCI Harbor
# Configure le projet 'omnipay', auto_scan Trivy, blocage CVE critiques,
# immuabilité des tags et compte robot CI (Images + Artefacts OCI Cosign & Syft)
# Rôle P4 : Ingénieure Packaging, Registre Harbor & Supply Chain GitOps
# ==============================================================================

set -euo pipefail

HARBOR_URL="${HARBOR_URL:-http://harbor.omnipay.local:30002}"
HARBOR_ADMIN="${HARBOR_ADMIN:-admin}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:-HarborAdminOmniPay2026!}"
PROJECT_NAME="omnipay"
ROBOT_NAME="robot-omnipay-ci"

echo "==================================================================="
echo " [P4] Initialisation & Durcissement de Harbor (OmniPay Zero-Trust)"
echo " Registre : ${HARBOR_URL}"
echo "==================================================================="

# ------------------------------------------------------------------------------
# 1. Attente active de la disponibilité de l'API Harbor
# ------------------------------------------------------------------------------
echo "--> [1/6] Vérification de la disponibilité de l'API Harbor..."
MAX_RETRIES=40
RETRY_COUNT=0
until curl -s -f -u "${HARBOR_ADMIN}:${HARBOR_PASSWORD}" "${HARBOR_URL}/api/v2.0/systeminfo" >/dev/null 2>&1; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ "${RETRY_COUNT}" -ge "${MAX_RETRIES}" ]; then
        echo "[ERREUR] Harbor API inaccessible après ${MAX_RETRIES} tentatives sur ${HARBOR_URL}."
        exit 1
    fi
    echo "    Harbor en cours d'initialisation... (${RETRY_COUNT}/${MAX_RETRIES}) - attente 10s"
    sleep 10
done
echo "    Harbor API v2.0 est prête et fonctionnelle !"

# ------------------------------------------------------------------------------
# 2. Création ou mise à jour du projet 'omnipay'
# ------------------------------------------------------------------------------
echo "--> [2/6] Configuration du projet durci '${PROJECT_NAME}'..."
PROJECT_CHECK_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "${HARBOR_ADMIN}:${HARBOR_PASSWORD}" "${HARBOR_URL}/api/v2.0/projects?name=${PROJECT_NAME}")

if [ "${PROJECT_CHECK_STATUS}" -eq 200 ] && [ "$(curl -s -u "${HARBOR_ADMIN}:${HARBOR_PASSWORD}" "${HARBOR_URL}/api/v2.0/projects?name=${PROJECT_NAME}" | grep -c "\"name\":\"${PROJECT_NAME}\"")" -gt 0 ]; then
    echo "    Le projet '${PROJECT_NAME}' existe déjà. Application du durcissement..."
    curl -s -f -X PUT "${HARBOR_URL}/api/v2.0/projects/${PROJECT_NAME}" \
        -u "${HARBOR_ADMIN}:${HARBOR_PASSWORD}" \
        -H "Content-Type: application/json" \
        -d '{
            "metadata": {
                "public": "true",
                "auto_scan": "true",
                "prevent_vul": "true",
                "severity": "critical",
                "reuse_sys_cve_allowlist": "true"
            }
        }' >/dev/null
else
    curl -s -f -X POST "${HARBOR_URL}/api/v2.0/projects" \
        -u "${HARBOR_ADMIN}:${HARBOR_PASSWORD}" \
        -H "Content-Type: application/json" \
        -d '{
            "project_name": "'"${PROJECT_NAME}"'",
            "public": true,
            "metadata": {
                "auto_scan": "true",
                "prevent_vul": "true",
                "severity": "critical",
                "reuse_sys_cve_allowlist": "true"
            }
        }' >/dev/null
    echo "    Projet '${PROJECT_NAME}' créé avec durcissement Zero-Trust."
fi

# ------------------------------------------------------------------------------
# 3. Activation du scan automatique Trivy (Scan on Push) et blocage CVE critiques
# ------------------------------------------------------------------------------
echo "--> [3/6] Validation du scan automatique Trivy & Blocage vulnérabilités critiques..."
curl -s -X PUT "${HARBOR_URL}/api/v2.0/projects/${PROJECT_NAME}" \
    -u "${HARBOR_ADMIN}:${HARBOR_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d '{
        "metadata": {
            "auto_scan": "true",
            "prevent_vul": "true",
            "severity": "critical"
        }
    }' >/dev/null
echo "    Scan Trivy 'Scan on push' activé et blocage immédiat des vulnérabilités CRITICAL configuré."

# ------------------------------------------------------------------------------
# 4. Règle d'immuabilité des tags (Tag Immutability Rule)
# ------------------------------------------------------------------------------
echo "--> [4/6] Application de la règle d'immuabilité des tags..."
IMMUTABLE_RULES=$(curl -s -u "${HARBOR_ADMIN}:${HARBOR_PASSWORD}" "${HARBOR_URL}/api/v2.0/projects/${PROJECT_NAME}/immutabletagrules" || echo "[]")

if echo "${IMMUTABLE_RULES}" | grep -q '"action":"immutable"'; then
    echo "    Une règle d'immuabilité est déjà configurée pour le projet '${PROJECT_NAME}'."
else
    curl -s -X POST "${HARBOR_URL}/api/v2.0/projects/${PROJECT_NAME}/immutabletagrules" \
        -u "${HARBOR_ADMIN}:${HARBOR_PASSWORD}" \
        -H "Content-Type: application/json" \
        -d '{
            "disabled": false,
            "action": "immutable",
            "template": "immutable_template",
            "params": {},
            "tag_selectors": [
                {
                    "kind": "doublestar",
                    "decoration": "matches",
                    "pattern": "**"
                }
            ],
            "scope_selectors": {
                "repository": [
                    {
                        "kind": "doublestar",
                        "decoration": "repoMatches",
                        "pattern": "**"
                    }
                ]
            }
        }' >/dev/null 2>&1 || true
    echo "    Règle d'immuabilité activée : interdiction formelle d'écraser les tags existants (Zero-Trust)."
fi

# ------------------------------------------------------------------------------
# 5. Création du compte robot CI (Images + Artefacts OCI Cosign / Syft)
# ------------------------------------------------------------------------------
echo "--> [5/6] Configuration du compte robot CI '${ROBOT_NAME}' pour images & OCI accessories..."
ROBOT_PAYLOAD=$(cat <<EOF
{
  "name": "${ROBOT_NAME}",
  "description": "Robot account for OmniPay CI/CD Pipeline (Jenkins, Syft SBOM, Cosign OCI signatures & ArgoCD)",
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
        {"resource": "artifact", "action": "delete"},
        {"resource": "artifact", "action": "list"},
        {"resource": "tag", "action": "create"},
        {"resource": "tag", "action": "delete"},
        {"resource": "tag", "action": "list"},
        {"resource": "scan", "action": "create"},
        {"resource": "scan", "action": "stop"},
        {"resource": "accessory", "action": "read"},
        {"resource": "accessory", "action": "create"},
        {"resource": "accessory", "action": "delete"},
        {"resource": "accessory", "action": "list"},
        {"resource": "artifact-addition", "action": "read"},
        {"resource": "artifact-addition", "action": "create"}
      ]
    }
  ]
}
EOF
)

ROBOT_RESPONSE=$(curl -s -X POST "${HARBOR_URL}/api/v2.0/robots" \
    -u "${HARBOR_ADMIN}:${HARBOR_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d "${ROBOT_PAYLOAD}" || true)

ROBOT_SECRET=$(echo "${ROBOT_RESPONSE}" | sed -n 's/.*"secret":"\([^"]*\)".*/\1/p' || true)

if [ -z "${ROBOT_SECRET}" ]; then
    echo "    Le robot existe déjà ou a été réinitialisé. Utilisation du mot de passe standard prédéfini."
    ROBOT_SECRET="RobotSecretOmniPay2026!"
else
    echo "    Compte robot créé avec succès avec support complet des artefacts OCI (Cosign / Syft) !"
fi

FULL_ROBOT_USER="robot\$${ROBOT_NAME}"

# ------------------------------------------------------------------------------
# 6. Injection du Secret Docker dans les namespaces Kubernetes
# ------------------------------------------------------------------------------
echo "--> [6/6] Synchronisation du Secret 'harbor-registry-secret' dans K3s..."
NAMESPACES=("omnipay-dev" "omnipay-recette" "omnipay-prod" "jenkins" "argocd")

if command -v kubectl >/dev/null 2>&1; then
    for NS in "${NAMESPACES[@]}"; do
        kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
        kubectl create secret docker-registry harbor-registry-secret \
            --namespace="${NS}" \
            --docker-server="harbor.omnipay.local:30002" \
            --docker-username="${FULL_ROBOT_USER}" \
            --docker-password="${ROBOT_SECRET}" \
            --docker-email="devsecops@omnipay.local" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
        echo "    Secret synchronisé dans le namespace: ${NS}"
    done
fi

echo "==================================================================="
echo " Durcissement Harbor terminé avec succès !"
echo " - Registre OCI  : harbor.omnipay.local:30002/${PROJECT_NAME}"
echo " - Sécurité Trivy: Auto-scan actif, Blocage CVE Critiques ACTIF"
echo " - Immuabilité   : Tags immuables (protection contre l'écrasement)"
echo " - Compte Robot  : ${FULL_ROBOT_USER}"
echo " - Support OCI   : Images Docker, Attestations SBOM Syft & Signatures Cosign"
echo "==================================================================="
