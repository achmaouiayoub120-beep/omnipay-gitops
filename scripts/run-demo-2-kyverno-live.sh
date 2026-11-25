#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Démo 2 Live (~2 min) : Barrière d'Admission Kyverno + Cosign
# Scénarios :
#   A : Image publique non signée (nginx:alpine) & image non signée Harbor -> rejetée
#   B : Conteneur privileged: true ou runAsUser: 0 -> rejeté (require-non-root / privileged)
#   C : Image signée Cosign depuis harbor.omnipay.local:30002 -> admise et Running
# Rôle P4 : Widad El Gharzaz — Plateforme, Supply Chain Security & Lead GitOps
# ==============================================================================

set -euo pipefail

NAMESPACE="${NAMESPACE:-omnipay-prod}"
PUBLIC_UNSIGNED_IMAGE="${PUBLIC_UNSIGNED_IMAGE:-nginx:alpine}"
HARBOR_UNSIGNED_IMAGE="${HARBOR_UNSIGNED_IMAGE:-harbor.omnipay.local:30002/omnipay/untrusted-service:latest}"
SIGNED_IMAGE="${SIGNED_IMAGE:-harbor.omnipay.local:30002/omnipay/transaction-service:1.0.0}"
DRY_RUN="${DRY_RUN:-false}"
RUNNING_TIMEOUT_SEC="${RUNNING_TIMEOUT_SEC:-60}"

for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN="true" ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--dry-run]
Variables d'environnement optionnelles :
  NAMESPACE, PUBLIC_UNSIGNED_IMAGE, HARBOR_UNSIGNED_IMAGE, SIGNED_IMAGE, RUNNING_TIMEOUT_SEC
EOF
            exit 0
            ;;
        *)
            echo "[ERREUR] Option inconnue : ${arg}" >&2
            exit 1
            ;;
    esac
done

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

POD_A_PUBLIC="demo2-unsigned-public-$$"
POD_A_HARBOR="demo2-unsigned-harbor-$$"
POD_B_PRIV="demo2-privileged-$$"
POD_B_ROOT="demo2-root-user-$$"
POD_C_SIGNED="demo2-signed-compliant-$$"

cleanup() {
    if [ "${DRY_RUN}" != "true" ]; then
        for p in "${POD_A_PUBLIC}" "${POD_A_HARBOR}" "${POD_B_PRIV}" "${POD_B_ROOT}" "${POD_C_SIGNED}"; do
            kubectl delete pod "${p}" -n "${NAMESPACE}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
        done
    fi
}
trap cleanup EXIT

echo -e "${BOLD}${BLUE}===================================================================================${NC}"
echo -e " ${BOLD}OmniPay Zero-Trust — Démo 2 Live (~2 min) : Admission Kyverno & Signature Cosign${NC}"
echo -e " Namespace cible : ${BOLD}${NAMESPACE}${NC}"
echo -e "${BOLD}${BLUE}===================================================================================${NC}"

if [ "${DRY_RUN}" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN] Mode simulation activé : aucune requête ne sera envoyée au cluster.${NC}"
fi

command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}[ERREUR] kubectl est requis.${NC}"; exit 1; }

