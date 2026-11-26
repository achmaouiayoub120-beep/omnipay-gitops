# Mémo Oral Soutenance — Rôle P4 (18:00 à 24:00)

**Intervenante** : Widad El Gharzaz (P4) — Ingénieure Plateforme, Supply Chain Security & Lead GitOps  
**Projet** : OmniPay Zero-Trust (ESTC)  
**Créneau** : **18:00 → 24:00** (6 minutes chrono)  
**Séquence** : Positionnement Supply Chain & GitOps → **Démo 2 Live (~2 min)** → **Démo 1 Live (~3 min)** → Transition vers **Moad (P5 — SRE & Observabilité)**

---

## 1. Pré-check Technique Avant Passage (à T-5 min)

- [ ] Terminal prêt à la racine de `omnipay-gitops` avec contexte `kubectl` pointant sur K3s.
- [ ] Vérifier l'état initial : `kubectl get rollout transaction-service -n omnipay-prod` (`Healthy`, image `1.0.0` à 100%).
- [ ] Vérifier les politiques Kyverno actives : `kubectl get clusterpolicy` (5 politiques `Ready=True`).
- [ ] Onglets navigateur ouverts en arrière-plan :
  - Harbor (`http://harbor.omnipay.local:30002`) — projet `omnipay`, scan Trivy & icône signature Cosign.
  - ArgoCD (`http://argocd.omnipay.local:30005`) — `omnipay-dev`, `omnipay-recette`, `omnipay-prod`.
  - Argo Rollouts Dashboard (`http://localhost:3100` via `kubectl argo rollouts dashboard`) ou terminal dédié avec `kubectl argo rollouts get rollout transaction-service -n omnipay-prod --watch`.
- [ ] Aucun secret affiché à l'écran ni dans les commandes tapées.

---

## 2. Déroulé Minute par Minute (18:00 → 24:00)

| Créneau | Durée | Séquence | Actions écran / Commandes | Message clé Jury |
| :--- | :--- | :--- | :--- | :--- |
| **18:00 – 18:45** | 45s | **Positionnement Supply Chain & GitOps** | Montrer schéma ou UI Harbor + ArgoCD (`omnipay-environments`). | « Jenkins ne touche jamais à la prod : GitOps Pull + registre Harbor durci + Cosign + Kyverno. » |
| **18:45 – 20:45** | 2m 00s | **Démo 2 Live : Admission Kyverno + Cosign** | Lancer `bash scripts/run-demo-2-kyverno-live.sh` (ou `.ps1`). | Scénarios A (image non signée rejetée), B (`privileged`/`runAsUser: 0` rejetés), C (image signée Harbor `Running`). |
| **20:45 – 23:30** | 2m 45s | **Démo 1 Live : Canary & Auto-Rollback** | Lancer `bash scripts/run-demo-1-canary-live.sh` (ou `.ps1`). | `v1.0.0` 100% → Canary `v2.0.0-unstable` à 10% → 5xx > 2% via Prometheus → rollback `< 30s` sans coupure. |
| **23:30 – 24:00** | 30s | **Synthèse & Transition vers Moad (P5)** | Pointer vers l'`AnalysisRun` et la requête PromQL. | Passage de relais naturel : « Les métriques utilisées par notre rollback proviennent du socle SRE de Moad (P5). » |

---

## 3. Script Oral & Conduite des Démonstrations en Direct

### 3.1 Accroche & Architecture Supply Chain (18:00 – 18:45)

> *« Merci. Pour garantir qu'aucun artefact compromis ou non audité n'atteigne la production bancaire d'OmniPay, j'ai conçu la chaîne d'approvisionnement Zero-Trust autour de quatre verrous complémentaires :*
> *1. **Harbor** sur le port 30002, avec scan Trivy automatique bloquant toute CVE critique et tags strictement immuables ;*
> *2. **Cosign et Syft**, qui attachent un SBOM SPDX et une signature cryptographique ECDSA à chaque image ;*
> *3. **ArgoCD**, en modèle GitOps Pull via un `ApplicationSet` sur `dev`, `recette` et `prod` — Jenkins n'a donc aucun `kubeconfig` sur le cluster ;*
> *4. **Kyverno**, qui vérifie cette signature et les règles Pod Security Standards avant toute création de Pod dans `etcd`.*
> *Passons immédiatement à la preuve en direct avec la Démo 2. »*

---

### 3.2 Conduite en Direct — Démo 2 : Barrière d'Admission Kyverno (~2 min : 18:45 – 20:45)

Lancer la commande :
```bash
bash scripts/run-demo-2-kyverno-live.sh
# (Sous Windows PowerShell 7+ : .\scripts\run-demo-2-kyverno-live.ps1)
```

