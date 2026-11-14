# OmniPay Zero-Trust — Dépôt GitOps (`omnipay-gitops`)

Ce dépôt constitue la **source unique de vérité** (Single Source of Truth) pour l'état désiré du cluster Kubernetes K3s, synchronisé en continu par **ArgoCD**.

---

## Architecture du dépôt

```text
omnipay-gitops/
├── envs/
│   ├── dev/            # Manifestes et configurations pour l'environnement Dev
│   ├── recette/        # Configuration pour l'environnement Recette (tests ZAP / k6)
│   └── prod/           # Configuration de Production (Argo Rollouts Canary)
└── platform/
    ├── argocd/         # Configuration des ApplicationSets ArgoCD
    ├── kyverno/        # Politiques d'admission (vérification Cosign)
    ├── vault/          # Injecteur et configuration HashiCorp Vault
    ├── falco/          # Règles de détection d'intrusion et Falcosidekick
    └── monitoring/     # kube-prometheus-stack, dashboards et alertes SLO
```

---

## Flux de mise à jour (Continuous Delivery)

1. Le pipeline Jenkins (`omnipay-app`) compile, teste, analyse et signe l'image avec **Cosign**.
2. L'image est poussée vers le registre privé **Harbor**.
3. Jenkins effectue un commit automatisé mettant à jour le tag d'image dans `envs/dev/values.yaml` (ou Kustomize).
4. **ArgoCD** détecte le commit et applique l'état sur K3s.
5. **Kyverno** vérifie la signature Cosign avant d'autoriser le déploiement du pod.
