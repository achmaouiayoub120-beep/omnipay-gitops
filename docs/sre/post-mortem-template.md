# 📋 Modèle de Post-Mortem SRE (Blameless Post-Mortem)
## OmniPay Zero-Trust | Gouvernance Fiabilité & Observabilité (Rôle P5)

> **Philosophie Google SRE** : Un post-mortem n'a pas pour but de blâmer un individu, mais de comprendre les faiblesses systémiques de l'architecture et des processus pour immuniser la plateforme contre des pannes futures.

---

## 1. Métadonnées de l'Incident

| Paramètre | Valeur |
|---|---|
| **Identifiant Incident** | `INC-2026-XXXX` |
| **Titre** | `[INCIDENT] Indisponibilité / Dégradation critique sur <Service>` |
| **Sévérité** | `CRITICAL (SEV-1)` / `MAJOR (SEV-2)` / `MINOR (SEV-3)` |
| **Date & Heure Début (UTC)** | `AAAA-MM-JJ HH:MM:SS` |
| **Date & Heure Résolution (UTC)** | `AAAA-MM-JJ HH:MM:SS` |
| **Durée totale d'interruption** | `X minutes / secondes` |
| **Lead Investigator (SRE P5)** | Moad Helkamel |
| **Équipe de réponse** | P2 (Backend), P3 (CI/CD), P4 (Packaging & GitOps), P5 (SRE) |
| **Services impactés** | `auth-service` / `transaction-service` / `notification-service` / `postgres` |

---

## 2. Indicateurs Clés de Fiabilité (SRE Metrics)

| Métrique SRE | Valeur | Cible / SLO | Évaluation |
|---|---|---|---|
| **Time to Detect (TTD)** | `XX secondes` | < 60s | ✅ / ⚠️ / ❌ |
| **Time to Mitigate (TTM)** | `XX secondes` | < 120s | ✅ / ⚠️ / ❌ |
| **Time to Resolve (TTR)** | `XX secondes` | < 300s | ✅ / ⚠️ / ❌ |
| **Impact Budget d'Erreur (30j)** | `X.X%` du budget mensuel | < 5% par incident | ✅ / ⚠️ / ❌ |
| **SLO Disponibilité résiduel** | `99.XX%` | 99.5% | Conforme / Menacé |

---

## 3. Résumé Exécutif pour le Management

_Décrire en 2 ou 3 phrases simples l'incident, le symptôme visible par les clients de la banque OmniPay, et la résolution appliquée._

Exemple :  
*Le 22 Novembre 2026 à 14h30 UTC, le service de virements bancaires (`transaction-service`) a subi un pic d'erreurs 500 consécutif à une interruption brutale du conteneur. Grâce aux sondes K3s et au Canary Rollback, le pod a été auto-cicatrisé en 3.2 secondes. Le budget d'erreur mensuel a absorbé 1.2% sans rupture de l'engagement de service de 99.5%.*

---

## 4. Chronologie Détaillée des Événements (Timeline UTC)

| Heure (UTC) | Acteur / Système | Action ou Détection observée |
|---|---|---|
| **T+00:00** | Système / Chaos | Injection de panne ou incident : pod tué ou latence réseau anormale |
| **T+00:15** | Prometheus | Scrape Actuator échoue (`up == 0` ou latence P95 > 200ms) |
| **T+00:30** | PrometheusRule | L'alerte `OmniPayMicroserviceDown` ou `OmniPayBurnRateCritical` passe à l'état `PENDING` |
| **T+00:45** | Alertmanager | Déclenchement de l'alerte à l'état `FIRING`, transmission au webhook Discord / Telegram |
| **T+01:00** | Équipe SRE / K3s | K3s kubelet planifie un nouveau conteneur sain sur le nœud |
| **T+01:15** | Conteneur | Démarrage Spring Boot 3.4 et passage des Readiness Probes `/actuator/health` |
| **T+01:30** | Alertmanager | Détection de retour à la normale, émission de la notification `[RESOLVED]` |

---

## 5. Analyse des Causes Racines (Root Cause Analysis — Les 5 Pourquoi)

1. **Pourquoi les transactions bancaires ont-elles échoué ?**  
   ➔ Le pod `transaction-service` n'était plus joignable sur le port 8082.
2. **Pourquoi le pod n'était-il plus joignable ?**  
   ➔ Le processus Java s'est arrêté brutalement (OOMKilled ou Pod Eviction).
3. **Pourquoi le conteneur a-t-il été arrêté ?**  
   ➔ La limite mémoire du conteneur (256Mi) a été dépassée lors d'un pic de requêtes.
4. **Pourquoi un seul pod absorbait-il tout le trafic ?**  
   ➔ Le ReplicaSet en environnement hors-prod était configuré à `replicas: 1`.
5. **Cause racine systémique (Root Cause)** :  
   ➔ Absence de politique de haute disponibilité active (`replicas: 2+`, PodDisruptionBudget et HorizontalPodAutoscaler calibré sur la mémoire Heap JVM).

---

## 6. Analyse d'Impact Zero-Trust & Sécurité

- **Intégrité des données financières** : Aucune transaction corrompue ; transactions en vol rejetées proprement avec rollback transactionnel PostgreSQL (`ACID`).
- **Surface d'attaque & Confidentialité** : Aucun secret ou token JWT n'a fuité dans les logs (filtrage Gitleaks et règles de masquage Promtail respectés).
- **Politiques Kyverno** : Le nouveau conteneur a été admis dans le cluster avec signature Cosign valide et profil `restricted` sans privilèges root.

---

## 7. Ce qui a bien fonctionné vs Ce qui doit être amélioré

### ✅ Ce qui a bien fonctionné :
- Détection ultra-rapide par Prometheus en moins de 30 secondes.
- Notification instantanée reçue sur le canal Discord de l'équipe SRE.
- Auto-guérison native de K3s restaurant le service sans intervention manuelle humaine.
- Corrélation instantanée dans Grafana (Métriques ➔ Traces Tempo ➔ Logs Loki).

### ⚠️ Ce qui doit être amélioré :
- Définir `minAvailable: 1` via un `PodDisruptionBudget` pour les services bancaires critiques.
- Augmenter les réplicas de production à `replicas: 2` minimum.
- Ajuster les seuils d'alertes préventives sur le pool HikariCP avant saturation de la mémoire.

---

## 8. Plan d'Actions Correctives et Préventives (Action Items)

| Réf | Action Corrective | Responsable | Priorité | Échéance | Statut |
|---|---|---|---|---|---|
| **ACT-01** | Passer `replicas: 2` et configurer le `PodDisruptionBudget` | P4 / P5 | P0 (Bloquant) | J+2 | En cours |
| **ACT-02** | Configurer l'HPA basé sur le CPU et la Heap JVM Actuator | P5 | P1 (Important) | J+5 | À faire |
| **ACT-03** | Raccourcir le scraping Prometheus à 10s pour `transaction-service` | P5 | P2 (Moyen) | J+7 | Validé |
| **ACT-04** | Documenter le runbook d'évacuation de nœud en GameDay | P5 | P2 (Moyen) | J+7 | Validé |

---

*Modèle certifié conforme aux standards SRE Google / OmniPay Zero-Trust ESTC (Semaine 3).*
