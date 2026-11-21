#!/usr/bin/env bash
# =============================================================================
# test-alerts.sh — OmniPay Zero-Trust | P5 Semaine 2
# Injection d'alertes synthétiques vers Alertmanager pour valider le webhook
# Usage : bash test-alerts.sh [ALERTMANAGER_URL]
# Exemple : bash test-alerts.sh http://192.168.1.100:30903
# =============================================================================
set -euo pipefail

ALERTMANAGER_URL="${1:-${ALERTMANAGER_URL:-http://localhost:30903}}"
API_ENDPOINT="${ALERTMANAGER_URL}/api/v2/alerts"

echo "============================================================"
echo "  OmniPay — Test injection alertes Alertmanager"
echo "  URL : ${ALERTMANAGER_URL}"
echo "============================================================"

# 1. Vérification
echo "[1/4] Verification disponibilite Alertmanager..."
if ! curl -sf "${ALERTMANAGER_URL}/-/healthy" > /dev/null 2>&1; then
  echo "ERREUR: Alertmanager inaccessible sur ${ALERTMANAGER_URL}"
  echo "Verifiez : kubectl get svc -n monitoring | grep alertmanager"
  exit 1
fi
echo "  OK Alertmanager accessible"

START_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
END_TIME="$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+10M +%Y-%m-%dT%H:%M:%SZ)"

# 2. Alerte critique BurnRate
echo ""
echo "[2/4] Injection alerte CRITIQUE : OmniPayBurnRateCritical..."
HTTP_CODE=$(curl -s -o /tmp/am_resp1.json -w "%{http_code}" \
  -X POST "${API_ENDPOINT}" \
  -H "Content-Type: application/json" \
  -d "[{
    \"labels\": {
      \"alertname\": \"OmniPayBurnRateCritical\",
      \"severity\": \"critical\",
      \"service\": \"transaction-service\",
      \"namespace\": \"default\",
      \"team\": \"p5-sre\",
      \"env\": \"k3s-simulation\",
      \"slo\": \"99.5\"
    },
    \"annotations\": {
      \"summary\": \"[SIMULATION TEST] Budget erreur en epuisement critique\",
      \"description\": \"Burn Rate : 14.5x | Budget restant : 12% | SLO 99.5% menace.\"
    },
    \"startsAt\": \"${START_TIME}\",
    \"endsAt\": \"${END_TIME}\",
    \"generatorURL\": \"http://prometheus:30900/graph\"
  }]")
echo "  HTTP ${HTTP_CODE} - Reponse : $(cat /tmp/am_resp1.json)"

# 3. Alerte microservice down
echo ""
echo "[3/4] Injection alerte CRITIQUE : OmniPayMicroserviceDown..."
HTTP_CODE=$(curl -s -o /tmp/am_resp2.json -w "%{http_code}" \
  -X POST "${API_ENDPOINT}" \
  -H "Content-Type: application/json" \
  -d "[{
    \"labels\": {
      \"alertname\": \"OmniPayMicroserviceDown\",
      \"severity\": \"critical\",
      \"job\": \"transaction-service-omnipay\",
      \"instance\": \"10.0.0.5:8082\",
      \"namespace\": \"default\",
      \"team\": \"p5-sre\",
      \"env\": \"k3s-simulation\"
    },
    \"annotations\": {
      \"summary\": \"[SIMULATION TEST] Microservice transaction-service inaccessible\",
      \"description\": \"Le microservice ne repond plus au scrape Prometheus depuis 2 minutes.\"
    },
    \"startsAt\": \"${START_TIME}\",
    \"endsAt\": \"${END_TIME}\",
    \"generatorURL\": \"http://prometheus:30900/graph\"
  }]")
echo "  HTTP ${HTTP_CODE} - Reponse : $(cat /tmp/am_resp2.json)"

# 4. Liste alertes actives
echo ""
echo "[4/4] Alertes actives dans Alertmanager :"
curl -sf "${ALERTMANAGER_URL}/api/v2/alerts" | \
  python3 -c "
import json,sys
alerts = json.load(sys.stdin)
if not alerts:
    print('  Aucune alerte active')
else:
    for a in alerts:
        name = a.get('labels',{}).get('alertname','?')
        sev  = a.get('labels',{}).get('severity','?')
        st   = a.get('status',{}).get('state','?')
        print(f'  [{sev.upper():8}] {name} -> {st}')
" 2>/dev/null || echo "  Consultez l'UI : ${ALERTMANAGER_URL}"

echo ""
echo "============================================================"
echo "  Test termine ! Verifiez votre canal Discord/Telegram."
echo "  Interface Alertmanager : ${ALERTMANAGER_URL}"
echo "============================================================"