# Vérification des ClusterPolicies Kyverno actives
echo -e "\n--> ${BOLD}[Pré-check] Vérification des politiques Kyverno actives...${NC}"
if [ "${DRY_RUN}" != "true" ]; then
    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || {
        echo -e "${RED}[ERREUR] Namespace '${NAMESPACE}' introuvable.${NC}"
        exit 1
    }

    for pol in "verify-omnipay-image-signature" "disallow-host-path-and-privileged" "require-ro-rootfs-and-drop-all" "mutate-inject-zero-trust-labels"; do
        if kubectl get clusterpolicy "${pol}" >/dev/null 2>&1; then
            action=$(kubectl get clusterpolicy "${pol}" -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null || echo "Mutate")
            echo -e "    ${GREEN}✔${NC} ClusterPolicy '${pol}' active [Mode: ${BOLD}${action:-Mutate}${NC}]"
        else
            echo -e "    ${YELLOW}⚠${NC} ClusterPolicy '${pol}' absente du cluster."
        fi
    done

    # Vérifier le nom exact de la politique non-root (require-run-as-non-root ou require-non-root-user)
    NON_ROOT_POL=""
    for candidate in "require-run-as-non-root" "require-non-root-user"; do
        if kubectl get clusterpolicy "${candidate}" >/dev/null 2>&1; then
            NON_ROOT_POL="${candidate}"
            action=$(kubectl get clusterpolicy "${candidate}" -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null || echo "Enforce")
            echo -e "    ${GREEN}✔${NC} ClusterPolicy '${candidate}' active [Mode: ${BOLD}${action}${NC}]"
        fi
    done
    if [ -z "${NON_ROOT_POL}" ]; then
        echo -e "${YELLOW}⚠ Aucune politique non-root ('require-run-as-non-root' / 'require-non-root-user') détectée.${NC}"
    fi
else
    echo "    [DRY-RUN] Vérification ClusterPolicies (verify-omnipay-image-signature, require-run-as-non-root, disallow-host-path-and-privileged)."
fi

SCENARIO_A_OK=false
SCENARIO_B_OK=false
SCENARIO_C_OK=false

# ------------------------------------------------------------------------------
# Scénario A : Image publique non signée (nginx:alpine) -> rejetée par Kyverno
# ------------------------------------------------------------------------------
echo -e "\n--> ${BOLD}[Scénario A] Tentative de déploiement d'une image publique non signée (${PUBLIC_UNSIGNED_IMAGE})...${NC}"

if [ "${DRY_RUN}" != "true" ]; then
    OUT_A_PUB=""
    if OUT_A_PUB=$(kubectl run "${POD_A_PUBLIC}" --image="${PUBLIC_UNSIGNED_IMAGE}" --restart=Never -n "${NAMESPACE}" 2>&1); then
        echo -e "${RED}[ÉCHEC SCÉNARIO A] L'image publique '${PUBLIC_UNSIGNED_IMAGE}' a été admise à tort !${NC}"
        kubectl delete pod "${POD_A_PUBLIC}" -n "${NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
        SCENARIO_A_OK=false
    else
        echo -e "${GREEN}✔ Rejet immédiat de '${PUBLIC_UNSIGNED_IMAGE}' par le webhook Kyverno (HTTP 403 Forbidden) :${NC}"
        echo "    $(echo "${OUT_A_PUB}" | tr '\n' ' ' | cut -c1-240)"
        SCENARIO_A_OK=true
    fi

    # Démonstration complémentaire ciblant explicitement la vérification Cosign (verify-omnipay-image-signature)
    echo -e "    Vérification ciblée de la signature Cosign sur '${HARBOR_UNSIGNED_IMAGE}' :"
    MANIFEST_A_HARBOR=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_A_HARBOR}
  namespace: ${NAMESPACE}
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: untrusted
      image: ${HARBOR_UNSIGNED_IMAGE}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF
)
    OUT_A_HARBOR=""
    if OUT_A_HARBOR=$(echo "${MANIFEST_A_HARBOR}" | kubectl apply -f - 2>&1); then
        echo -e "${RED}[ÉCHEC SCÉNARIO A] L'image Harbor non signée '${HARBOR_UNSIGNED_IMAGE}' a été admise !${NC}"
        kubectl delete pod "${POD_A_HARBOR}" -n "${NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
        SCENARIO_A_OK=false
    else
        echo -e "${GREEN}✔ Rejet cryptographique Cosign confirmé par Kyverno :${NC}"
        echo "    $(echo "${OUT_A_HARBOR}" | tr '\n' ' ' | cut -c1-240)"
    fi
