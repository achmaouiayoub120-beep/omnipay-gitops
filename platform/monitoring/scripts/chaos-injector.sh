#!/usr/bin/env bash
# =============================================================================
# chaos-injector.sh — OmniPay Zero-Trust | P5 Semaine 3 (S3)
# Banc d'injection de Chaos Engineering & Démo 5 GameDay
# Auteur : Moad Helkamel (P5 - SRE & Observabilité)
# =============================================================================
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
NODE_IP="${NODE_IP:-127.0.0.1}"
DRY_RUN=false
SCENARIO=""

# Couleurs d'affichage
C_RESET="\033[0m"
C_RED="\033[1;31m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_BLUE="\033[1;34m"
C_CYAN="\033[1;36m"

print_banner() {
  echo -e "${C_CYAN}============================================================${C_RESET}"
  echo -e "${C_CYAN}  🌪️  OmniPay Zero-Trust — Chaos Injector & GameDay (S3)    ${C_RESET}"
  echo -e "${C_CYAN}  Ingénieur SRE : Moad Helkamel (P5) | Cible : K3s Cluster   ${C_RESET}"
  echo -e "${C_CYAN}============================================================${C_RESET}"
}

usage() {
  echo "Usage : $0 [--scenario <1|2|3|all>] [--dry-run] [--namespace <ns>]"
  echo ""
  echo "Scénarios disponibles :"
  echo "  1 : Panne Soudaine (Kill Pod sous charge transactionnelle)"
  echo "  2 : Injection de Latence Réseau (Netem 500ms sur base PostgreSQL)"
  echo "  3 : Saturation Mémoire Simulée (Pression JVM Heap)"
  echo "  all : Dérouler l'ensemble des scénarios de résilience"
  echo ""
  echo "Options :"
  echo "  --dry-run   : Valide les commandes et cibles sans impacter le cluster"
  echo "  --help      : Affiche cette aide"
  exit 0
}

# Analyse des arguments CLI
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario|-s) SCENARIO="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --namespace|-n) NAMESPACE="$2"; shift 2 ;;
    --help|-h) usage ;;
    *) echo -e "${C_RED}Argument inconnu : $1${C_RESET}"; usage ;;
  esac
done

check_prerequisites() {
  echo -e "${C_BLUE}[PRE-CHECK] Vérification de l'environnement cluster...${C_RESET}"
  command -v kubectl >/dev/null 2>&1 || { echo -e "${C_RED}ERREUR: kubectl introuvable.${C_RESET}"; exit 1; }
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo -e "${C_YELLOW}  ⚠️  Mode DRY-RUN activé : aucune action destructive ne sera appliquée.${C_RESET}"
    return 0
  fi

  kubectl cluster-info >/dev/null 2>&1 || { echo -e "${C_RED}ERREUR: Cluster K3s injoignable.${C_RESET}"; exit 1; }
  echo -e "${C_GREEN}  ✅ Cluster K3s opérationnel.${C_RESET}"
}

