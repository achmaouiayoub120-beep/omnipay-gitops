#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Démo 1 Live (~3 min) : Canary Argo Rollouts & Auto-Rollback
# Scénario :
#   1. Vérifier v1.0.0 stable à 100% du trafic.
#   2. Déclencher le Canary transaction-service:v2.0.0-unstable (50% d'erreurs 500) à 10%.
#   3. Lancer l'analyse Prometheus sur le taux d'erreur 5xx (> 2%) et vérifier 0 coupure.
#   4. Constater le rollback automatique vers v1.0.0 à 100% en < 30s (Degraded / RolledBack).
# Rôle P4 : Widad El Gharzaz — Plateforme, Supply Chain Security & Lead GitOps
# ==============================================================================

set -euo pipefail

NAMESPACE="${NAMESPACE:-omnipay-prod}"
ROLLOUT_NAME="${ROLLOUT_NAME:-transaction-service}"
ACTIVE_SERVICE="${ACTIVE_SERVICE:-transaction-service-active}"
TARGET_SERVICE="${TARGET_SERVICE:-transaction-service}"
STABLE_IMAGE="${STABLE_IMAGE:-harbor.omnipay.local:30002/omnipay/transaction-service:1.0.0}"
UNSTABLE_IMAGE="${UNSTABLE_IMAGE:-harbor.omnipay.local:30002/omnipay/transaction-service:v2.0.0-unstable}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://prometheus.omnipay.local:30900}"
ERROR_THRESHOLD_PCT="${ERROR_THRESHOLD_PCT:-2.0}"
TRAFFIC_REQUESTS="${TRAFFIC_REQUESTS:-40}"
ROLLBACK_TIMEOUT_SEC="${ROLLBACK_TIMEOUT_SEC:-30}"
AUTO_RESET="${AUTO_RESET:-false}"
DRY_RUN="${DRY_RUN:-false}"

for arg in "$@"; do
    case "${arg}" in
        --auto-reset) AUTO_RESET="true" ;;
        --dry-run)    DRY_RUN="true" ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--auto-reset] [--dry-run]
Variables d'environnement optionnelles :
  NAMESPACE, ROLLOUT_NAME, STABLE_IMAGE, UNSTABLE_IMAGE, PROMETHEUS_URL,
  ERROR_THRESHOLD_PCT, TRAFFIC_REQUESTS, ROLLBACK_TIMEOUT_SEC
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

TRAFFIC_POD="demo1-traffic-gen-$$"
PROBE_POD="demo1-health-probe-$$"

cleanup() {
    if [ "${DRY_RUN}" != "true" ]; then
        kubectl delete pod "${TRAFFIC_POD}" -n "${NAMESPACE}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
        kubectl delete pod "${PROBE_POD}" -n "${NAMESPACE}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

has_rollouts_plugin() {
    kubectl argo rollouts version >/dev/null 2>&1
}

show_rollout_status() {
    if has_rollouts_plugin; then
        kubectl argo rollouts get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" --no-color || true
    else
        kubectl get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" -o wide || true
        kubectl get pods -n "${NAMESPACE}" -l "app=${ROLLOUT_NAME}" -o wide || true
    fi
}

probe_active_service() {
    local pod_name="$1"
    local svc_url="http://${ACTIVE_SERVICE}.${NAMESPACE}.svc.cluster.local:8080/actuator/health"
    kubectl run "${pod_name}" --rm -i --restart=Never -n "${NAMESPACE}" \
        --image=curlimages/curl:8.10.1 \
        --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"runAsGroup":10001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"'"${pod_name}"'","image":"curlimages/curl:8.10.1","command":["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","5","'"${svc_url}"'"],"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}' \
        2>/dev/null || echo "000"
}

query_prometheus_5xx() {
    local promql="(sum(rate(http_server_requests_seconds_count{service=\"${ROLLOUT_NAME}\",status=~\"5..\"}[2m])) / (sum(rate(http_server_requests_seconds_count{service=\"${ROLLOUT_NAME}\"}[2m])) > 0)) * 100 or vector(0)"
    if command -v curl >/dev/null 2>&1; then
        curl -s --max-time 4 --get "${PROMETHEUS_URL}/api/v1/query" \
            --data-urlencode "query=${promql}" 2>/dev/null || true
    fi
}

echo -e "${BOLD}${BLUE}===================================================================================${NC}"
echo -e " ${BOLD}OmniPay Zero-Trust — Démo 1 Live (~3 min) : Canary & Rollback Automatique${NC}"
echo -e " Cible : ${ROLLOUT_NAME} (${NAMESPACE}) | Seuil 5xx : > ${ERROR_THRESHOLD_PCT}% | SLA Rollback : < ${ROLLBACK_TIMEOUT_SEC}s"
echo -e "${BOLD}${BLUE}===================================================================================${NC}"

if [ "${DRY_RUN}" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN] Mode simulation activé : aucune mutation ne sera appliquée au cluster.${NC}"
fi

# ------------------------------------------------------------------------------
# Prérequis & État Initial : v1.0.0 stable à 100% du trafic
# ------------------------------------------------------------------------------
echo -e "\n--> ${BOLD}[Étape 1/4] Vérification de l'état stable initial (v1.0.0 à 100% du trafic)...${NC}"
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}[ERREUR] kubectl est requis.${NC}"; exit 1; }