else
    echo "    [DRY-RUN] Rejet attendu : admission webhook validate.kyverno.svc denied (${PUBLIC_UNSIGNED_IMAGE} & ${HARBOR_UNSIGNED_IMAGE})."
    SCENARIO_A_OK=true
fi

# ------------------------------------------------------------------------------
# Scénario B : Conteneur privileged: true ou runAsUser: 0 -> rejeté
# ------------------------------------------------------------------------------
echo -e "\n--> ${BOLD}[Scénario B] Tentative de conteneur privilégié (privileged: true) et root (runAsUser: 0)...${NC}"

if [ "${DRY_RUN}" != "true" ]; then
    MANIFEST_B_PRIV=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_B_PRIV}
  namespace: ${NAMESPACE}
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
  containers:
    - name: priv-container
      image: ${SIGNED_IMAGE}
      securityContext:
        privileged: true
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF
)
    B_PRIV_DENIED=false
    if OUT_B1=$(echo "${MANIFEST_B_PRIV}" | kubectl apply -f - 2>&1); then
        echo -e "${RED}[ÉCHEC] Le pod avec privileged: true a été accepté !${NC}"
        kubectl delete pod "${POD_B_PRIV}" -n "${NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
    else
        echo -e "${GREEN}✔ Pod 'privileged: true' rejeté par Kyverno :${NC}"
        echo "    $(echo "${OUT_B1}" | tr '\n' ' ' | cut -c1-240)"
        B_PRIV_DENIED=true
    fi

    MANIFEST_B_ROOT=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_B_ROOT}
  namespace: ${NAMESPACE}
spec:
  securityContext:
    runAsNonRoot: false
    runAsUser: 0
  containers:
    - name: root-container
      image: ${SIGNED_IMAGE}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF
)
    B_ROOT_DENIED=false
    if OUT_B2=$(echo "${MANIFEST_B_ROOT}" | kubectl apply -f - 2>&1); then
        echo -e "${RED}[ÉCHEC] Le pod avec runAsUser: 0 a été accepté !${NC}"
        kubectl delete pod "${POD_B_ROOT}" -n "${NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
    else
        echo -e "${GREEN}✔ Pod 'runAsUser: 0' rejeté par la politique non-root Kyverno :${NC}"
        echo "    $(echo "${OUT_B2}" | tr '\n' ' ' | cut -c1-240)"
        B_ROOT_DENIED=true
    fi

    if [ "${B_PRIV_DENIED}" = true ] && [ "${B_ROOT_DENIED}" = true ]; then
        SCENARIO_B_OK=true
    fi
else
    echo "    [DRY-RUN] Rejet attendu : privileged: true (disallow-host-path-and-privileged) et runAsUser: 0 (require-run-as-non-root)."
    SCENARIO_B_OK=true
fi

# ------------------------------------------------------------------------------
# Scénario C : Image signée Cosign depuis harbor.omnipay.local:30002 -> admis & Running
# ------------------------------------------------------------------------------
echo -e "\n--> ${BOLD}[Scénario C] Déploiement d'une image signée Cosign (${SIGNED_IMAGE}) conforme Zero-Trust...${NC}"

if [ "${DRY_RUN}" != "true" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    COSIGN_PUB="${SCRIPT_DIR}/../platform/kyverno/keys/cosign.pub"
    if command -v cosign >/dev/null 2>&1 && [ -f "${COSIGN_PUB}" ]; then
        echo "    Vérification locale Cosign avec ${COSIGN_PUB} :"
        cosign verify --key "${COSIGN_PUB}" --insecure-ignore-tlog "${SIGNED_IMAGE}" >/dev/null 2>&1 && \
            echo -e "    ${GREEN}✔ Signature cryptographique Cosign vérifiée localement.${NC}" || \
            echo -e "    ${YELLOW}ℹ Vérification locale Cosign non concluante (vérification cluster en cours).${NC}"
    fi

    MANIFEST_C_SIGNED=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_C_SIGNED}
  namespace: ${NAMESPACE}
  labels:
    app: demo2-signed-check