Commentaire oral synchronisé sur les 3 scénarios à l'écran :
1. **Scénario A — Image publique non signée (`nginx:alpine` + image non signée Harbor)** :
   > *« Premier test : j'essaie de déployer une image publique non signée `nginx:alpine`, puis une image non signée dans Harbor. Kyverno intercepte l'appel au niveau du webhook d'admission et renvoie immédiatement un **HTTP 403 Forbidden** : aucun pod n'est créé dans `omnipay-prod`. »*
2. **Scénario B — Élévation de privilèges (`privileged: true` et `runAsUser: 0`)** :
   > *« Deuxième test : même avec une image signée, si un manifeste tente d'exécuter un conteneur en `privileged: true` ou en `root` (`runAsUser: 0`), les politiques `disallow-host-path-and-privileged` et `require-run-as-non-root` bloquent la requête à l'entrée. Nos conteneurs sont forcés en `readOnlyRootFilesystem: true` et `capabilities.drop: [ALL]`. »*
3. **Scénario C — Image signée Cosign depuis `harbor.omnipay.local:30002`** :
   > *« Troisième test : je déploie maintenant `transaction-service:1.0.0`, signée avec notre clé Cosign et conforme Zero-Trust. Kyverno valide la signature, injecte automatiquement nos labels de gouvernance (`security.omnipay.local/enforced: true`) et le profil `seccompProfile: RuntimeDefault`, et le Pod passe bien à l'état **`Running`**. »*

---

### 3.3 Conduite en Direct — Démo 1 : Canary Argo Rollouts & Auto-Rollback (~2m45 : 20:45 – 23:30)

Lancer la commande :
```bash
bash scripts/run-demo-1-canary-live.sh
# (Sous Windows PowerShell 7+ : .\scripts\run-demo-1-canary-live.ps1)
```

Commentaire oral synchronisé :
1. **État initial stable (`v1.0.0` à 100%)** :
   > *« Maintenant que se passe-t-il si une image **bien signée** contient un bug fonctionnel critique ? Voici notre `Rollout` `transaction-service` en production : `v1.0.0` est `Healthy` à 100% du trafic. »*
2. **Déclenchement du Canary `v2.0.0-unstable` au palier 10%** :
   > *« Je déclenche le déploiement de `transaction-service:v2.0.0-unstable`, qui simule 50% d'erreurs HTTP 500. Grâce à Argo Rollouts, au lieu de remplacer tout le parc comme un `RollingUpdate` classique, **le Blast Radius est confiné à 10%** : un seul pod Canary reçoit du trafic, tandis que les réplicas `1.0.0` continuent de servir les clients. »*
3. **Analyse Prometheus & Auto-Rollback `< 30s`** :
   > *« Pendant que le trafic bancaire circule, l'`AnalysisTemplate` `prometheus-error-rate` interroge Prometheus sur le taux d'erreurs HTTP 5xx. Dès que le seuil critique (> 2%, configuré à < 0.5% dans notre SLO Guardrail) est franchi, l'`AnalysisRun` passe en `Failed`. En **moins de 30 secondes** et sans aucune intervention humaine, Argo Rollouts passe en statut **`Degraded` / `RolledBack`**, détruit le pod Canary et maintient **100% du trafic sur `v1.0.0` sans aucune coupure de service**. »*

**Plan B en cas de latence réseau/cluster pendant le direct** :
- Garder `scripts/audit-gitops-harbor.sh --dry-run` prêt pour afficher en 3 secondes la conformité `Synced / Healthy` des 3 environnements et les événements `PolicyViolation` déjà enregistrés.
- Si le prompt interactif de réinitialisation apparaît en fin de Démo 1, valider par `O` (ou utiliser `--auto-reset`) pour laisser le cluster propre pour P5.

---

### 3.4 Transition vers Moad (P5 — SRE & Observabilité) (23:30 – 24:00)

> *« Vous venez de voir comment Argo Rollouts protège la production en temps réel en interrogeant les métriques Prometheus dès le palier 10%. Mais cette détection automatique ne serait pas possible sans une chaîne d'observabilité complète : métriques RED, tableaux de bord SLO, alertes Burn Rate, centralisation des logs et tracing distribué. Je passe maintenant la main à **Moad (P5)**, qui va vous présenter l'architecture SRE, l'observabilité 360° et le Game Day en production. »*

---

## 4. Top 5 des Questions Pièges du Jury & Réponses Préparées