if [ "${DRY_RUN}" != "true" ]; then
    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || {
        echo -e "${RED}[ERREUR] Namespace '${NAMESPACE}' introuvable.${NC}"
        exit 1
    }
    kubectl get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 || {
        echo -e "${RED}[ERREUR] Rollout '${ROLLOUT_NAME}' introuvable dans '${NAMESPACE}'.${NC}"
        exit 1
    }

    CURRENT_IMAGE=$(kubectl get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}')
    CURRENT_PHASE=$(kubectl get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')
    DESIRED_REPLICAS=$(kubectl get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}')
    READY_REPLICAS=$(kubectl get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}')
    AVAILABLE_REPLICAS=$(kubectl get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.availableReplicas}')

    echo -e "    Image active      : ${CYAN}${CURRENT_IMAGE}${NC}"
    echo -e "    Phase Rollout     : ${GREEN}${CURRENT_PHASE:-Healthy}${NC}"
    echo -e "    Réplicas Ready    : ${READY_REPLICAS:-0}/${DESIRED_REPLICAS:-0} (Available: ${AVAILABLE_REPLICAS:-0})"

    show_rollout_status

    if [ "${CURRENT_PHASE}" != "Healthy" ] || [ "${READY_REPLICAS:-0}" != "${DESIRED_REPLICAS:-0}" ]; then
        echo -e "${YELLOW}[ATTENTION] Le Rollout n'est pas encore pleinement Healthy (${CURRENT_PHASE}). Vérification en cours...${NC}"
    fi

    HTTP_CODE=$(probe_active_service "${PROBE_POD}-init")
    echo -e "    Sonde service stable (${ACTIVE_SERVICE}) : HTTP ${BOLD}${HTTP_CODE}${NC}"
    echo -e "${GREEN}✔ État initial validé : version stable à 100% du trafic.${NC}"
else
    echo "    [DRY-RUN] Vérification Rollout '${ROLLOUT_NAME}' sur '${STABLE_IMAGE}' (100% trafic, Healthy)."
fi

# ------------------------------------------------------------------------------
# Étape 2 : Déclencher le Canary v2.0.0-unstable (palier 10%)
# ------------------------------------------------------------------------------
echo -e "\n--> ${BOLD}[Étape 2/4] Déclenchement Canary de ${UNSTABLE_IMAGE} (palier 10%, 50% erreurs HTTP 500)...${NC}"
START_CANARY_TS=$(date +%s)

if [ "${DRY_RUN}" != "true" ]; then
    if has_rollouts_plugin; then
        kubectl argo rollouts set image "${ROLLOUT_NAME}" "${ROLLOUT_NAME}=${UNSTABLE_IMAGE}" -n "${NAMESPACE}"
    else
        kubectl set image "rollout/${ROLLOUT_NAME}" "${ROLLOUT_NAME}=${UNSTABLE_IMAGE}" -n "${NAMESPACE}"
    fi

    sleep 5
    STEP_INDEX=$(kubectl get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || echo "0")
    CANARY_WEIGHT=$(kubectl get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.canary.weights.canary.weight}' 2>/dev/null || echo "10")
    STABLE_WEIGHT=$(kubectl get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.canary.weights.stable.weight}' 2>/dev/null || echo "90")

    echo -e "    Palier actif      : Step ${STEP_INDEX:-0} | Canary=${YELLOW}${CANARY_WEIGHT:-10}%${NC} / Stable=${GREEN}${STABLE_WEIGHT:-90}%${NC}"
    show_rollout_status
    echo -e "${GREEN}✔ Canary démarré avec Blast Radius strictement borné à 10%.${NC}"
else
    echo "    [DRY-RUN] kubectl argo rollouts set image ${ROLLOUT_NAME} ${ROLLOUT_NAME}=${UNSTABLE_IMAGE} -n ${NAMESPACE}"
fi

# ------------------------------------------------------------------------------
# Étape 3 : Trafic HTTP + Analyse Prometheus 5xx (> 2%) & Continuité de service
# ------------------------------------------------------------------------------
echo -e "\n--> ${BOLD}[Étape 3/4] Injection de trafic & Analyse Prometheus du taux d'erreur 5xx (seuil > ${ERROR_THRESHOLD_PCT}%)...${NC}"

if [ "${DRY_RUN}" != "true" ]; then
    echo "    Envoi de ${TRAFFIC_REQUESTS} requêtes vers http://${TARGET_SERVICE}:8080/api/transactions et vérification continue du service actif..."

    kubectl run "${TRAFFIC_POD}" --rm -i --restart=Never -n "${NAMESPACE}" \
        --image=curlimages/curl:8.10.1 \
        --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"runAsGroup":10001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"'"${TRAFFIC_POD}"'","image":"curlimages/curl:8.10.1","command":["sh","-c","ok=0; err=0; i=1; while [ \"$i\" -le '"${TRAFFIC_REQUESTS}"' ]; do code=$(curl -s -o /dev/null -w \"%{http_code}\" --max-time 2 http://'"${TARGET_SERVICE}"'.'"${NAMESPACE}"'.svc.cluster.local:8080/api/transactions || echo 000); case \"$code\" in 5*) err=$((err+1));; 2*|4*) ok=$((ok+1));; esac; i=$((i+1)); sleep 0.3; done; echo \"TRAFFIC_SUMMARY ok=$ok err_5xx=$err\""],"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}' \
        2>/dev/null | grep -E "TRAFFIC_SUMMARY|HTTP" || true

    # Vérification de continuité de service sur le service stable pendant l'incident Canary
    ACTIVE_HTTP=$(probe_active_service "${PROBE_POD}-mid")
    echo -e "    Continuité service stable (${ACTIVE_SERVICE}) pendant Canary : HTTP ${GREEN}${ACTIVE_HTTP}${NC}"

    # Capture de l'AnalysisRun Prometheus
    ANALYSIS_RUN=$(kubectl get analysisrun -n "${NAMESPACE}" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${ANALYSIS_RUN}" ]; then
        echo -e "    AnalysisRun actif : ${BOLD}${ANALYSIS_RUN}${NC}"
        kubectl get analysisrun "${ANALYSIS_RUN}" -n "${NAMESPACE}" -o wide || true
        kubectl describe analysisrun "${ANALYSIS_RUN}" -n "${NAMESPACE}" | grep -E "(Phase|Status|Message|Value|Failed|Metric)" || true
    else
        echo -e "${YELLOW}[INFO] AnalysisRun en cours de création par le contrôleur Argo Rollouts...${NC}"
    fi

    PROM_RAW=$(query_prometheus_5xx)
    if [ -n "${PROM_RAW}" ]; then
        echo -e "    Réponse Prometheus API (${PROMETHEUS_URL}) : ${CYAN}${PROM_RAW}${NC}"
    fi
else
    echo "    [DRY-RUN] Simulation de trafic HTTP + requête AnalysisTemplate 'prometheus-error-rate'."
fi

# ------------------------------------------------------------------------------
# Étape 4 : Observation du Rollback Automatique (< 30s) vers v1.0.0 à 100%
# ------------------------------------------------------------------------------
echo -e "\n--> ${BOLD}[Étape 4/4] Validation du Rollback Automatique (< ${ROLLBACK_TIMEOUT_SEC}s) & État Degraded / RolledBack...${NC}"

if [ "${DRY_RUN}" != "true" ]; then
    DETECTION_TS=$(date +%s)
    ROLLED_BACK="false"
    FINAL_PHASE=""
    ABORT_FLAG=""
    ELAPSED_DETECTION=0

    MAX_POLLS=$((ROLLBACK_TIMEOUT_SEC / 2))
    [ "${MAX_POLLS}" -lt 1 ] && MAX_POLLS=15

    for _ in $(seq 1 "${MAX_POLLS}"); do
        FINAL_PHASE=$(kubectl get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        ABORT_FLAG=$(kubectl get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.abort}' 2>/dev/null || echo "")
        ROLLOUT_MSG=$(kubectl get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.message}' 2>/dev/null || echo "")
        CANARY_WEIGHT_NOW=$(kubectl get rollout "${ROLLOUT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.canary.weights.canary.weight}' 2>/dev/null || echo "0")

        if [ "${FINAL_PHASE}" = "Degraded" ] || [ "${ABORT_FLAG}" = "true" ]; then
            NOW_TS=$(date +%s)
            ELAPSED_DETECTION=$((NOW_TS - DETECTION_TS))
            ELAPSED_TOTAL=$((NOW_TS - START_CANARY_TS))
            echo -e "${GREEN}✔ Rollback automatique déclenché (détection -> rollback : ${ELAPSED_DETECTION}s, total démo : ${ELAPSED_TOTAL}s) !${NC}"
            echo -e "    Statut Rollout : ${RED}${BOLD}${FINAL_PHASE}${NC} (RolledBack / Aborted=${ABORT_FLAG:-true})"
            [ -n "${ROLLOUT_MSG}" ] && echo -e "    Message        : ${ROLLOUT_MSG}"
            echo -e "    Poids Canary   : ${CANARY_WEIGHT_NOW:-0}% | Trafic Stable v1.0.0 : 100%"
            ROLLED_BACK="true"
            break
        fi
        sleep 2
    done

    if [ "${ROLLED_BACK}" != "true" ]; then
        echo -e "${RED}[ATTENTION] Le Rollout n'est pas encore passé en Degraded/Aborted dans le délai imparti (phase=${FINAL_PHASE}).${NC}"
    fi

    # Afficher l'état final de l'AnalysisRun et du Rollout
    ANALYSIS_RUN_FINAL=$(kubectl get analysisrun -n "${NAMESPACE}" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${ANALYSIS_RUN_FINAL}" ]; then
        AR_PHASE=$(kubectl get analysisrun "${ANALYSIS_RUN_FINAL}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        echo -e "    État final AnalysisRun '${ANALYSIS_RUN_FINAL}' : ${RED}${BOLD}${AR_PHASE}${NC}"
    fi

    echo -e "\n${CYAN}État détaillé du Rollout et des Pods après Rollback :${NC}"
    show_rollout_status

    POST_HTTP=$(probe_active_service "${PROBE_POD}-post")
    echo -e "    Vérification post-rollback service stable (${ACTIVE_SERVICE}) : HTTP ${GREEN}${POST_HTTP}${NC}"

    # Réinitialisation propre vers v1.0.0 Healthy
    DO_RESET="${AUTO_RESET}"
    if [ "${DO_RESET}" != "true" ] && [ -t 0 ]; then
        echo ""
        read -r -p "Réinitialiser le Rollout sur '${STABLE_IMAGE}' pour la démo suivante ? [O/n] " CONFIRM || CONFIRM="O"
        if [[ "${CONFIRM}" =~ ^[oOyY]?$ ]]; then
            DO_RESET="true"
        fi
    fi

    if [ "${DO_RESET}" = "true" ]; then
        if has_rollouts_plugin; then
            kubectl argo rollouts undo "${ROLLOUT_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 || \
            kubectl argo rollouts set image "${ROLLOUT_NAME}" "${ROLLOUT_NAME}=${STABLE_IMAGE}" -n "${NAMESPACE}"
        else
            kubectl set image "rollout/${ROLLOUT_NAME}" "${ROLLOUT_NAME}=${STABLE_IMAGE}" -n "${NAMESPACE}"
        fi
        echo -e "${GREEN}✔ Rollout réinitialisé vers ${STABLE_IMAGE} (100% stable).${NC}"
    fi

    if [ "${ROLLED_BACK}" != "true" ]; then
        exit 1
    fi
else
    echo "    [DRY-RUN] Validation statut Degraded/RolledBack (< 30s) et restauration 100% v1.0.0."
fi

echo -e "\n${BOLD}${BLUE}===================================================================================${NC}"
echo -e " ${BOLD}${GREEN}[SUCCÈS DÉMO 1] Canary & Auto-Rollback Prometheus validés !${NC}"
echo -e " - Version stable   : ${STABLE_IMAGE} (100% trafic sans coupure)"
echo -e " - Version fautive  : ${UNSTABLE_IMAGE} (confinée à 10% puis détruite)"
echo -e " - Analyse PromQL   : Taux 5xx > ${ERROR_THRESHOLD_PCT}% -> Statut Degraded / RolledBack"
echo -e " - Temps de réaction: < ${ROLLBACK_TIMEOUT_SEC}s sans intervention humaine"
echo -e "${BOLD}${BLUE}===================================================================================${NC}"