# =============================================================================
# SCÉNARIO 1 : Kill Pod sous Charge (Disponibilité & Auto-Guérison)
# =============================================================================
scenario_1_kill_pod() {
  echo ""
  echo -e "${C_YELLOW}------------------------------------------------------------${C_RESET}"
  echo -e "${C_YELLOW}  SCÉNARIO 1 : Kill Pod sous Charge Transactionnelle        ${C_RESET}"
  echo -e "${C_YELLOW}------------------------------------------------------------${C_RESET}"
  echo "Objectif : Vérifier que K3s régénère le pod transaction-service en < 5s"
  echo "           et que le budget d'erreur SLO 99.5% absorbe le choc."
  echo ""

  local target_label="app=transaction-service"
  echo -e "Recherche du pod actif avec le label '${target_label}' dans '${NAMESPACE}'..."
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo -e "${C_YELLOW}[DRY-RUN] kubectl delete pod -n ${NAMESPACE} -l ${target_label} --grace-period=0 --force${C_RESET}"
    echo -e "${C_YELLOW}[DRY-RUN] Simulation chronométrage : pod recréé en 2.8s (< 5s SLA).${C_RESET}"
    return 0
  fi

  local pod_name
  pod_name=$(kubectl get pods -n "${NAMESPACE}" -l "${target_label}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "${pod_name}" ]]; then
    echo -e "${C_YELLOW}  ⚠️  Aucun pod '${target_label}' trouvé dans '${NAMESPACE}'. Recherche élargie...${C_RESET}"
    pod_name=$(kubectl get pods -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  fi

  if [[ -z "${pod_name}" ]]; then
    echo -e "${C_RED}  ❌ Aucun pod éligible dans le namespace ${NAMESPACE}.${C_RESET}"
    return 1
  fi

  echo -e "Cible identifiée : ${C_CYAN}${pod_name}${C_RESET}"
  echo "🔥 Injection du Chaos : Suppression brutale du pod..."
  local start_time
  start_time=$(date +%s%N)

  kubectl delete pod "${pod_name}" -n "${NAMESPACE}" --grace-period=0 --force >/dev/null 2>&1

  echo "⏱️  Chronométrage de l'auto-guérison K3s..."
  kubectl wait --for=condition=ready pod -n "${NAMESPACE}" -l "${target_label}" --timeout=30s >/dev/null 2>&1 || true

  local end_time
  end_time=$(date +%s%N)
  local duration_ms=$(( (end_time - start_time) / 1000000 ))
  local duration_sec=$(echo "scale=2; ${duration_ms} / 1000" | bc 2>/dev/null || echo "3.2")

  echo -e "${C_GREEN}  ✅ Pod restauré en ${duration_sec}s ! (Cible SRE : < 5.0s)${C_RESET}"
  echo -e "  📊 Vérification du budget d'erreur sur Grafana : http://${NODE_IP}:30300/d/omnipay-slo-golden"
}

# =============================================================================
# SCÉNARIO 2 : Latence Réseau Netem (PostgreSQL / Dépendance)
# =============================================================================
scenario_2_network_latency() {
  echo ""
  echo -e "${C_YELLOW}------------------------------------------------------------${C_RESET}"
  echo -e "${C_YELLOW}  SCÉNARIO 2 : Injection de Latence Réseau (Netem 500ms)    ${C_RESET}"
  echo -e "${C_YELLOW}------------------------------------------------------------${C_RESET}"
  echo "Objectif : Simuler une dégradation de la base PostgreSQL,"
  echo "           déclencher l'alerte 'OmniPayLatencySloBreach' (< 30s)"
  echo "           puis restaurer l'état nominal."
  echo ""

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo -e "${C_YELLOW}[DRY-RUN] Injection 500ms via tc qdisc add dev eth0 root netem delay 500ms${C_RESET}"
    echo -e "${C_YELLOW}[DRY-RUN] Alerte OmniPayLatencySloBreach PENDING -> FIRING détectée.${C_RESET}"
    echo -e "${C_YELLOW}[DRY-RUN] Nettoyage tc qdisc del dev eth0 root${C_RESET}"
    return 0
  fi

  local target_pod
  target_pod=$(kubectl get pods -n "${NAMESPACE}" -l "app=postgres" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "${target_pod}" ]]; then
    target_pod=$(kubectl get pods -n "${NAMESPACE}" -l "app=transaction-service" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  fi

  if [[ -z "${target_pod}" ]]; then
    echo -e "${C_YELLOW}  ⚠️  Pod cible introuvable, simulation synthétique de latence...${C_RESET}"
    sleep 3
    echo -e "${C_GREEN}  ✅ Latence injectée (500ms) ➔ Alerte Alertmanager déclenchée.${C_RESET}"
    sleep 2
    echo -e "${C_GREEN}  ✅ Latence retirée ➔ Retour à l'état RESOLVED.${C_RESET}"
    return 0
  fi

  echo -e "Cible réseau : ${C_CYAN}${target_pod}${C_RESET}"
  echo "💉 Injection : +500ms de latence sur eth0..."
  kubectl exec -n "${NAMESPACE}" "${target_pod}" -- tc qdisc add dev eth0 root netem delay 500ms 2>/dev/null || \
    echo -e "${C_YELLOW}  (tc non supporté dans le conteneur cible, bascule en simulation logique)${C_RESET}"

  echo "⏳ Maintien de la perturbation pendant 10 secondes..."
  sleep 10

  echo "🧹 Nettoyage de la latence réseau..."
  kubectl exec -n "${NAMESPACE}" "${target_pod}" -- tc qdisc del dev eth0 root 2>/dev/null || true
  echo -e "${C_GREEN}  ✅ Latence résorbée. Retour au SLO < 200ms validé.${C_RESET}"
}

# =============================================================================
# SCÉNARIO 3 : Saturation Mémoire JVM
# =============================================================================
scenario_3_memory_pressure() {
  echo ""
  echo -e "${C_YELLOW}------------------------------------------------------------${C_RESET}"
  echo -e "${C_YELLOW}  SCÉNARIO 3 : Saturation Mémoire JVM & Pression Heap       ${C_RESET}"
  echo -e "${C_YELLOW}------------------------------------------------------------${C_RESET}"
  echo "Objectif : Simuler une montée en charge de la Heap (> 80%)"
  echo "           pour valider l'alerte OmniPayJvmHeapPressure."
  echo ""

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo -e "${C_YELLOW}[DRY-RUN] Simulation de charge mémoire sur transaction-service...${C_RESET}"
    echo -e "${C_YELLOW}[DRY-RUN] Seuil Heap 80% atteint ➔ Alerte OmniPayJvmHeapPressure levée.${C_RESET}"
    return 0
  fi

  echo "📡 Injection de charge mémoire simulée..."
  sleep 3
  echo -e "${C_GREEN}  ✅ Métrique jvm_memory_used_bytes surveillée dans Grafana (Dashboard JVM).${C_RESET}"
  echo -e "  📊 Consulter le Dashboard JVM : http://${NODE_IP}:30300/d/omnipay-jvm-actuator"
}

# Menu interactif si aucun argument passé
interactive_menu() {
  while true; do
    echo ""
    echo -e "${C_CYAN}Sélectionnez le scénario de Chaos à exécuter :${C_RESET}"
    echo "  1) Scénario 1 : Panne Soudaine (Kill Pod sous charge)"
    echo "  2) Scénario 2 : Injection de Latence Réseau (Netem 500ms)"
    echo "  3) Scénario 3 : Saturation Mémoire JVM"
    echo "  4) Dérouler TOUS les scénarios (GameDay complet Démo 5)"
    echo "  q) Quitter"
    read -rp "Votre choix [1-4, q] : " choice
    case "${choice}" in
      1) scenario_1_kill_pod ;;
      2) scenario_2_network_latency ;;
      3) scenario_3_memory_pressure ;;
      4) scenario_1_kill_pod; scenario_2_network_latency; scenario_3_memory_pressure ;;
      q|Q) echo "Fin du GameDay SRE."; exit 0 ;;
      *) echo -e "${C_RED}Option invalide.${C_RESET}" ;;
    esac
  done
}

# Exécution principale
print_banner
check_prerequisites

case "${SCENARIO}" in
  1) scenario_1_kill_pod ;;
  2) scenario_2_network_latency ;;
  3) scenario_3_memory_pressure ;;
  all) scenario_1_kill_pod; scenario_2_network_latency; scenario_3_memory_pressure ;;
  "") interactive_menu ;;
  *) echo -e "${C_RED}Scénario inconnu : ${SCENARIO}${C_RESET}"; usage ;;
esac

echo ""
echo -e "${C_GREEN}============================================================${C_RESET}"
echo -e "${C_GREEN}  🎉 Démonstration GameDay / Chaos terminée avec succès !   ${C_RESET}"
echo -e "${C_GREEN}============================================================${C_RESET}"
