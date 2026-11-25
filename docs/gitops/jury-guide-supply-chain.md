# Guide Jury — Architecture Supply Chain Security, Kyverno & Argo Rollouts (P4)

**Projet** : OmniPay Zero-Trust (ESTC)  
**Rôle P4** : Widad El Gharzaz — Ingénieure Plateforme, Supply Chain Security & Lead GitOps  
**Dépôt GitOps** : `omnipay-gitops`  
**Cible d'exécution** : Cluster Kubernetes K3s (`omnipay-dev`, `omnipay-recette`, `omnipay-prod`)

---

## 1. Architecture de la Supply Chain Zero-Trust

Dans OmniPay Zero-Trust, aucune image ni aucun manifeste ne bénéficie d'une confiance implicite (*Never Trust, Always Verify*). La chaîne de confiance relie de façon auditable le code source Git jusqu'au Pod en production :

```text
  +----------------+      +----------------------+      +--------------------------------+
  |   1. Git       | ---> |  2. CI Jenkins (P1)  | ---> |  3. Harbor OCI (NodePort 30002)|
  |  omnipay-app   |      |  - Gitleaks / Maven  |      |  - Scan Trivy (Prevent Crit)   |
  |  omnipay-gitops|      |  - SonarQube (30003) |      |  - Tags Immuables (**)         |
  +----------------+      |  - Syft SBOM SPDX    |      |  - Accessoires OCI (.sig/.sbom)|
         ^                |  - Cosign Sign       |      +--------------------------------+
         |                +----------------------+                       |
         |                                                               v
         |                +----------------------+      +--------------------------------+
         +--------------- |  4. ArgoCD (30005)   | ---> |  5. Kyverno Admission Webhook  |
           Pull GitOps    |  ApplicationSet :    |      |  - Vérif. Signature Cosign     |
           (No CI kube-   |   - omnipay-dev      |      |  - PSS Restricted (Non-Root)   |
            config!)      |   - omnipay-recette  |      |  - Mutation Labels & Seccomp   |
                          |   - omnipay-prod     |      +--------------------------------+
                          +----------------------+                       |
                                                                         v
                                                        +--------------------------------+
                                                        |  6. Argo Rollouts (Prod)       |
                                                        |  Canary 10->33->66->100%       |
                                                        |  <-> Prometheus (5xx < 0.5%/2%)|
                                                        |  Auto-Rollback < 30s           |
                                                        +--------------------------------+
```

### Principes architecturaux clés

1. **Séparation des responsabilités (SoD)** : Jenkins pousse des images signées dans Harbor et met à jour les tags dans `omnipay-gitops`, sans jamais détenir de `kubeconfig` administrateur sur K3s (`ADR-004`).
2. **Modèle Pull GitOps (`ApplicationSet` `omnipay-environments`)** :
   - `omnipay-dev` : `autoSync` actif (`prune: true`, `selfHeal: true`).
   - `omnipay-recette` : `autoSync` actif (`prune: true`, `selfHeal: true`) pour validation k6 & OWASP ZAP.
   - `omnipay-prod` : `autoSync: false` — promotion contrôlée manuellement puis orchestrée par Argo Rollouts.
3. **Registre souverain Harbor (`http://harbor.omnipay.local:30002`)** (`ADR-002`) :
   - Scan Trivy automatique à chaque `docker push` (`auto_scan: true`) avec blocage de pull sur CVE `Critical` (`prevent_vul: true`).
   - Règle d'immuabilité des tags (`**`) empêchant tout écrasement d'un artefact déjà publié.
   - Compte robot à moindre privilège (`robot$robot-omnipay-ci`) et stockage des accessoires OCI (SBOM Syft SPDX + signature Cosign ECDSA P-256).
4. **Zéro secret dans Git** : Seule la clé publique `platform/kyverno/keys/cosign.pub` est versionnée ; les identifiants Harbor, clés privées Cosign et jetons ArgoCD sont injectés via variables d'environnement ou Secrets Kubernetes (`harbor-registry-secret`).

---

## 2. Matrice des Politiques Kyverno Actives

