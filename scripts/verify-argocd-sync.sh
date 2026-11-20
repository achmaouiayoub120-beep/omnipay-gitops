#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Vérification du Statut GitOps ArgoCD Multi-Environnements
# Affiche sous forme de tableau le SyncStatus et HealthStatus de dev, recette et prod
# Rôle P4 : Ingénieure Packaging, Registre Harbor & Supply Chain GitOps
# ==============================================================================

set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APPLICATIONS=("omnipay-dev" "omnipay-recette" "omnipay-prod")

# Codes couleurs ANSI
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${BOLD}===================================================================================================${NC}"
echo -e " ${BOLD}${BLUE}[P4] Statut de Synchronisation & Santé GitOps ArgoCD (OmniPay Zero-Trust)${NC}"
echo -e "${BOLD}===================================================================================================${NC}"

# Vérification des prérequis
if ! command -v kubectl >/dev/null 2>&1; then
    echo -e "${RED}[ERREUR] kubectl n'est pas disponible sur cet environnement.${NC}"
    exit 1
fi

# Vérification de l'accès au namespace ArgoCD
if ! kubectl get namespace "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
    echo -e "${RED}[ERREUR] Namespace '${ARGOCD_NAMESPACE}' introuvable dans le cluster K3s.${NC}"
    exit 1
fi

# En-tête du tableau
printf "\n"
printf "${BOLD}%-18s | %-16s | %-14s | %-14s | %-22s | %-10s${NC}\n" \
    "APPLICATION" "NAMESPACE CIBLE" "SYNC STATUS" "HEALTH STATUS" "MODE SYNC" "RÉVISION"
printf "%s\n" "---------------------------------------------------------------------------------------------------"

TOTAL_APPS=0
SYNCED_APPS=0
HEALTHY_APPS=0

for APP in "${APPLICATIONS[@]}"; do
    TOTAL_APPS=$((TOTAL_APPS + 1))
    
    # Vérification de l'existence de la CR Application
    APP_JSON=$(kubectl get application "${APP}" -n "${ARGOCD_NAMESPACE}" -o json 2>/dev/null || true)
    
    if [ -z "${APP_JSON}" ]; then
        printf "%-18s | %-16s | ${RED}%-14s${NC} | ${RED}%-14s${NC} | %-22s | %-10s\n" \
            "${APP}" "n/a" "Non Déployée" "Inconnu" "n/a" "n/a"
        continue
    fi

    # Extraction des données JSON via sed/grep (compatible sans jq)
    SYNC_STATUS=$(echo "${APP_JSON}" | grep -o '"sync":{"status":"[^"]*"' | head -n1 | cut -d'"' -f6 || echo "Unknown")
    HEALTH_STATUS=$(echo "${APP_JSON}" | grep -o '"health":{"status":"[^"]*"' | head -n1 | cut -d'"' -f6 || echo "Unknown")
    TARGET_NS=$(echo "${APP_JSON}" | grep -o '"destination":{"namespace":"[^"]*"' | head -n1 | cut -d'"' -f6 || echo "n/a")
    TARGET_REV=$(echo "${APP_JSON}" | grep -o '"targetRevision":"[^"]*"' | head -n1 | cut -d'"' -f4 || echo "main")
    
    # Vérification auto-sync
    HAS_AUTOSYNC=$(echo "${APP_JSON}" | grep -c '"automated":{' || true)
    if [ "${HAS_AUTOSYNC}" -gt 0 ]; then
        SYNC_MODE="Auto (Prune/Heal)"
    else
        SYNC_MODE="Manuel / Contrôlé"
    fi

    # Formatage couleur du SyncStatus
    case "${SYNC_STATUS}" in
        "Synced")
            COLOR_SYNC="${GREEN}"
            SYNCED_APPS=$((SYNCED_APPS + 1))
            ;;
        "OutOfSync")
            COLOR_SYNC="${YELLOW}"
            ;;
        *)
            COLOR_SYNC="${RED}"
            ;;
    esac

    # Formatage couleur du HealthStatus
    case "${HEALTH_STATUS}" in
        "Healthy")
            COLOR_HEALTH="${GREEN}"
            HEALTHY_APPS=$((HEALTHY_APPS + 1))
            ;;
        "Progressing")
            COLOR_HEALTH="${YELLOW}"
            ;;
        *)
            COLOR_HEALTH="${RED}"
            ;;
    esac

    printf "%-18s | %-16s | ${COLOR_SYNC}%-14s${NC} | ${COLOR_HEALTH}%-14s${NC} | %-22s | %-10s\n" \
        "${APP}" "${TARGET_NS}" "${SYNC_STATUS}" "${HEALTH_STATUS}" "${SYNC_MODE}" "${TARGET_REV}"
done

printf "%s\n\n" "---------------------------------------------------------------------------------------------------"
echo -e "${BOLD}Synthèse GitOps :${NC}"
echo -e " - Applications déclarées : ${BOLD}${TOTAL_APPS}${NC}"
echo -e " - Applications synchronisées (Synced) : ${BOLD}${SYNCED_APPS}/${TOTAL_APPS}${NC}"
echo -e " - Applications saines (Healthy) : ${BOLD}${HEALTHY_APPS}/${TOTAL_APPS}${NC}"
echo ""
echo -e "${CYAN}Rappel Zero-Trust :${NC}"
echo -e " • ${BOLD}dev & recette${NC} : Synchronisation automatique activée pour intégration continue rapide."
echo -e " • ${BOLD}prod${NC} : Synchronisation manuelle / contrôlée requise. Déclenchement via :"
echo -e "   ${BOLD}argocd app sync omnipay-prod${NC} (ou validation UI sur http://argocd.omnipay.local:30005)"
echo -e "${BOLD}===================================================================================================${NC}"
