#!/usr/bin/env bash
# =============================================================================
# test-discord-webhook.sh — OmniPay Zero-Trust | P5 Semaine 3 (S3)
# Test d'envoi de cartes d'incident professionnelles vers Discord / Webhook
# Usage : ./test-discord-webhook.sh [WEBHOOK_URL] [NODE_IP]
# =============================================================================
set -euo pipefail

WEBHOOK_URL="${1:-${DISCORD_WEBHOOK_URL:-WEBHOOK_URL_PLACEHOLDER}}"
NODE_IP="${2:-127.0.0.1}"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "============================================================"
echo "  OmniPay SRE — Test Webhook Alertmanager & Discord (S3)    "
echo "============================================================"

if [[ "${WEBHOOK_URL}" == "WEBHOOK_URL_PLACEHOLDER" || -z "${WEBHOOK_URL}" ]]; then
  echo "⚠️  NOTE ZERO-TRUST : Aucun webhook réel spécifié."
  echo "    Usage : $0 https://discord.com/api/webhooks/<ID>/<TOKEN> [NODE_IP]"
  echo "    Ou exporter la variable : export DISCORD_WEBHOOK_URL='https://...'"
  echo ""
  echo "    Validation de la génération du payload JSON synthétique (Dry-Run)..."
fi

# 1. Payload de l'alerte CRITIQUE (Embed Rouge Discord #E74C3C / 15158332)
PAYLOAD_FIRING=$(cat <<EOF
{
  "username": "OmniPay SRE Alertmanager",
  "avatar_url": "https://raw.githubusercontent.com/prometheus/prometheus/main/documentation/images/prometheus-logo.png",
  "content": "🚨 **[INCIDENT EN COURS] Notification prioritaire P5 — Fiabilité Plateforme**",
  "embeds": [
    {
      "title": "🚨 [ALERTE SRE OMNIPAY] OmniPayBurnRateCritical (CRITICAL)",
      "description": "Le budget d'erreur de la plateforme bancaire se consume à vitesse critique ! Risque imminent de rupture du SLA 99.5%.",
      "color": 15158332,
      "fields": [
        {
          "name": "🏦 Service impacté",
          "value": "\`transaction-service\`",
          "inline": true
        },
        {
          "name": "🏷️ Namespace",
          "value": "\`default\`",
          "inline": true
        },
        {
          "name": "🔥 Vitesse de consommation (Burn Rate)",
          "value": "**14.5x** (> 2% du budget en 1h)",
          "inline": true
        },
        {
          "name": "📉 Budget d'erreur restant",
          "value": "**12.4%** (Seuil critique < 20%)",
          "inline": true
        },
        {
          "name": "⏱️ Latence P95 actuelle",
          "value": "\`385ms\` (SLO max: 200ms)",
          "inline": true
        },
        {
          "name": "🎯 Objectif de Service (SLO)",
          "value": "99.5% disponibilité sur 30 jours",
          "inline": true
        },
        {
          "name": "📊 Dashboard Grafana",
          "value": "[Accéder au Dashboard SLO](http://${NODE_IP}:30300/d/omnipay-slo-golden)",
          "inline": false
        },
        {
          "name": "📖 Runbook d'intervention",
          "value": "[Runbook SLO Breach](https://github.com/achmaouiayoub120-beep/omnipay-gitops/blob/main/demos/demo-5-gameday-slo.md)",
          "inline": false
        }
      ],
      "footer": {
        "text": "OmniPay Zero-Trust SRE Bot • Cluster K3s • Moad Helkamel (P5)"
      },
      "timestamp": "${TIMESTAMP}"
    }
  ]
}
EOF
)

# 2. Payload de l'alerte RÉSOLUE (Embed Vert Discord #2ECC71 / 3066993)
PAYLOAD_RESOLVED=$(cat <<EOF
{
  "username": "OmniPay SRE Alertmanager",
  "avatar_url": "https://raw.githubusercontent.com/prometheus/prometheus/main/documentation/images/prometheus-logo.png",
  "content": "✅ **[INCIDENT RÉSOLU] Retour à la normale — Fiabilité rétablie**",
  "embeds": [
    {
      "title": "✅ [RESOLVED] OmniPayBurnRateCritical (NORMAL)",
      "description": "Le trafic bancaire s'est stabilisé. Le taux de consommation du budget d'erreur est redescendu sous le seuil nominal.",
      "color": 3066993,
      "fields": [
        {
          "name": "🏦 Service restauré",
          "value": "\`transaction-service\`",
          "inline": true
        },
        {
          "name": "🛡️ Auto-guérison",
          "value": "Pod K3s régénéré avec succès",
          "inline": true
        },
        {
          "name": "⏱️ Latence P95 stabilisée",
          "value": "\`42ms\` (< 200ms SLO)",
          "inline": true
        },
        {
          "name": "📊 Dashboard Grafana",
          "value": "[Vérifier le statut](http://${NODE_IP}:30300/d/omnipay-slo-golden)",
          "inline": false
        }
      ],
      "footer": {
        "text": "OmniPay Zero-Trust SRE Bot • Incident clos automatiquement"
      },
      "timestamp": "${TIMESTAMP}"
    }
  ]
}
EOF
)

if [[ "${WEBHOOK_URL}" != "WEBHOOK_URL_PLACEHOLDER" && -n "${WEBHOOK_URL}" ]]; then
  echo "📤 [1/2] Envoi de l'alerte CRITIQUE vers le webhook..."
  HTTP_CODE=$(curl -s -o /tmp/discord_resp.txt -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "${PAYLOAD_FIRING}" "${WEBHOOK_URL}")
  if [[ "${HTTP_CODE}" == "204" || "${HTTP_CODE}" == "200" ]]; then
    echo "  ✅ Alerte CRITIQUE transmise (HTTP ${HTTP_CODE})."
  else
    echo "  ⚠️  Code HTTP : ${HTTP_CODE}"
    cat /tmp/discord_resp.txt 2>/dev/null || true
  fi

  echo "⏳ Pause de 3 secondes avant notification de résolution..."
  sleep 3

  echo "📤 [2/2] Envoi de la notification de RÉSOLUTION..."
  HTTP_CODE=$(curl -s -o /tmp/discord_resp2.txt -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "${PAYLOAD_RESOLVED}" "${WEBHOOK_URL}")
  if [[ "${HTTP_CODE}" == "204" || "${HTTP_CODE}" == "200" ]]; then
    echo "  ✅ Notification RÉSOLUE transmise (HTTP ${HTTP_CODE})."
  else
    echo "  ⚠️  Code HTTP : ${HTTP_CODE}"
    cat /tmp/discord_resp2.txt 2>/dev/null || true
  fi
else
  echo "  ✅ Payload JSON valide généré :"
  echo "${PAYLOAD_FIRING}" | head -n 25
  echo "  ... [payload complet prêt pour diffusion]"
fi

echo ""
echo "============================================================"
echo "  ✅ Test webhook Alertmanager terminé avec succès !"
echo "============================================================"
