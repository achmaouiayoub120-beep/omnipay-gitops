# Démo 5 — Game Day & Résilience SLO
## OmniPay Zero-Trust | Rôle P5 — Fiabilité & Observabilité | Semaine 2

**Objectif** : Démontrer au jury le cycle complet SRE en 15 minutes :
> _Trafic nominal → Panne → Détection → Alerte → Auto-guérison → Post-mortem_

| Info | Valeur |
|------|--------|
| **Durée** | 15 minutes |
| **Cluster** | K3s (local ou VM) |
| **Prérequis** | kube-prometheus-stack + Loki déployés, canal Discord/Telegram configuré |
| **URL Grafana** | `http://<NODE_IP>:30300` (admin / GrafanaOmniPay2026!) |
| **URL Alertmanager** | `http://<NODE_IP>:30903` |
| **URL Prometheus** | `http://<NODE_IP>:30900` |

---

## Vue d'ensemble du scénario

```
Trafic k6 (nominal)
       │
       ▼
  ┌─────────────────────┐
  │   OmniPay (K3s)     │──── kubectl delete pod ──► Panne injectée
  │  Auth / Transaction  │
  │  Notification        │
  └─────────────────────┘
            │
            ▼  (< 30s)
  ┌──────────────────────────┐
  │  Prometheus détecte      │
  │  up=0 → Burn Rate élevé  │
  └──────────────────────────┘
            │
            ▼  (< 10s)
  ┌──────────────────────────┐
  │  Alertmanager → Webhook  │──► Discord/Telegram 📱
  └──────────────────────────┘
            │
            ▼  (90s)
  ┌──────────────────────────┐
  │  K3s recrée le pod       │
  │  Alerte → RESOLVED ✅    │
  └──────────────────────────┘
            │
            ▼
     Post-mortem GitHub Issue
```

---

## ⚙️ Préparation (J-1 avant la démo)

```bash
# 1. Vérifier tous les pods sont UP
kubectl get pods -n monitoring
kubectl get pods -n default

# 2. Vérifier ServiceMonitors actifs
kubectl get servicemonitors -n monitoring

# 3. Vérifier les alertes PrometheusRule chargées
kubectl get prometheusrules -n monitoring

# 4. Tester le webhook (valider que Discord/Telegram reçoit)
bash platform/monitoring/scripts/test-alerts.sh http://<NODE_IP>:30903

# 5. Ouvrir les 3 onglets navigateur :
#    - Grafana dashboard SLO : http://<NODE_IP>:30300/d/omnipay-slo-golden
#    - Alertmanager UI       : http://<NODE_IP>:30903
#    - Discord/Telegram      : sur téléphone en évidence
```

---

## 🚦 ÉTAPE 1 — Trafic Nominal (2 min)

**But** : Montrer l'état sain — 100% budget d'erreur, latence < 50ms.

```bash
# Lancer le générateur de charge k6 (fourni par P2)
k6 run --vus 10 --duration 5m \
  -e BASE_URL=http://<NODE_IP>:8082 \
  load-tests/load-test-transactions.js
```

**Ce que le jury voit sur Grafana (dashboard SLO) :**

| Indicateur | Valeur observée | SLO |
|------------|----------------|-----|
| Disponibilité 30j | 🟢 99.9% | ≥ 99.5% |
| Budget d'erreur restant | 🟢 100% | > 50% |
| Latence P95 | 🟢 < 50ms | < 200ms |
| RPS Transaction Service | 🟢 ~10 req/s | — |
| Taux erreurs HTTP | 🟢 0% | < 0.5% |

---

## 💥 ÉTAPE 2 — Injection de Panne (Chaos) (1 min)

**But** : Simuler la défaillance du microservice le plus critique.

### Option A — Kill Pod (recommandé, le plus spectaculaire)
```bash
# Supprimer le pod transaction-service (K3s le recréera automatiquement)
kubectl delete pod -n default \
  -l app=transaction-service \
  --grace-period=0 --force

# Observer le redémarrage en temps réel
kubectl get pods -n default -l app=transaction-service -w
```

### Option B — Scale-down (plus simple)
```bash
kubectl scale deployment transaction-service -n default --replicas=0
# Restauration après démo :
kubectl scale deployment transaction-service -n default --replicas=1
```

