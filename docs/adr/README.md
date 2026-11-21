# Registre des Décisions d'Architecture (ADR) — OmniPay GitOps

Ce registre recense les décisions d'architecture prises pour le dépôt GitOps et l'infrastructure de livraison continue et de sécurité de la plateforme **OmniPay Zero-Trust**.

---

## Registre des décisions portées par le Rôle P4 (Livraison & Supply Chain)

| Numéro | Titre de la décision | Porteur | Statut | Environnements impactés |
|---|---|---|---|---|
| [**ADR-002**](ADR-002.md) | Choix du registre d'images privé sécurisé Harbor avec analyse Trivy | P4 | **Accepté** | Plateforme, CI (Jenkins), K3s |
| [**ADR-004**](ADR-004.md) | Choix du modèle de déploiement continu GitOps avec ArgoCD & ApplicationSet | P4 | **Accepté** | `omnipay-dev`, `omnipay-recette`, `omnipay-prod` |
| [**ADR-005**](ADR-005.md) | Sécurisation de la supply chain logicielle : SBOM Syft, Cosign & Kyverno | P4 | **Accepté** | `omnipay-recette`, `omnipay-prod` |
| [**ADR-007**](ADR-007.md) | Stratégie de déploiement progressif Canary avec Argo Rollouts | P4 | **Accepté** | `omnipay-prod` (transaction-service) |