### Question 1 : « Pourquoi avoir choisi Kyverno plutôt qu'OPA Gatekeeper ? »
**Réponse préparée** :
- **Natifs Kubernetes en YAML** : Les politiques Kyverno sont de simples ressources `ClusterPolicy` en YAML, lisibles et maintenables par toute l'équipe DevSecOps sans imposer l'apprentissage du langage **Rego** (courbe d'apprentissage élevée sur OPA Gatekeeper).
- **Vérification Cosign intégrée (`verifyImages`)** : Kyverno vérifie nativement les signatures Cosign et attestations OCI Harbor sans déployer de composant tiers supplémentaire (contrairement à Gatekeeper qui nécessite **Ratify** + provider externe).
- **Capacités de mutation et génération natives** : Kyverno nous permet à la fois de **valider** (`Enforce`), de **muter** automatiquement les labels Zero-Trust et `seccompProfile: RuntimeDefault`, tout en gardant une empreinte mémoire adaptée à K3s (`ADR-005`).

### Question 2 : « Que se passe-t-il pendant un déploiement Canary si Prometheus devient indisponible ou injoignable ? »
**Réponse préparée** :
- Nous appliquons strictement le principe Zero-Trust ***Fail-Safe Defaults*** (`ADR-012`).
- Si Prometheus est indisponible au moment où l'`AnalysisRun` exécute sa requête PromQL, l'appel HTTP échoue, la métrique passe en état **`Error` / `Inconclusive`** (après le `failureLimit` configuré à `1`), et **Argo Rollouts bloque immédiatement la promotion** (voire avorte vers la révision stable) au lieu de promouvoir une version non vérifiée à l'aveugle.
- En d'autres termes : *« pas de signal d'observabilité valide = pas de mise en production »*.

### Question 3 : « En quoi votre approche GitOps (ArgoCD + Harbor + Kyverno) répond-elle aux exigences de conformité PCI-DSS ? »
**Réponse préparée** :
- **Séparation des tâches et moindre privilège (PCI-DSS Req. 7 & 6.4)** : La CI (Jenkins) ne dispose d'aucun accès direct au cluster de production ; toute promotion passe par Git (`omnipay-gitops`) avec revue et historique immuable, puis tirée par ArgoCD (`omnipay-prod` en synchronisation manuelle contrôlée).
- **Piste d'audit immuable (Req. 10)** : Chaque déploiement est corrélé à un commit Git signé/identifié, à un digest immuable dans Harbor, et aux événements Kubernetes (`PolicyViolation`, `AnalysisRun`).
- **Protection de l'intégrité logicielle et des secrets (Req. 2, 3 & 6)** : Zéro secret en clair dans Git, scan Trivy bloquant les CVE critiques avant même le pull, vérification cryptographique Cosign à l'admission, et exécution non-root en `readOnlyRootFilesystem: true`.
- **Anti-drift (`selfHeal`)** : Toute modification manuelle non autorisée sur `dev`/`recette` est détectée et corrigée automatiquement par ArgoCD.

### Question 4 : « Comment gérez-vous le risque de compromission ou de rotation de la clé privée Cosign (`cosign.key`) ? »
**Réponse préparée** :
- La clé privée `cosign.key` est chiffrée (`COSIGN_PASSWORD`) et stockée exclusivement dans les secrets protégés de la CI / Vault, **jamais dans Git** (seule `cosign.pub` est versionnée dans `platform/kyverno/keys/cosign.pub`).
- En cas de rotation périodique ou de suspicion de compromission :
  1. Génération d'une nouvelle paire via `platform/kyverno/keys/generate-keys.sh` et révocation immédiate de l'ancienne clé dans Jenkins/Vault.
  2. Fenêtre de transition dans la `ClusterPolicy` `verify-omnipay-image-signature` (section `attestors`) en autorisant temporairement la nouvelle clé publique à côté de l'ancienne le temps de re-signer/promouvoir les images actives, puis retrait définitif de l'ancienne clé.
- À terme, en environnement connecté, l'architecture est prête pour basculer vers **Sigstore Keyless** (OIDC + Fulcio + Rekor) afin d'éliminer totalement les clés statiques longue durée.

### Question 5 : « Pourquoi ne pas utiliser un Service Mesh (Istio) avec Flagger pour le Canary, et comment gérez-vous un rollback si la base de données a changé de schéma ? »
**Réponse préparée** :
- **Choix Argo Rollouts vs Istio + Flagger (`ADR-012`)** : Un Service Mesh complet (Istio + sidecars Envoy sur chaque pod) consomme plusieurs gigaoctets de RAM et ajoute une complexité réseau disproportionnée pour un cluster K3s bancaire compact. Argo Rollouts + Ingress NGINX assure le routage pondéré (`10% -> 33% -> 66% -> 100%`) et l'analyse Prometheus avec une empreinte mémoire minime.
- **Compatibilité des migrations SQL lors d'un rollback** : Un rollback d'image (`v2 -> v1`) échoue si `v2` a exécuté une migration destructive (`DROP COLUMN`). Nous imposons le pattern **Expand & Contract** (Flyway/Liquibase) : la phase d'ajout (nouvelle colonne nullable / table) reste 100% rétrocompatible avec `v1.0.0` pendant toute la durée du Canary ; le nettoyage (`Contract`) n'intervient qu'après promotion complète et stabilisation à 100%.