### Option C — Injection de latence (avancé)
```bash
# Injecter 600ms de latence réseau dans le pod
kubectl exec -n default deployment/transaction-service -- \
  sh -c "tc qdisc add dev eth0 root netem delay 600ms 2>/dev/null || echo 'tc unavailable'"
# Nettoyer après :
kubectl exec -n default deployment/transaction-service -- \
  sh -c "tc qdisc del dev eth0 root 2>/dev/null || true"
```

---

## 🚨 ÉTAPE 3 — Détection & Alerte (3 min)

**But** : Montrer que Prometheus détecte la panne en < 1 minute.

```bash
# Terminal 1 : Observer les alertes en temps réel
watch -n5 'curl -sf http://<NODE_IP>:30900/api/v1/alerts | \
  python3 -c "
import json,sys
data=json.load(sys.stdin)
alerts=data[\"data\"][\"alerts\"]
print(f\"Alertes actives : {len(alerts)}\")
for a in alerts:
    print(f\"  [{a[\"labels\"][\"severity\"].upper():8}] {a[\"labels\"][\"alertname\"]} -> {a[\"state\"]}\")"'

# Terminal 2 : Logs en temps réel (Loki via CLI)
kubectl logs -n default -l app=transaction-service -f --tail=50
```

**Timeline de détection attendue :**

| Temps | Événement |
|-------|-----------|
| T+0s | Pod supprimé / latence injectée |
| T+15s | Prometheus scrape échoue (interval: 15s) |
| T+30s | Alerte `OmniPayMicroserviceDown` → **PENDING** |
| T+60s | Alerte → **FIRING** (for: 1m écoulé) |
| T+70s | Alertmanager reçoit l'alerte |
| T+80s | Webhook Discord/Telegram déclenché (group_wait: 10s) |
| T+90s | 📱 Notification reçue sur le téléphone du jury |

**Ce que le jury voit :**
1. **Grafana** : chute brutale du budget d'erreur, latence monte
2. **Alertmanager** : `OmniPayMicroserviceDown` + `OmniPayBurnRateCritical` → FIRING
3. **Discord/Telegram** : Message critique avec description de l'incident

```bash
# Vérifier les alertes actives Alertmanager
curl -sf http://<NODE_IP>:30903/api/v2/alerts | \
  python3 -c "
import json,sys
alerts=json.load(sys.stdin)
print(f'Alertes actives : {len(alerts)}')
for a in alerts:
    print(f'  {a[\"labels\"][\"alertname\"]} [{a[\"labels\"][\"severity\"]}] -> {a[\"status\"][\"state\"]}')
"
```

**Logs Loki dans Grafana (Explore → Loki) :**
```logql
# Logs d'erreur Spring Boot du service en panne
{namespace="default", app="transaction-service"} |= "ERROR"

# Toutes les erreurs des 5 dernières minutes
{namespace="default"} |= "ERROR" | json | level="ERROR"
```

---

## 🔄 ÉTAPE 4 — Auto-guérison K3s (2 min)

**But** : Montrer que K3s recrée le pod automatiquement sans aucune intervention humaine.

```bash
# Observer le pod revenir à la vie
kubectl get pods -n default -l app=transaction-service -w

# Vérifier les events K3s
kubectl get events -n default \
  --field-selector reason=Started \
  --sort-by='.lastTimestamp' | tail -10
```

**Ce que le jury voit sur Grafana :**
- Budget d'erreur : **remontée progressive** vers 100%
- Latence : **revient < 200ms**
- RPS : **retour du trafic normal**
- Alertes → **Resolved** (badge vert dans Alertmanager)
- **Discord/Telegram** reçoit le message "✅ Resolved — OmniPayMicroserviceDown"

---

## 📚 ÉTAPE 5 — Boucle d'Apprentissage Post-Mortem (5 min)

**But** : Fermer la boucle DevOps avec un post-mortem structuré.

### Génération automatique de l'issue GitHub post-mortem