Toutes les politiques résident dans `platform/kyverno/policies/` et s'exécutent au niveau de l'Admission Controller de K3s avant toute persistance dans `etcd`.

| ClusterPolicy (`metadata.name`) | Fichier source | Type / Action | Périmètre cible | Règle appliquée & Impact Zero-Trust |
| :--- | :--- | :--- | :--- | :--- |
| **`verify-omnipay-image-signature`** | `disallow-unsigned-images.yaml` | `Validate` / **`Enforce`** (`failurePolicy: Fail`) | `Pod` dans `omnipay-prod`, `omnipay-recette` | Vérifie la signature cryptographique **Cosign** (`cosign.pub` ECDSA P-256) des images `harbor.omnipay.local:30002/omnipay/*`, `harbor.omnipay.local/omnipay/*`, `*/omnipay/*`. Rejette (HTTP 403) toute image non signée ou altérée. |
| **`require-run-as-non-root`** | `require-non-root.yaml` | `Validate` / **`Enforce`** | `Pod` dans `omnipay-prod`, `omnipay-recette` | Exige `spec.securityContext.runAsNonRoot: true`. Bloque tout conteneur tentant de démarrer sous UID `0` (`root`). |
| **`disallow-host-path-and-privileged`** | `disallow-host-path-and-privileged.yaml` | `Validate` / **`Enforce`** | `Pod` dans `omnipay-*` | 3 règles : interdit les volumes `hostPath`, interdit `securityContext.privileged: true` (`containers`, `initContainers`, `ephemeralContainers`) et bloque les capacités Linux critiques (`SYS_ADMIN`, `NET_ADMIN`, `SYS_PTRACE`). |
| **`require-ro-rootfs-and-drop-all`** | `require-ro-rootfs-and-drop-all.yaml` | `Validate` / **`Enforce`** | `Pod` dans `omnipay-*` | Exige `readOnlyRootFilesystem: true` (système de fichiers racine immuable, écriture bornée à `/tmp` en `emptyDir`) et `capabilities.drop: ["ALL"]`. |
| **`mutate-inject-zero-trust-labels`** | `mutate-inject-zero-trust-labels.yaml` | `Mutate` | `Pod`, `Deployment` dans `omnipay-*` | Injecte automatiquement les labels obligatoires (`security.omnipay.local/enforced: "true"`, `app.kubernetes.io/managed-by: "argocd"`, `network.omnipay.local/segment: "banking-core"`) et le profil `seccompProfile.type: RuntimeDefault`. |

### Points d'attention pour la vérification en direct (Démo 2)

- Les rejets émettent des événements Kubernetes `Warning` (`reason=PolicyViolation`) consultables avec :
  `kubectl get events -n omnipay-prod --field-selector reason=PolicyViolation`
