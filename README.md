# OmniPay Zero-Trust — Dépôt GitOps (`omnipay-gitops`)

[![GitOps: ArgoCD](https://img.shields.io/badge/GitOps-ArgoCD%2030005-orange.svg)](https://argo-cd.readthedocs.io/)
[![Admission: Kyverno](https://img.shields.io/badge/Admission-Kyverno%20Enforce-blue.svg)](https://kyverno.io/)
[![Supply Chain: Cosign](https://img.shields.io/badge/Supply%20Chain-Cosign%20Signed-purple.svg)](https://sigstore.dev/)
[![Rollouts: Canary](https://img.shields.io/badge/Canary-Argo%20Rollouts-green.svg)](https://argoproj.github.io/argo-rollouts/)
[![Registry: Harbor](https://img.shields.io/badge/Registry-Harbor%2030002-blue.svg)](https://goharbor.io/)
[![SonarQube: 30003](https://img.shields.io/badge/Quality%20Gate-SonarQube%2030003-brightgreen.svg)](https://sonarqube.org/)
[![Monitoring: Prometheus](https://img.shields.io/badge/Monitoring-Prometheus%2030900-red.svg)](https://prometheus.io/)

Ce dépôt constitue la **source unique de vérité** (Single Source of Truth) pour l'état désiré du cluster Kubernetes K3s de la néobanque **OmniPay Zero-Trust**, synchronisé en continu par **ArgoCD**.

Porté par **Widad El Gharzaz (Rôle P4 : Packaging, Registre Harbor, Argo Rollouts & Kyverno)**, ce dépôt met en œuvre les principes fondamentaux de la sécurité **Zero-Trust** et de la résilience **SRE** :
- **Zéro secret dans Git** : Aucun mot de passe ni certificat sensible n'est versionné en clair.
- **Vérification d'authenticité cryptographique** : Admission stricte avec **Kyverno** bloquant impitoyablement toute image non signée par **Cosign** (Démo 2).
- **Durcissement au Runtime & Mutation** : Politiques Kyverno interdisant les volumes `hostPath`, le mode `privileged`, les capacités Linux critiques, et forçant `readOnlyRootFilesystem: true` ainsi que l'injection automatique des labels Zero-Trust et du `seccompProfile: RuntimeDefault`.
- **Résilience opérationnelle mesurée** : Déploiements progressifs **Canary (10% -> 33% -> 66% -> 100%)** avec **Argo Rollouts** et **rollback automatique en moins de 30 secondes** lors de la détection d'anomalies HTTP 5xx par **Prometheus** (Démo 1).
- **Traçabilité totale** : Tout changement d'état résulte d'un commit Git respectant les **Conventional Commits**.

---

## 1. Arborescence du Dépôt

```text
omnipay-gitops/
├── envs/
│   ├── dev/                                        # Environnement de Développement & CI
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── auth-service.yaml
│   │   ├── transaction-service.yaml
│   │   ├── notification-service.yaml
│   │   └── network-policies.yaml
│   ├── recette/                                    # Environnement de Qualification (Tests k6 & OWASP ZAP)
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── auth-service.yaml
│   │   ├── transaction-service.yaml
│   │   ├── notification-service.yaml
│   │   └── network-policies.yaml
│   └── prod/                                       # Environnement de Production Bancaire (Zero-Trust Strict)
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       ├── auth-service.yaml                       # Hardened (readOnlyRootFilesystem: true, drop: [ALL])
│       ├── transaction-service-rollout.yaml         # Rollout Canary 10% -> 33% -> 66% -> 100%
│       ├── transaction-service-analysis.yaml        # AnalysisTemplate interrogeant Prometheus
│       ├── transaction-service-services.yaml        # Services Active (stable) & Canary
│       ├── notification-service.yaml               # Hardened (readOnlyRootFilesystem: true, drop: [ALL])
│       └── network-policies.yaml
├── platform/
│   ├── argocd/                                     # Contrôleur GitOps ArgoCD (Port 30005)
│   │   ├── install-argocd.sh
│   │   ├── argocd-values.yaml
│   │   └── applicationsets/
│   │       └── applicationset-omnipay.yaml         # Générateur automatique des apps dev, recette, prod
│   ├── harbor/                                     # Registre d'images privé durci (Port 30002)
│   │   ├── install-harbor.sh
│   │   ├── harbor-values.yaml                      # Scanner Trivy & NodePort 30002
│   │   ├── init-harbor.sh                          # Projet 'omnipay', immuabilité & compte robot CI
│   │   └── README.md
│   ├── sonarqube/                                  # Plateforme d'analyse de code (Port 30003)
│   │   ├── install-sonarqube.sh
│   │   ├── values-sonarqube.yaml                   # NodePort 30003 & limites K3s
│   │   ├── init-sonarqube.sh                       # Quality Gate Zero-Trust & Webhook
│   │   └── README.md
│   ├── kyverno/                                    # Admission Controller Zero-Trust & Runtime Hardening
│   │   ├── install-kyverno.sh
│   │   ├── keys/
│   │   │   ├── cosign.pub                          # Clé publique pour validation signature
│   │   │   └── generate-keys.sh                    # Script de rotation de clés
│   │   └── policies/
│   │       ├── disallow-unsigned-images.yaml       # Signature Cosign obligatoire (Enforce)
│   │       ├── require-non-root.yaml               # Exécution non-root (Enforce)
│   │       ├── mutate-inject-zero-trust-labels.yaml# Mutation : Labels Zero-Trust & Seccomp
│   │       ├── disallow-host-path-and-privileged.yaml # Interdiction hostPath, privileged & caps
│   │       └── require-ro-rootfs-and-drop-all.yaml # ReadOnlyRootFilesystem & Drop ALL
│   ├── monitoring/                                 # Stack Prometheus, Grafana, Loki (P5/P4)
│   │   ├── servicemonitor-omnipay.yaml
│   │   ├── values-prometheus.yaml
│   │   ├── rules/slo-alerts.yaml
│   │   └── dashboards/
│   └── rollouts/                                   # Contrôleur Argo Rollouts (Port 3100)
│       ├── install-rollouts.sh
│       └── analysis-templates/
│           └── prometheus-error-rate.yaml          # Template métrique 5xx global
├── scripts/
│   ├── setup-supply-chain.sh                       # Bootstrap complet bash de la plateforme P4
│   ├── setup-supply-chain.ps1                      # Bootstrap complet PowerShell Windows P4
│   ├── run-demo-canary.sh                          # Démo 1 Jury : Rollback automatique Canary (< 30s)
│   ├── run-demo-canary.ps1                         # Démo 1 Jury : Version PowerShell Windows
│   ├── test-admission-gate.sh                      # Démo 2 Jury : Rejet images non signées Cosign
│   ├── test-kyverno-runtime-policies.sh            # Validation des politiques Kyverno Runtime (bash)
│   ├── test-kyverno-runtime-policies.ps1           # Validation des politiques Kyverno Runtime (PS)
│   ├── verify-argocd-sync.sh                       # Tableau de réconciliation GitOps multi-environnements
│   ├── ci-supply-chain-pipeline.sh                 # Pipeline standalone build, SBOM & signature
│   └── jenkinsfile-supply-chain-stage.groovy       # Snippet d'intégration CI Jenkinsfile (P1)
├── demos/
│   ├── demo-1-canary-rollback.md                   # Guide pas à pas jury : Canary + auto-rollback < 30s
│   ├── demo-2-kyverno-signature-gate.md            # Guide pas à pas jury : Rejet d'image non signée
│   ├── demo-3-devsecops-pipeline.md                # Guide pas à pas jury : Pipeline CI/CD DevSecOps
│   └── demo-5-gameday-slo.md                       # Guide pas à pas jury : GameDay & résilience SLO
└── docs/
    └── adr/                                        # Registre des Décisions d'Architecture
        ├── README.md
        ├── ADR-002.md                              # Registre privé Harbor avec scan Trivy
        ├── ADR-004.md                              # Modèle GitOps ArgoCD & ApplicationSet
        ├── ADR-005.md                              # Chaîne supply chain : SBOM Syft, Cosign & Kyverno
        ├── ADR-007.md                              # Stratégie Canary initiale Argo Rollouts
        └── ADR-012.md                              # Déploiement progressif Canary & auto-rollback < 30s
```

---

## 2. Cartographie des Ports K3s (Garantie Zéro Conflit)

L'architecture réseau du cluster K3s respecte un plan d'adressage strict sans aucun conflit de ports :

| Service | Port NodePort / Dashboard | URL d'accès | Protocole / Rôle | Identifiants par défaut |
|---|---|---|---|---|
| **Harbor Registry** | **30002** | `http://harbor.omnipay.local:30002` | HTTP / OCI Registry & Scanner Trivy | `admin` / `HarborAdminOmniPay2026!` |
| **SonarQube Community** | **30003** | `http://sonarqube.omnipay.local:30003` | HTTP / Quality Gate Zero-Trust | `admin` / `admin` (puis rotation) |
| **ArgoCD UI** | **30005** | `http://argocd.omnipay.local:30005` | HTTPS / Contrôleur GitOps | `admin` / (secret `argocd-initial-admin-secret`) |
| **Vault UI** | **30006** | `http://vault.omnipay.local:30006` | HTTP / Gestionnaire de Secrets (P2) | Token Root / Unseal Keys |
| **Grafana Dashboards** | **30300** | `http://grafana.omnipay.local:30300` | HTTP / Tableaux de bord SRE & SLO | `admin` / `prom-operator` |
| **Prometheus Server** | **30900** (et interne `:9090`) | `http://prometheus.omnipay.local:30900` | HTTP / Métriques & PromQL | N/A |
| **Argo Rollouts Dashboard** | **3100** | `http://localhost:3100` | HTTP / Visualisation Canary en direct | Accessible via `kubectl argo rollouts dashboard` |
| **Kyverno Webhook** | Interne K3s | `https://kyverno-svc.kyverno.svc:443` | HTTPS / Admission Webhook bloquant | Certificats mTLS gérés par Kyverno |

---

## 3. Déploiement et Initialisation Rapide

Pour bootstraper l'intégralité de la chaîne de livraison, de packaging et de sécurité :

### Sous Linux / WSL / CI :
```bash
chmod +x scripts/*.sh platform/*/*.sh platform/*/*/*.sh
./scripts/setup-supply-chain.sh
```

### Sous Windows (PowerShell 7+) :
```powershell
.\scripts\setup-supply-chain.ps1
```

---

## 4. Guides de Démonstration pour la Soutenance (Jury)

### Démo 1 — Déploiement Progressif Canary & Auto-Rollback en < 30s (Argo Rollouts)
- **Objectif** : Prouver la mitigation autonome des régressions critiques sans intervention humaine.
- **Fichier guide** : [demos/demo-1-canary-rollback.md](demos/demo-1-canary-rollback.md)
- **Script d'automatisation clé en main** :
  - Linux/CI : `./scripts/run-demo-canary.sh`
  - Windows PowerShell : `.\scripts\run-demo-canary.ps1`
- **Mécanisme** :
  1. Injection d'une version régressée `v2-bad` générant des erreurs HTTP 500.
  2. Palier 1 Canary : 1 pod déployé (Blast Radius limité à 10%).
  3. L'`AnalysisTemplate` `prometheus-error-rate` détecte le pic d'erreurs (seuil critique `result[0] < 0.5`).
  4. Argo Rollouts passe le Rollout en `Degraded` et réduit immédiatement les pods Canary à 0 réplica.
  5. 100% du trafic reste desservi par la version stable 1.0.0. Rollback accompli en moins de 30 secondes !

### Démo 2 — Barrière d'Admission Kyverno & Rejet d'Image Non Signée Cosign
- **Objectif** : Prouver qu'aucune image conteneur non approuvée cryptographiquement ne peut pénétrer en production.
- **Fichier guide** : [demos/demo-2-kyverno-signature-gate.md](demos/demo-2-kyverno-signature-gate.md)
- **Script de test** : `./scripts/test-admission-gate.sh`
- **Mécanisme** :
  1. Tentative d'instanciation d'un conteneur avec une image non signée (`untrusted-service`).
  2. Rejet immédiat par le webhook d'admission Kyverno avec code `403 Forbidden` (`failed signature verification`).
  3. Déploiement d'une image signée avec la clé privée de la CI : admission instantanée et démarrage du conteneur.

### Démo Complémentaire — Politiques Kyverno de Hardening Runtime & Mutation
- **Objectif** : Prouver la protection en profondeur au runtime (interdiction de volumes `hostPath`, du mode `privileged`, des capacités noyau, et injection automatique de labels).
- **Scripts de validation** :
  - Linux/CI : `./scripts/test-kyverno-runtime-policies.sh`
  - Windows PowerShell : `.\scripts\test-kyverno-runtime-policies.ps1`

---

## 5. Décisions d'Architecture (ADR)

Les orientations structurantes prises pour l'architecture GitOps et la chaîne de confiance logicielle sont documentées dans le registre ADR :

- [**ADR-002**](docs/adr/ADR-002.md) : Choix du registre d'images privé sécurisé Harbor avec analyse Trivy on-push.
- [**ADR-004**](docs/adr/ADR-004.md) : Choix du modèle de déploiement continu GitOps avec ArgoCD & ApplicationSet multi-environnements.
- [**ADR-005**](docs/adr/ADR-005.md) : Sécurisation de la supply chain logicielle : SBOM Syft, signatures Cosign et admission Kyverno.
- [**ADR-007**](docs/adr/ADR-007.md) : Stratégie initiale de déploiement progressif Canary avec Argo Rollouts.
- [**ADR-012**](docs/adr/ADR-012.md) : Stratégie de déploiement progressif Canary (Argo Rollouts) et mitigation automatisée des pannes en production (paliers 10%-33%-66%-100%, Prometheus continuous analysis, auto-rollback < 30s, blast radius max 10%).