```bash
gh issue create \
  --repo achmaouiayoub120-beep/omnipay-app \
  --title "[POST-MORTEM] Incident transaction-service — $(date +%Y-%m-%d)" \
  --label "post-mortem,p5-sre,incident" \
  --body "## Post-Mortem OmniPay Zero-Trust

**Date** : $(date '+%Y-%m-%d %H:%M UTC')
**Durée incident** : ~90 secondes
**Service impacté** : transaction-service
**Sévérité** : CRITIQUE

### Chronologie

| Heure | Événement |
|-------|-----------|
| T+0s  | Pod supprimé (Game Day) |
| T+30s | Alerte OmniPayMicroserviceDown PENDING |
| T+60s | Alerte FIRING |
| T+80s | Notification Discord/Telegram reçue |
| T+90s | K3s recrée le pod automatiquement |
| T+2m  | Alerte RESOLVED |

### Impact

- Transactions bancaires indisponibles : ~90 secondes
- Budget d'erreur mensuel consommé : ~1.2%
- SLO 99.5% : respecté sur fenêtre 30 jours

### Root Cause Analysis

Cause directe : Suppression forcée du pod transaction-service (simulation Game Day)
Cause racine : Absence de redondance (replicas=1) sur un service critique

### Actions correctives

- [ ] Augmenter replicas à 2 pour haute disponibilité (transaction-service)
- [ ] Mettre en place un PodDisruptionBudget (PDB)
- [ ] Ajouter une alerte HPA si CPU > 80%
- [ ] Configurer des readiness/liveness probes plus agressifs

### Leçons apprises

1. ✅ Détection Prometheus < 30s fonctionne parfaitement
2. ✅ Webhook Discord/Telegram opérationnel
3. ✅ Auto-guérison K3s validée (pod recréé automatiquement)
4. ✅ Alerte Resolved automatique reçue sur Discord/Telegram
5. ✅ Budget d'erreur reste dans les limites acceptables sur 30j
"
```

### Métriques post-incident

```bash
# Disponibilité sur la dernière heure
curl -sf "http://<NODE_IP>:30900/api/v1/query" \
  --data-urlencode 'query=1-(sum(rate(http_server_requests_seconds_count{status=~"5.."}[1h])) or vector(0))/sum(rate(http_server_requests_seconds_count[1h]))' | \
  python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d['data']['result']
if r:
    v=float(r[0]['value'][1])
    print(f'Disponibilite 1h : {v*100:.4f}% (SLO: 99.5%)')
else:
    print('Pas de donnees (aucun trafic)')
"
```

---

## ✅ Checklist de validation pour le jury

| # | Critère | Résultat attendu | Validé |
|---|---------|-----------------|--------|
| 1 | Trafic nominal visible Grafana | Dashboard SLO affiche 100% budget | ☐ |
| 2 | Panne détectée < 1 min | Alerte FIRING Alertmanager | ☐ |
| 3 | Notification Discord/Telegram | Message critique reçu en direct | ☐ |
| 4 | Auto-guérison K3s | Pod recréé sans intervention humaine | ☐ |
| 5 | Alerte Resolved automatique | Canal reçoit "Resolved" | ☐ |
| 6 | Logs Loki corrélés | Stacktraces Spring Boot visibles | ☐ |
| 7 | Post-mortem GitHub | Issue créée avec chronologie | ☐ |

---

## 🛠️ Commandes de Secours

```bash
# Réinitialiser le cluster si problème
kubectl scale deployment transaction-service -n default --replicas=1
kubectl scale deployment auth-service -n default --replicas=1
kubectl scale deployment notification-service -n default --replicas=1

# Vérifier tous les microservices
kubectl get pods -n default -o wide

# Vérifier les targets Prometheus
curl -sf http://<NODE_IP>:30900/api/v1/targets | \
  python3 -c "
import json,sys
data=json.load(sys.stdin)
for t in data['data']['activeTargets']:
    print(t['labels'].get('job','?'), '->', t['health'])
"

# Silence Watchdog (si trop de bruit)
curl -X POST http://<NODE_IP>:30903/api/v2/silences \
  -H "Content-Type: application/json" \
  -d '{
    "matchers": [{"name":"alertname","value":"Watchdog","isRegex":false,"isEqual":true}],
    "startsAt": "2026-01-01T00:00:00Z",
    "endsAt": "2026-12-31T23:59:59Z",
    "createdBy": "p5-moad",
    "comment": "Silence Watchdog during demo"
  }'
```

---

*Document rédigé par P5 — Moad Helkamel | OmniPay Zero-Trust ESTC | Semaine 2*
