# Démonstration 2 — Barrière d'Admission Zero-Trust & Rejet d'Image Non Signée (Kyverno + Cosign)

**Projet** : OmniPay Zero-Trust  
**Rôle** : P4 — Ingénieure Packaging, Registre Harbor, SonarQube & Supply Chain GitOps (Widad El Gharzaz)  
**Composants démontrés** : Kyverno Admission Controller, Sigstore Cosign, Registre OCI Harbor, Kubernetes K3s  
**Objectif pour le jury** : Démontrer le verrouillage cryptographique absolu de la chaîne d'approvisionnement logicielle (*Supply Chain Security*). Tout conteneur qui ne possède pas une signature numérique valide émise par l'autorité CI d'OmniPay est intercepté et rejeté sans concession à l'entrée du cluster Kubernetes, protégeant la banque contre toute injection d'image pirate, vulnérable ou non certifiée.

---

## 1. Architecture de Sécurité & Chaîne de Confiance

Dans le paradigme Zero-Trust bancaire d'OmniPay, le cluster Kubernetes ne fait jamais confiance par défaut aux images conteneurs, même si elles proviennent d'un registre interne.

```
+----------------------------------------------------------------------------------------------------+
|                                    CHAÎNE D'APPROVISIONNEMENT SÉCURISÉE                            |
+----------------------------------------------------------------------------------------------------+
|                                                                                                    |
|  1. Pipeline Jenkins (P1)                                                                          |
|     └── Build Docker Microservice -> Génération SBOM Syft -> Scan Trivy                            |
|                                                                                                    |
|  2. Signature Cryptographique Cosign (P4)                                                          |
|     └── Signature de l'image avec cosign.key protégée -> Push signature OCI vers Harbor (30002)   |
|                                                                                                    |
|  3. Déploiement GitOps ArgoCD (P4)                                                                 |
|     └── ApplicationSet -> Envoi du manifeste Pod vers l'API Server K3s                             |
|                                                                                                    |
|  4. Contrôle d'Admission Kyverno (P4)                                                              |
|     ├── Requête d'Admission Webhook interceptée AVANT écriture dans etcd                           |
|     ├── Vérification de la signature avec cosign.pub                                               |
|     │    ├── Signature absente ou invalide ──> REJET HTTP 403 (Pod non créé)                      |
|     │    └── Signature valide et conforme ────> ADMISSION VALIDÉE (Pod exécuté)                    |
|                                                                                                    |
+----------------------------------------------------------------------------------------------------+
```

---

## 2. Déroulé Pas à Pas de la Démonstration (Commandes & Sorties Attendues)

### Option Rapide : Exécution du Script Automatisé

Pour une démonstration complète en une seule commande :

```bash
bash scripts/test-admission-gate.sh omnipay-prod
```

---

### Option Détaillée : Déroulé Étape par Étape pour le Jury

#### Étape 0 : Vérifier l'état actif de la politique d'admission Kyverno

Affichez la politique d'admission déployée sur le cluster :

```bash
kubectl get clusterpolicy verify-omnipay-image-signature -o wide
```

*Sortie console attendue :*
```text
NAME                             BACKGROUND   ACTION    READY   AGE   MESSAGE
verify-omnipay-image-signature   false        Enforce   true    15m   Ready
```

Vérifiez que la politique cible explicitement les namespaces protégés (`omnipay-prod` et `omnipay-recette`) et applique la règle `Enforce` :

```bash
kubectl get clusterpolicy verify-omnipay-image-signature -o jsonpath='{.spec.validationFailureAction}'
```

*Sortie console attendue :*
```text
Enforce
```

---

#### Étape 1 : Tentative d'injection d'une image NON SIGNÉE (Simulation d'Attaque)

Simulez la tentative d'un attaquant (ou d'un déploiement non certifié) injectant un conteneur non signé directement dans le namespace de production `omnipay-prod` :

```bash
kubectl run rogue-container \
  --image=harbor.omnipay.local:30002/omnipay/untrusted-service:latest \
  --restart=Never \
  -n omnipay-prod
```

*Sortie console immédiate (Rejet par Admission Webhook) :*
```text
Error from server (Forbidden): admission webhook "validate.kyverno.svc" denied the request: 

policy ClusterPolicy/verify-omnipay-image-signature:
  verify-cosign-signature:
    image harbor.omnipay.local:30002/omnipay/untrusted-service:latest failed signature verification:
    no matching signatures found for public key
```

