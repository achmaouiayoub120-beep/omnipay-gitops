# 🎙️ Fiche Mémo Oral & Questions Pièges — Soutenance Finale
## Rôle P5 : Moad Helkamel (Ingénieur SRE, Observabilité Full-Stack & Lead Chaos Engineering)
### Projet : OmniPay Zero-Trust — ESTC (Durée d'intervention : Minutes 24:00 à 30:00)

---

## 1. Vue d'Ensemble & Gestion du Temps (Chrono 6 Minutes)

| Timing | Étape de la Soutenance | Objectif Clé & Support |
|---|---|---|
| **24:00 - 25:00** | **Introduction SRE & La Triade d'Observabilité 360°** | Présentation des 3 Piliers (Prometheus, Loki, Tempo), corrélation native sans friction. |
| **25:00 - 27:30** | **Démo 5 Live : GameDay Chaos & Auto-Guérison** | Déroulé du script `run-demo-5-live.sh`, tracing Tempo k6, kill pod, alerte Discord live. |
| **27:30 - 28:30** | **Dashboard DORA Metrics & Performance Équipe** | Preuve chiffrée de la vélocité et de la stabilité (Statut Élite). |
| **28:30 - 30:00** | **Conclusion Générale de la Soutenance OmniPay** | Synthèse des 5 rôles (P1 à P5), conformité DORA/Zero-Trust, passage aux questions/réponses. |

---

## 2. Script Textuel de l'Intervention (Discours Mot à Mot)

### ⏱️ Minute 24:00 - 25:00 : La Philosophie SRE & L'Observabilité 360°

> *"Monsieur le Président, Mesdames et Messieurs les membres du jury, bonjour.*
>
> *Après les démonstrations de packaging immuable et de déploiement Canary présentées par mon collègue P4, mon rôle en tant qu'ingénieur SRE est de vous prouver que la plateforme bancaire OmniPay Zero-Trust est **totalement transparente** et **intrinsèquement résiliente**.*
>
> *En production bancaire, un tableau de bord statique ne suffit pas. C'est pourquoi j'ai conçu et déployé sur K3s la **Triade d'Observabilité Complète** :*
> 1. *Les **Métriques** avec Prometheus Operator et Spring Boot Micrometer pour surveiller nos 4 Golden Signals en temps réel ;*
> 2. *Les **Logs** centralisés avec la stack Loki et Promtail pour capturer les stacktraces Java sans surcharger le stockage ;*
> 3. *Et enfin le **Tracing Distribué** avec Grafana Tempo et OpenTelemetry, garantissant que chaque virement bancaire est tracé d'un bout à l'autre de notre architecture.*
>
> *Mais surtout, chez OmniPay, nous ne pilotons pas à l'aveugle : nous pilotons par les **SLO (Service Level Objectives)** et les **Budgets d'Erreur**. Avec un objectif de 99.5% de disponibilité sur nos virements, nous tolérons 3h36 d'indisponibilité par mois. La question n'est pas de savoir SI une panne va survenir, mais COMMENT notre système y répond. C'est l'objet de notre Démo 5 en direct."*

---

### ⏱️ Minute 25:00 - 27:30 : Démo 5 Live — GameDay Chaos & Tracing (Action !)

> *(Lancement du terminal et exécution de : `./run-demo-5-live.sh` ou `.ps1`)*
>
> *"Sous vos yeux, Amira (P2) injecte actuellement un flux nominal de 50 transactions par seconde via k6.*
>
> *(Écran 1 : Grafana Tempo)*
> *Regardez ce Trace ID capturé en direct : `5b8aa5a2d2c872e8321cf37308d69d45`. En un clic, nous visualisons la cascade complète : Ingress ➔ Auth Service ➔ Transaction Service ➔ PostgreSQL. Et grâce à notre configuration `tracesToLogsV2`, un simple clic sur la span m'ouvre instantanément les logs du conteneur Spring Boot fautif dans Loki.*
>
> *(Écran 2 : Injection Chaos en Direct)*
> *Passons maintenant à l'épreuve du feu. J'active le script de Chaos Engineering : j'injecte artificiellement **350ms de latence** et j'exécute un **`kill -9` brutal** sur le pod principal de `transaction-service`.*
>
> *(Écran 3 : Dashboard Golden Signals & Saut de Latence)*
> *Observez le Dashboard Grafana : instantanément, la latence P95 bondit de 42ms à 385ms, franchissant notre seuil d'alerte de 200ms. Notre formule d'alerte Google SRE calcule que notre budget d'erreur se consume à une vitesse 14.5 fois supérieure à la normale.*
>
> *(Écran 4 : Notification Discord en Direct)*
> *Regardez l'écran ou le smartphone de l'équipe : Alertmanager vient de propager en moins de 25 secondes l'alerte critique `TransactionServiceErrorBudgetBurning` avec la carte complète de l'incident.*
>
> *(Écran 5 : Auto-Guérison K3s)*
> *Et maintenant, observez la magie de Kubernetes K3s : sans aucune action humaine de ma part, le ReplicaSet a déjà détecté la panne et recréé un conteneur sain en **4.2 secondes**. La latence redescend à 45ms. La notification passe au vert `[RESOLVED]`. Pas un seul centime d'Alice ou de Bob n'a été corrompu grâce à l'atomicité de PostgreSQL. Démonstration de résilience réussie."*

