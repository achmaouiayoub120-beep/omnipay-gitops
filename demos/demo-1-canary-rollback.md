# Démonstration 1 — Déploiement Progressif Canary et Rollback Automatique (Argo Rollouts)

**Projet** : OmniPay Zero-Trust  
**Rôle** : P4 — Widad El Gharzaz (Ingénieure Packaging, Registre Harbor, Argo Rollouts & Kyverno)  
**Composants démontrés** : Argo Rollouts, Prometheus (`kube-prometheus-stack`), AnalysisTemplate, Kubernetes K3s  
**Objectif pour le jury** : Démontrer la résilience opérationnelle totale de la banque OmniPay. En cas de mise en production d'une version applicative régressée (`v2-bad` générant des erreurs HTTP 5xx), le système limite le rayon d'impact (Blast Radius) à 10% du trafic, détecte automatiquement l'anomalie via Prometheus et avorte le déploiement avec retour arrière immédiat à 100% sur la version saine, en moins de 30 secondes sans la moindre action humaine.

---

## 1. Prérequis & Architecture de la Démo

- Cluster K3s actif avec le namespace `omnipay-prod`.
- Contrôleur **Argo Rollouts** installé (`platform/rollouts/install-rollouts.sh`).
- Plugin CLI `kubectl-argo-rollouts` installé (ou fallback kubectl).
- Prometheus opérationnel sur l'URL interne du cluster :  
  `http://monitoring-kube-prometheus-prometheus.monitoring.svc:9090`.
- Microservice transactionnel : `transaction-service` configuré avec son Rollout (`envs/prod/transaction-service-rollout.yaml`) et son AnalysisTemplate (`envs/prod/transaction-service-analysis.yaml`).

---

## 2. Exécution Automatisée en Une Commande (Recommandé Jury)

Un script d'automatisation complet a été conçu pour exécuter la démonstration de bout en bout de manière parfaitement reproductible :

### Sous Linux / MacOS / CI :
```bash
chmod +x scripts/run-demo-canary.sh
./scripts/run-demo-canary.sh
```

### Sous Windows (PowerShell 7+) :
```powershell
.\scripts\run-demo-canary.ps1
```

---

## 3. Déroulé Pas à Pas Détaillé pour la Soutenance

### Étape 0 : Constater l'état initial stable (Version 1.0.0 à 100%)

Ouvrez un terminal pour observer la vue temps réel du Rollout :

```bash
kubectl argo rollouts get rollout transaction-service -n omnipay-prod --watch
```

*Sortie attendue :*
```text
Name:            transaction-service
Namespace:       omnipay-prod
Status:          » Healthy
Strategy:        Canary
  Step:          100%
  SetWeight:     100
Replicas:
  Desired:       4
  Current:       4
  Updated:       4
  Ready:         4
  Available:     4

Images:
  harbor.omnipay.local:30002/omnipay/transaction-service:1.0.0 (stable)
```

Vérifiez que le service stable répond avec succès (HTTP 200) :

```bash
kubectl run test-curl --rm -it --restart=Never --image=curlimages/curl -n omnipay-prod -- \
  curl -s -o /dev/null -w "Code HTTP : %{http_code}\n" http://transaction-service-active:8080/actuator/health
```
*Sortie attendue :* `Code HTTP : 200`

---

### Étape 1 : Déclencher le déploiement de la version défectueuse (`v2-bad`)

Simulez la livraison d'une version buggée (retournant des erreurs 500 sur les endpoints de transaction).

```bash
kubectl argo rollouts set image transaction-service \
  transaction-service=harbor.omnipay.local:30002/omnipay/transaction-service:v2-bad \
  -n omnipay-prod
```

---

### Étape 2 : Observer le palier Canary à 10% et le démarrage de l'analyse

Basculez sur la vue du Rollout. Vous observez immédiatement :
1. Argo Rollouts crée **1 pod Canary** (représentant ~10% de la charge globale).
2. Les 3 autres pods restent sur l'ancienne version saine `1.0.0`.
3. Le statut indique : `Canary - Step 1/4 (setWeight: 10)`.
4. Une ressource `AnalysisRun` est automatiquement instanciée à partir de `prometheus-error-rate`.

```bash
kubectl get analysisrun -n omnipay-prod
```

*Sortie attendue :*
```text
NAME                                         STATUS    AGE
transaction-service-7f8d69784b-1-canary      Running   10s
```

---

### Étape 3 : Injecter du trafic de simulation bancaire

Générez des requêtes vers le service transactionnel :

```bash
kubectl run traffic-generator --rm -i --restart=Never --image=curlimages/curl -n omnipay-prod -- \
  sh -c 'for i in $(seq 1 60); do curl -s http://transaction-service:8080/api/transactions > /dev/null; sleep 0.5; done'
```

Dans Prometheus, la métrique PromQL suivante est évaluée en continu sur 2 minutes :
```promql
(
  sum(rate(http_server_requests_seconds_count{service="transaction-service", status=~"5.."}[2m]))
  /
  (sum(rate(http_server_requests_seconds_count{service="transaction-service"}[2m])) > 0)
) * 100 or vector(0)
```
La valeur mesurée grimpe immédiatement et dépasse le seuil maximal toléré de **0.5%** (`successCondition: result[0] < 0.5`).

---

### Étape 4 : Constater l'échec de l'AnalysisRun et le Rollback automatique

Argo Rollouts constate l'échec de la condition `result[0] < 0.5` :

```bash
kubectl describe analysisrun -l rollout-type=Canary -n omnipay-prod
```

*Sortie console clé :*
```text
Status:
  Message:           Metric "http-5xx-error-rate" failed 1 times. Threshold: 1
  Phase:             Failed
  Metric Results:
    Name:            http-5xx-error-rate
    Count:           1
    Failed:          1
    Measurements:
      Value:         [10.00]
      Status:        Failed
```

Dans la console Argo Rollouts, observez le comportement immédiat :

```text
Name:            transaction-service
Namespace:       omnipay-prod
Status:          ✖ Degraded
Message:         Rollout aborted update to revision 2: metric "http-5xx-error-rate" failed
Strategy:        Canary
  Step:          0/4
  SetWeight:     0
Replicas:
  Desired:       4
  Current:       4
  Updated:       0
  Ready:         4
  Available:     4

Images:
  harbor.omnipay.local:30002/omnipay/transaction-service:1.0.0 (stable)
  harbor.omnipay.local:30002/omnipay/transaction-service:v2-bad (canary) [Terminating / Scaled down]
```

**Points clés démontrés au jury :**
1. **Plafond Blast Radius à 10%** : Au maximum 10% des requêtes ont été exposées à l'erreur pendant moins d'une minute.
2. **Auto-Rollback en < 30 secondes** : Le pod Canary v2-bad a été immédiatement détruit et ramené à 0 réplica.
3. **Zéro interruption de service** : 100% du trafic client a continué d'être desservi par les 4 réplicas stables de la version 1.0.0.
4. **Zéro action humaine** : Le MTTR a été réduit à quelques secondes grâce à l'automatisation SRE/DevSecOps.

---

### Étape 5 : Remise à zéro pour la suite des démonstrations

Pour remettre le Rollout dans son état initial sain :

```bash
kubectl argo rollouts undo transaction-service --to-revision=1 -n omnipay-prod
kubectl argo rollouts status rollout transaction-service -n omnipay-prod
```
