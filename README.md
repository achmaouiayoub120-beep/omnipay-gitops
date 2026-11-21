# OmniPay Zero-Trust — Dépôt GitOps (`omnipay-gitops`)

[![GitOps: ArgoCD](https://img.shields.io/badge/GitOps-ArgoCD-orange.svg)](https://argo-cd.readthedocs.io/)
[![Admission: Kyverno](https://img.shields.io/badge/Admission-Kyverno-blue.svg)](https://kyverno.io/)
[![Supply Chain: Cosign](https://img.shields.io/badge/Supply%20Chain-Cosign-purple.svg)](https://sigstore.dev/)
[![Rollouts: Canary](https://img.shields.io/badge/Canary-Argo%20Rollouts-green.svg)](https://argoproj.github.io/argo-rollouts/)
[![Registry: Harbor](https://img.shields.io/badge/Registry-Harbor%2030002-blue.svg)](https://goharbor.io/)

Ce dépôt constitue la **source unique de vérité** (Single Source of Truth) pour l'état désiré du cluster Kubernetes K3s de la néobanque **OmniPay Zero-Trust**, synchronisé en continu par **ArgoCD**.

Porté par le **Rôle P4 (Livraison & Chaîne d'Approvisionnement)**, ce dépôt met en œuvre les principes fondamentaux du modèle **Zero-Trust** :
- **Zéro secret dans Git** : Aucun mot de passe ni certificat sensible n'est versionné en clair.
- **Vérification d'authenticité cryptographique** : Admission stricte avec **Kyverno** validant les signatures **Cosign** des images.
- **Traçabilité totale** : Tout changement d'état résulte d'un commit Git respectant les **Conventional Commits**.
- **Résilience opérationnelle mesurée** : Déploiements progressifs **Canary (10% -> 50% -> 100%)** avec **Argo Rollouts** et rollback automatique en cas de régression du taux d'erreur 5xx (Prometheus).

---

## 1. Arborescence du Dépôt

```text
omnipay-gitops/
├── envs/
│   ├── dev/                                  # Environnement de Développement & CI
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── auth-service.yaml
│   │   ├── transaction-service.yaml
│   │   ├── notification-service.yaml
│   │   └── network-policies.yaml
│   ├── recette/                              # Environnement de Qualification (Tests k6 & OWASP ZAP)
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── auth-service.yaml
│   │   ├── transaction-service.yaml
│   │   ├── notification-service.yaml
│   │   └── network-policies.yaml
│   └── prod/                                 # Environnement de Production Bancaire (Zero-Trust Strict)
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       ├── auth-service.yaml
│       ├── transaction-service-rollout.yaml   # Rollout Canary 10% -> 50% -> 100%
│       ├── transaction-service-analysis.yaml  # AnalysisTemplate interrogeant Prometheus
│       ├── transaction-service-services.yaml  # Services Active & Preview
│       ├── notification-service.yaml
│       └── network-policies.yaml
├── platform/
│   ├── argocd/                               # Contrôleur GitOps ArgoCD
│   │   ├── install-argocd.sh
│   │   ├── argocd-values.yaml
│   │   └── applicationsets/
│   │       └── applicationset-omnipay.yaml   # Générateur automatique des apps dev, recette, prod
│   ├── harbor/                               # Registre d'images privé (Port 30002)
│   │   ├── install-harbor.sh
│   │   ├── harbor-values.yaml                # Scanner Trivy & NodePort 30002
│   │   └── init-harbor.sh                    # Création du projet 'omnipay' et du robot CI
│   ├── kyverno/                              # Admission Controller Zero-Trust
│   │   ├── install-kyverno.sh
│   │   ├── keys/
│   │   │   ├── cosign.pub                    # Clé publique pour validation admission
│   │   │   └── generate-keys.sh              # Script de génération / rotation de clés
│   │   └── policies/
│   │       ├── disallow-unsigned-images.yaml # ClusterPolicy bloquante (Enforce)
│   │       └── require-non-root.yaml         # Restriction d'exécution non-root
│   └── rollouts/                             # Déploiements progressifs Canary
│       ├── install-rollouts.sh
│       └── analysis-templates/
│           └── prometheus-error-rate.yaml    # Métrique d'erreur HTTP 5xx
├── scripts/
│   ├── setup-supply-chain.sh                 # Bootstrap complet automatisé de la plateforme P4
│   ├── ci-supply-chain-pipeline.sh           # Script standalone de build, Syft SBOM & Cosign
│   └── jenkinsfile-supply-chain-stage.groovy # Snippet clé en main pour Jenkinsfile (P1)
├── demos/
│   ├── demo-1-canary-rollback.md             # Guide pas à pas jury : Canary + auto-rollback
│   └── demo-2-kyverno-signature-gate.md      # Guide pas à pas jury : Rejet d'image non signée
└── docs/
    └── adr/                                  # Registre des Décisions d'Architecture
        ├── README.md
        ├── ADR-002.md                        # Choix du registre Harbor avec Trivy
        ├── ADR-004.md                        # Choix du modèle GitOps avec ArgoCD
        ├── ADR-005.md                        # Chaîne supply chain : Syft, Cosign & Kyverno
        └── ADR-007.md                        # Stratégie Canary avec Argo Rollouts
```

---

## 2. Déploiement Rapide de la Plateforme

Pour déployer l'intégralité de la chaîne de livraison et de sécurité en une seule commande :

```bash
# Rendre les scripts exécutables
chmod +x scripts/*.sh platform/*/*.sh platform/*/*/*.sh

# Exécuter le bootstrap complet
./scripts/setup-supply-chain.sh
```

### URLs et Accès Internes

| Service | URL / Point d'accès | Identifiants par défaut | Rôle |
|---|---|---|---|
| **Harbor Registry** | `http://harbor.omnipay.local:30002` | `admin` / `HarborAdminOmniPay2026!` | Registre privé OCI & Trivy |
| **ArgoCD GitOps** | `http://argocd.omnipay.local:30005` | `admin` / (initial-admin-secret) | Contrôleur de synchronisation GitOps |
| **Prometheus** | `http://monitoring-kube-prometheus-prometheus.monitoring.svc:9090` | N/A | Scraping métriques & SLO |
| **Kyverno Webhook** | Interne K3s (`validate.kyverno.svc`) | Certificats mTLS K8s | Admission Control bloquant |

---

## 3. Chaîne Supply-Chain & Intégration CI (Jenkins P1)

Le flux continu de livraison s'articule comme suit :
1. **Compilation & Scan statique** : Jenkins compile les microservices et effectue les contrôles de qualité.
2. **Génération de SBOM (Syft)** : Syft extrait la nomenclature complète des dépendances au format SPDX (`syft <image> -o spdx-json`).
3. **Publication dans Harbor** : L'image est poussée sur le registre privé via le compte robot `robot$robot-omnipay-ci`.
4. **Signature cryptographique (Cosign)** : L'image et son SBOM sont signés avec la clé privée protégée (`cosign sign`).
5. **Promotion GitOps** : Jenkins committe le nouveau tag d'image dans `envs/dev/kustomization.yaml` avec un Conventional Commit (`chore(release): bump transaction-service to <sha>`).
6. **Réconciliation ArgoCD** : ArgoCD détecte le commit, valide l'état désiré et déclenche la création du pod sur K3s.
7. **Filtrage Kyverno** : Le webhook de Kyverno intercepte la demande, valide mathématiquement la signature Cosign avec `cosign.pub`, et autorise le démarrage du conteneur.

---

## 4. Guides de Démonstration pour la Soutenance (Jury)

- **[Démonstration 1 — Canary & Rollback Automatique](demos/demo-1-canary-rollback.md)** : Déploiement d'une version régressée `v2-bad`, détection du pic d'erreurs 5xx par Prometheus, échec de l'AnalysisTemplate et retour arrière instantané sur la version stable 1.0.0.
- **[Démonstration 2 — Barrière Kyverno & Rejet d'Image Non Signée](demos/demo-2-kyverno-signature-gate.md)** : Tentative de déploiement d'un conteneur non approuvé, blocage 403 Forbidden par Kyverno, signature avec Cosign et acceptation du pod.

---

## 5. Décisions d'Architecture (ADR)

Les choix techniques ont été formalisés selon les standards stricts de l'Architecture Decision Record :
- **[ADR-002](docs/adr/ADR-002.md)** : Choix du registre d'images privé sécurisé Harbor avec analyse Trivy.
- **[ADR-004](docs/adr/ADR-004.md)** : Choix du modèle de déploiement continu GitOps avec ArgoCD & ApplicationSet.
- **[ADR-005](docs/adr/ADR-005.md)** : Sécurisation de la supply chain logicielle : SBOM Syft, Cosign & Kyverno.
- **[ADR-007](docs/adr/ADR-007.md)** : Stratégie de déploiement progressif Canary avec Argo Rollouts.