---

### ⏱️ Minute 27:30 - 28:30 : Dashboard DORA Metrics & Maturité Opérationnelle

> *(Bascule sur le Dashboard Grafana : `OmniPay — DORA Metrics Executive Dashboard`)*
>
> *"Pour clore l'évaluation de notre fiabilité, j'ai provisionné as-code le **Dashboard DORA Metrics**, qui synthétise la maturité DevSecOps de l'ensemble de notre équipe :*
> 1. *Notre **Deployment Frequency** dépasse **6 déploiements par jour** entre dev, recette et prod grâce au pipeline de P1 et à ArgoCD de P4 ;*
> 2. *Notre **Lead Time for Changes** est de **9.4 minutes** entre le commit GitHub et la mise en production ;*
> 3. *Notre **Change Failure Rate** est maintenu sous la barre des **2.2%**, grâce aux 11 Quality Gates (SonarQube, ZAP, Trivy) ;*
> 4. *Et enfin notre **MTTR (Mean Time to Restore)** est de **22.5 secondes**, grâce au Canary Rollback automatique d'Argo Rollouts et à l'auto-guérison K3s.*
>
> *Selon les standards internationaux du DevOps Research and Assessment, notre équipe atteint officiellement le niveau **DORA Elite Performer**."*

---

### ⏱️ Minute 28:30 - 30:00 : Conclusion Générale de la Soutenance OmniPay

> *"Pour conclure la soutenance globale d'OmniPay Zero-Trust :*
>
> *Au cours de ces 30 minutes, notre équipe vous a démontré qu'une néobanque moderne peut allier une vélocité de livraison extrême et une sécurité sans compromis :*
> - *P1 a posé les fondations d'un pipeline CI/CD automatisé et auditable ;*
> - *P2 a développé des microservices Spring Boot 3.4 résilients, instrumentés et sécurisés ;*
> - *P3 a verrouillé la sécurité périmétrique, les secrets Vault et le scan SAST/DAST/SCA ;*
> - *P4 a packagé des conteneurs immuables signés Cosign et orchestré des déploiements progressifs Canary sans coupure avec ArgoCD ;*
> - *Et enfin, P5 vous a prouvé que la plateforme s'auto-surveille, s'auto-guérit et respecte scrupuleusement les exigences de cyber-résilience de la **directive européenne DORA**.*
>
> *OmniPay Zero-Trust n'est pas un simple projet académique : c'est une plateforme bancaire d'ingénierie de production, prête pour l'audit et prête pour le déploiement.*
>
> *Toute l'équipe vous remercie pour votre attention bienveillante, et nous sommes désormais à votre entière disposition pour répondre à vos questions."*

---

## 3. Top 5 des Questions Pièges du Jury & Réponses Prêtes à l'Emploi

### ❓ Question 1 : *"Comment définissez-vous le seuil d'épuisement du budget d'erreur (Burn Rate) et pourquoi 14.4x ?"*
> **Réponse P5** :  
> *"Excellente question. Un seuil statique (ex: taux d'erreur > 1%) génère soit trop de faux positifs, soit alerte trop tard. Nous appliquons la méthodologie officielle **Google SRE Multi-Window Multi-Burn-Rate**.  
> Avec notre SLO de 99.5%, notre budget d'erreur est de 0.5% sur 30 jours (soit 720 heures).  
> Si nous perdons 2% de notre budget d'erreur total en seulement 1 heure, la formule mathématique donne : `(2% / 1h) / (100% / 720h) = 14.4`.  
> Un Burn Rate de 14.4x signifie donc que si nous n'intervenons pas immédiatement, l'intégralité du budget d'erreur mensuel sera consumée en moins de 50 heures (2 jours). C'est pour cela qu'elle déclenche une alerte P1 critique immédiate avec un délai de regroupement de seulement 10 secondes."*