Vérifiez qu'aucun pod n'a été créé sur le cluster :

```bash
kubectl get pods -l run=rogue-container -n omnipay-prod
```

*Sortie attendue :*
```text
No resources found in omnipay-prod namespace.
```

> **Message clé pour le jury :**  
> L'API Server Kubernetes a délégué la validation de la requête au Webhook de Kyverno avant même que le Pod ne soit persisté dans `etcd`. Constatant l'absence d'attestation cryptographique Cosign, Kyverno a bloqué la création avec une erreur HTTP 403 Forbidden. Aucune image non auditée ne peut tourner en production ou recette.

---

#### Étape 2 : Signature cryptographique de l'image avec Cosign (Pipeline CI)

Prenez le rôle du pipeline Jenkins sécurisé en signant l'image avec la clé privée de l'organisation :

```bash
export COSIGN_PASSWORD="OmniPayCosignKey2026!"

# Signature de l'image conteneur
cosign sign \
  --key platform/kyverno/keys/cosign.key \
  --yes \
  harbor.omnipay.local:30002/omnipay/trusted-service:1.0.0
```

*Sortie console attendue :*
```text
Generating ephemeral cert...
Pushing signature to: harbor.omnipay.local:30002/omnipay/trusted-service
```

Vérifiez la signature localement avec la clé publique déployée sur Kyverno :

```bash
cosign verify \
  --key platform/kyverno/keys/cosign.pub \
  harbor.omnipay.local:30002/omnipay/trusted-service:1.0.0
```

*Sortie console attendue :*
```text
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were successfully verified against the specified public key
[{"critical":{"identity":{"docker-reference":"harbor.omnipay.local:30002/omnipay/trusted-service"},"image":{"docker-manifest-digest":"sha256:d8c5..."},"type":"cosign container image signature"}}]
```

---

#### Étape 3 : Déploiement de l'image SIGNÉE dans `omnipay-prod`

Déployez à présent le conteneur signé avec la clé cryptographique valide :

```bash
kubectl run trusted-service \
  --image=harbor.omnipay.local:30002/omnipay/trusted-service:1.0.0 \
  --restart=Never \
  -n omnipay-prod
```

*Sortie console immédiate :*
```text
pod/trusted-service created
```

Vérifiez le statut du pod :

```bash
kubectl get pod trusted-service -n omnipay-prod
```

*Sortie attendue :*
```text
NAME              READY   STATUS    RESTARTS   AGE
trusted-service   1/1     Running   0          5s
```

---

#### Étape 4 : Inspection des événements d'audit Kyverno (Traçabilité & Compliance)

Consultez les événements d'audit enregistrés par Kyverno pour prouver la traçabilité de la tentative de violation :

```bash
kubectl get events -n omnipay-prod --field-selector reason=PolicyViolation
```

*Sortie attendue :*
```text
LAST SEEN   TYPE      REASON            OBJECT                MESSAGE
2m          Warning   PolicyViolation   pod/rogue-container   Policy 'verify-omnipay-image-signature' failed: image failed signature verification
```

---

#### Étape 5 : Nettoyage des ressources de test

Nettoyez le pod de test pour restaurer l'environnement :

```bash
kubectl delete pod trusted-service -n omnipay-prod --grace-period=0 --force
```

*Sortie attendue :*
```text
pod "trusted-service" force deleted
```

---

## 3. Synthèse des Résultats pour l'Évaluation du Jury

| Scénario Testé | Action Réalisée | Résultat Kyverno | Statut Sécurité |
| :--- | :--- | :--- | :--- |
| **Image Non Signée** | `kubectl run rogue-container` | **HTTP 403 Rejet immédiat** | **CONFIRMÉ (Bloqué)** |
| **Image Altérée / Mauvaise Clé** | Signature tierce non reconnue | **HTTP 403 Rejet immédiat** | **CONFIRMÉ (Bloqué)** |
| **Image Signée OmniPay** | Signature Cosign valide | **HTTP 201 Pod créé** | **CONFIRMÉ (Admis)** |
| **Périmètre d'Application** | `omnipay-recette` & `omnipay-prod` | Protection active Enforce | **CONFIRMÉ** |

> **Conclusion P4 :**  
> Grâce à la combinaison de Harbor durci, Cosign et Kyverno, la chaîne d'approvisionnement logicielle d'OmniPay est étanche. Aucune menace issue d'une image non certifiée ne peut pénétrer l'écosystème bancaire de production.