- Les images de production (`auth-service`, `transaction-service`, `notification-service`) respectent intégralement le profil **Pod Security Standards (Restricted)** (`runAsUser: 10001`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`).

---

## 3. Stratégie Argo Rollouts, Métriques RED & Auto-Rollback

Pour `transaction-service` en production (`envs/prod/transaction-service-rollout.yaml`), l'objet natif Kubernetes `Deployment` est remplacé par un CRD **`Rollout`** (`ADR-007` et `ADR-012`).

### 3.1 Paliers progressifs Canary

```text
[v1.0.0 - 100%]
      │
      ▼  Livraison nouvelle image
[Palier 1 : 10% Trafic] ── pause 1m ──► AnalysisTemplate (prometheus-error-rate)
      │ (OK)
      ▼
[Palier 2 : 33% Trafic] ── pause 1m ──► AnalysisTemplate (prometheus-error-rate)
      │ (OK)
      ▼
[Palier 3 : 66% Trafic] ── pause 1m ──► AnalysisTemplate (prometheus-error-rate)
      │ (OK)
      ▼
[Palier 4 : 100% Trafic] ──► Promotion complète
```

- **Blast Radius borné à 10%** : Au Palier 1, seul 1 pod Canary sur 4 expose la nouvelle révision tandis que `transaction-service-active` continue de desservir la clientèle sur `1.0.0`.

### 3.2 Intégration Prometheus & Couverture des Métriques RED

La stratégie s'appuie sur la triade **RED** collectée par `kube-prometheus-stack` (`ServiceMonitor` sur le port Actuator `:8081`, path `/actuator/prometheus`) :

| Pilier RED | Métrique Spring Boot / Micrometer | Rôle dans la gouvernance OmniPay |
| :--- | :--- | :--- |
| **R — Rate** (Débit) | `rate(http_server_requests_seconds_count{service="transaction-service"}[2m])` | Dénominateur du calcul de taux d'erreur et suivi RPS Grafana (P5). |
| **E — Errors** (Erreurs 5xx) | `rate(http_server_requests_seconds_count{service="transaction-service", status=~"5.."}[2m])` | **Garde-fou bloquant** dans l'`AnalysisTemplate` `prometheus-error-rate`. |
| **D — Duration** (Latence P95) | `histogram_quantile(0.95, sum(rate(http_server_requests_seconds_bucket[5m])) by (le))` | Surveillée dans le dashboard SLO Grafana (`< 200ms`) et corrélée aux traces Tempo (P5). |

### 3.3 Requête PromQL & Mécanisme d'Auto-Rollback (`< 30s`)

Extrait de `envs/prod/transaction-service-analysis.yaml` :
- **Adresse Prometheus interne** : `http://monitoring-kube-prometheus-prometheus.monitoring.svc:9090`
- **Intervalle & Tolérance** : `interval: 15s`, `count: 3`, `failureLimit: 1`
- **Condition de succès** : `successCondition: result[0] < 0.5` (taux 5xx strictement `< 0.5%`, soit bien en deçà du seuil critique `> 2%` lors d'une panne simulée à 50% HTTP 500)
- **Comportement en cas d'échec** :
  1. L'`AnalysisRun` passe en `Phase: Failed` dès la première mesure hors seuil (`failureLimit: 1`).
  2. Le contrôleur Argo Rollouts marque le Rollout **`Degraded` / `Aborted`** (`RolledBack`).
  3. Le ReplicaSet Canary (`v2.0.0-unstable`) est immédiatement ramené à 0 pod ; **100% du trafic reste servi par `v1.0.0` sans interruption de service**.
- **Principe *Fail-Safe Defaults*** : Si Prometheus est injoignable, l'`AnalysisRun` échoue/passe en `Error` et bloque la promotion automatique au lieu de valider aveuglément le déploiement.

---

## 4. Commandes Clés pour la Soutenance & l'Audit

### Exécution des démonstrations en direct

```bash
# Démo 2 (~2 min) : Admission Kyverno (image non signée, root/privileged, image signée Cosign)
bash scripts/run-demo-2-kyverno-live.sh

# Démo 1 (~3 min) : Canary v2.0.0-unstable (10%) & Auto-Rollback Prometheus (< 30s)
bash scripts/run-demo-1-canary-live.sh

# Audit complet ArgoCD + Nettoyage Harbor (fournir HARBOR_PASSWORD via variable d'environnement)
export HARBOR_PASSWORD="<votre-mot-de-passe>"
bash scripts/audit-gitops-harbor.sh --dry-run
```

### Équivalents Windows PowerShell 7+

```powershell
.\scripts\run-demo-2-kyverno-live.ps1
.\scripts\run-demo-1-canary-live.ps1
$env:HARBOR_PASSWORD = "<votre-mot-de-passe>"
.\scripts\audit-gitops-harbor.ps1 -DryRun
```

### Cartographie rapide des interfaces (Zéro conflit de ports)

| Service | Port / NodePort | URL |
| :--- | :--- | :--- |
| **Harbor Registry** | `30002` | `http://harbor.omnipay.local:30002` |
| **SonarQube** | `30003` | `http://sonarqube.omnipay.local:30003` |
| **ArgoCD UI** | `30005` | `http://argocd.omnipay.local:30005` |
| **Grafana** | `30300` | `http://grafana.omnipay.local:30300` |
| **Prometheus** | `30900` | `http://prometheus.omnipay.local:30900` |
| **Argo Rollouts UI** | `3100` | `http://localhost:3100` (`kubectl argo rollouts dashboard`) |