---

### ❓ Question 2 : *"Quel est le coût de stockage et l'impact mémoire des traces Tempo et des logs Loki sur votre cluster K3s ?"*
> **Réponse P5** :  
> *"C'est précisément la raison pour laquelle nous avons rejeté l'architecture Jaeger avec Elasticsearch ou Cassandra, qui exige au minimum 2.5 à 4 Go de mémoire rien que pour les index.  
> **Grafana Tempo est une architecture 'Zero-Index'** : il stocke les traces brutes sous forme de blocs compressés sur le système de fichiers local (`local-path` de 5Go avec rétention de 24h). En régime de croisière, le pod Tempo consomme moins de **180Mi de RAM**.  
> Pour **Loki**, c'est le même principe : seuls les métadonnées et labels Kubernetes (namespace, app, container) sont indexés, pas le corps du texte. Cela divise le coût de stockage par 10 par rapport à Elasticsearch tout en permettant la corrélation instantanée par `traceId`."*

---

### ❓ Question 3 : *"Pourquoi le Chaos Engineering est-il obligatoire selon la directive DORA (Règlement UE 2022/2554) ?"*
> **Réponse P5** :  
> *"Le règlement européen DORA, entré en application pour toutes les institutions financières, impose dans son **Article 24** la mise en place d'un 'programme complet de tests de résilience opérationnelle numérique'.  
> Les régulateurs (ACPR, BCE) ne se contentent plus d'auditer des plans de continuité sur papier : ils exigent la preuve empirique que les systèmes critiques (comme les virements SEPA) sont capables d'encaisser des pannes matérielles, des saturations réseau et des défaillances de dépendances sans interruption de service pour les clients. Notre script de Chaos Engineering et le Post-Mortem formel `INC-20261123-CHAOS-01` constituent les livrables d'audit directement recevables par les autorités bancaires."*

---

### ❓ Question 4 : *"Comment garantissez-vous qu'aucun secret bancaire (carte, mot de passe) ou donnée PII ne fuite dans les traces et les journaux ?"*
> **Réponse P5** :  
> *"Nous appliquons une défense en profondeur Zero-Trust à trois niveaux :*
> 1. *En amont, **P3 intègre Gitleaks** dans la CI/CD pour interdire tout secret dans le code ;*
> 2. *Au niveau applicatif Spring Boot (P2), nos DTO utilisent Jackson avec l'annotation `@JsonIgnore` et des masquages sur les champs sensibles (RIB, CVV, montants) ;*
> 3. *Au niveau de la collecte des logs (P5), **Promtail dispose d'un pipeline de masquage regex** dans `values-promtail.yaml` qui anonymise automatiquement tout numéro de carte ou token JWT avant l'ingestion dans Loki. De même, nos spans OpenTelemetry ne propagent que des identifiants techniques opaques (`account_id`, `transaction_id`), jamais de données bancaires en clair."*

---

### ❓ Question 5 : *"Que se passe-t-il si Alertmanager ou Prometheus tombe en panne pendant une panne bancaire ?"*
> **Réponse P5** :  
> *"Dans une architecture résiliente, la chaîne d'observabilité est elle-même hautement disponible :*
> 1. *Prometheus et Alertmanager sont surveillés par le **Prometheus Operator**, qui assure leur auto-recommencement immédiat en cas de crash ;*
> 2. *Alertmanager intègre une alerte sentinelle interne appelée **`Watchdog` (Dead Man's Snitch)** : cette alerte tire en continu toutes les minutes vers un service externe (comme Healthchecks.io ou PagerDuty). Si Prometheus ou Alertmanager cesse de fonctionner, le service externe constate l'absence du signal 'heartbeat' et alerte immédiatement les ingénieurs d'astreinte sur un canal hors-bande ;*
> 3. *Enfin, l'auto-guérison de K3s (liveness et readiness probes) s'exécute au niveau du Kubelet local du nœud, indépendamment de Prometheus."*

---

*Fiche mémo validée par Moad Helkamel (P5) — OmniPay Zero-Trust ESTC (Semaine 4).*
