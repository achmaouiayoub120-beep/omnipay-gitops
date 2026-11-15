# Démonstration 1 — Déploiement Progressif Canary et Rollback Automatique (Argo Rollouts)

**Projet** : OmniPay Zero-Trust  
**Rôle** : P4 — Ingénieur DevSecOps (Livraison & Chaîne d'Approvisionnement)  
**Composants démontrés** : Argo Rollouts, Prometheus (`kube-prometheus-stack`), AnalysisTemplate, Kubernetes K3s  
**Objectif pour le jury** : Démontrer la résilience opérationnelle totale de la banque OmniPay. En cas de mise en production d'une version applicative régressée (`v2-bad` générant des erreurs HTTP 5xx), le système limite le rayon d'impact (Blast Radius) à 10% du trafic, détecte automatiquement l'anomalie via Prometheus et avorte le déploiement avec retour arrière immédiat à 100% sur la version saine, sans la moindre action humaine.

---

## 1. Prérequis & Architecture de la Démo

- Cluster K3s actif avec le namespace `omnipay-prod`.
- Contrôleur **Argo Rollouts** installé (`platform/rollouts/install-rollouts.sh`).
- Plugin CLI `kubectl-argo-rollouts` installé.
- Prometheus opérationnel sur l'URL interne du cluster :  
  `http://monitoring-kube-prometheus-prometheus.monitoring.svc:9090`.

---

## 2. Déroulé Pas à Pas de la Démonstration (Commandes pour le Jury)

### Étape 0 : Constater l'état initial stable (Version 1.0.0 à 100%)

Ouvrez un premier terminal pour afficher la surveillance en temps réel du Rollout :

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

Dans un second terminal, vérifiez que le service actif répond avec succès :

```bash
kubectl run test-curl --rm -it --restart=Never --image=curlimages/curl -n omnipay-prod -- \
  curl -s -o /dev/null -w "Code HTTP : %{http_code}\n" http://transaction-service-active:8080/actuator/health
```
*Sortie attendue :* `Code HTTP : 200`

---

### Étape 1 : Déclencher le déploiement de la version défectueuse (`v2-bad`)

Simulez la livraison d'une nouvelle version contenant un bug critique (qui retourne des erreurs 500 sur les endpoints de transaction).

Exécutez la mise à jour de l'image du Rollout :

```bash
kubectl argo rollouts set image transaction-service \
  transaction-service=harbor.omnipay.local:30002/omnipay/transaction-service:v2-bad \
  -n omnipay-prod
```

---

### Étape 2 : Observer le palier Canary à 10% et le démarrage de l'analyse

Basculez sur le terminal avec `--watch`. Vous observez immédiatement :
1. Argo Rollouts crée **1 pod Canary** (représentant ~10% de la charge globale).
2. Les 3 autres pods restent sur l'ancienne version stable `1.0.0`.
3. Le statut indique : `Canary - Step 1/3 (setWeight: 10)`.
4. Une ressource `AnalysisRun` est automatiquement instanciée.

```bash
kubectl get analysisrun -n omnipay-prod
```

*Sortie attendue :*
```text
NAME                                         STATUS    AGE
transaction-service-7f8d69784b-1-canary      Running   12s
```

---

### Étape 3 : Injecter du trafic de simulation

Générez une série de requêtes vers le service transactionnel. Les requêtes dirigées vers le pod Canary échouent en 500 :

```bash
# Lancement d'une boucle simulant les requêtes des clients bancaires
kubectl run traffic-generator --rm -i --restart=Never --image=curlimages/curl -n omnipay-prod -- \
  sh -c 'for i in $(seq 1 60); do curl -s http://transaction-service:8080/api/transactions > /dev/null; sleep 0.5; done'
```

Dans Prometheus, la métrique d'erreur 5xx augmente et dépasse le seuil critique toléré de **2.0%** :
```text
Métrique : sum(rate(http_requests_total{status=~"5.*", app="transaction-service"}[1m])) / sum(...) * 100
Valeur mesurée : 10.0% (> 2.0%)
```

---

### Étape 4 : Constater l'échec de l'AnalysisRun et le Rollback automatique

Argo Rollouts constate l'échec de la condition `result[0] < 2.0` :

Vérifiez le détail de l'échec dans l'AnalysisRun :

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

Dans la console `--watch` d'Argo Rollouts, observez le comportement immédiat :

```text
Name:            transaction-service
Namespace:       omnipay-prod
Status:          ✖ Degraded
Message:         Rollout aborted update to revision 2: metric "http-5xx-error-rate" failed
Strategy:        Canary
  Step:          0/3
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
1. Le pod v2-bad défectueux a été immédiatement réduit à 0 réplicas.
2. 100% des connexions sont maintenues sur la version saine `1.0.0`.
3. Zéro interruption de service pour les utilisateurs légitimes.
4. Le rollback a été exécuté en moins de 15 secondes sans aucune commande manuelle.

---

### Étape 5 : Remise à zéro pour la suite des tests

Pour réinitialiser le statut du Rollout :

```bash
# Annulation de l'état dégradé et retour propre à l'état sain v1.0.0
kubectl argo rollouts undo transaction-service --to-revision=1 -n omnipay-prod
kubectl argo rollouts status rollout transaction-service -n omnipay-prod
```