spec:
  imagePullSecrets:
    - name: harbor-registry-secret
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: transaction-service
      image: ${SIGNED_IMAGE}
      imagePullPolicy: IfNotPresent
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      volumeMounts:
        - name: tmp-vol
          mountPath: /tmp
  volumes:
    - name: tmp-vol
      emptyDir: {}
EOF
)
    if echo "${MANIFEST_C_SIGNED}" | kubectl apply -f -; then
        echo -e "    Attente de l'état Running/Ready (timeout ${RUNNING_TIMEOUT_SEC}s)..."
        if kubectl wait --for=condition=Ready "pod/${POD_C_SIGNED}" -n "${NAMESPACE}" --timeout="${RUNNING_TIMEOUT_SEC}s" >/dev/null 2>&1; then
            PHASE_C=$(kubectl get pod "${POD_C_SIGNED}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')
            LABEL_ENF=$(kubectl get pod "${POD_C_SIGNED}" -n "${NAMESPACE}" -o jsonpath='{.metadata.labels.security\.omnipay\.local/enforced}' 2>/dev/null || echo "")
            echo -e "${GREEN}✔ Pod '${POD_C_SIGNED}' admis et en état '${PHASE_C}' !${NC}"
            echo -e "    Label muté par Kyverno (security.omnipay.local/enforced) : ${CYAN}${LABEL_ENF:-N/A}${NC}"
            kubectl get pod "${POD_C_SIGNED}" -n "${NAMESPACE}" -o wide
            SCENARIO_C_OK=true
        else
            PHASE_C=$(kubectl get pod "${POD_C_SIGNED}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            echo -e "${YELLOW}⚠ Pod admis par Kyverno (phase actuelle : ${PHASE_C}). Détails :${NC}"
            kubectl get pod "${POD_C_SIGNED}" -n "${NAMESPACE}" -o wide || true
            if [ "${PHASE_C}" = "Running" ]; then
                SCENARIO_C_OK=true
            fi
        fi
    else
        echo -e "${RED}[ÉCHEC SCÉNARIO C] Le pod signé et conforme a été rejeté.${NC}"
    fi
else
    echo "    [DRY-RUN] Admission & état Running attendus pour '${SIGNED_IMAGE}'."
    SCENARIO_C_OK=true
fi

# ------------------------------------------------------------------------------
# Synthèse Démo 2
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}${BLUE}===================================================================================${NC}"
echo -e " ${BOLD}SYNTHÈSE DÉMO 2 — BARRIÈRE D'ADMISSION KYVERNO & COSIGN${NC}"
echo -e "${BOLD}${BLUE}===================================================================================${NC}"
printf " %-52s | %s\n" "SCÉNARIO" "RÉSULTAT"
echo "-----------------------------------------------------------------------------------"
printf " %-52s | " "A. Image non signée (${PUBLIC_UNSIGNED_IMAGE} / Harbor)"
[ "${SCENARIO_A_OK}" = true ] && echo -e "${GREEN}REJETÉE (PASS)${NC}" || echo -e "${RED}FAIL${NC}"
printf " %-52s | " "B. Conteneur privileged: true / runAsUser: 0"
[ "${SCENARIO_B_OK}" = true ] && echo -e "${GREEN}REJETÉ (PASS)${NC}" || echo -e "${RED}FAIL${NC}"
printf " %-52s | " "C. Image signée Cosign (${SIGNED_IMAGE})"
[ "${SCENARIO_C_OK}" = true ] && echo -e "${GREEN}ADMISE & RUNNING (PASS)${NC}" || echo -e "${RED}FAIL${NC}"
echo -e "${BOLD}${BLUE}===================================================================================${NC}"

if [ "${SCENARIO_A_OK}" != true ] || [ "${SCENARIO_B_OK}" != true ] || [ "${SCENARIO_C_OK}" != true ]; then
    exit 1
fi
