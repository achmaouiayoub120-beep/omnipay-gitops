# Démonstration 2 — Barrière d'Admission Zero-Trust & Rejet d'Image Non Signée (Kyverno + Cosign)

**Projet** : OmniPay Zero-Trust  
**Rôle** : P4 — Ingénieur DevSecOps (Livraison & Chaîne d'Approvisionnement)  
**Composants démontrés** : Kyverno Admission Controller, Cosign (Sigstore), Harbor OCI Registry, Kubernetes K3s  
**Objectif pour le jury** : Démontrer le verrouillage cryptographique absolu de la chaîne d'approvisionnement logicielle. Tout conteneur qui ne possède pas une signature numérique valide émise par la clé privée d'OmniPay est intercepté et rejeté net à l'entrée du cluster Kubernetes, protégeant la banque contre toute injection d'image pirate, vulnérable ou non auditée.

---

## 1. Prérequis & Architecture de la Démo

- Cluster K3s avec Kyverno installé et actif (`platform/kyverno/install-kyverno.sh`).
- ClusterPolicy `verify-omnipay-image-signature` configurée en mode `validationFailureAction: Enforce`.
- Clé publique `cosign.pub` déployée dans la politique Kyverno.
- Clé privée `cosign.key` accessible pour la signature.

---

## 2. Déroulé Pas à Pas de la Démonstration (Commandes pour le Jury)

### Étape 0 : Vérifier l'état actif de la politique d'admission Kyverno

Affichez la politique d'admission déployée sur le cluster :

```bash
kubectl get clusterpolicy verify-omnipay-image-signature -o wide
```

*Sortie attendue :*
```text
NAME                             BACKGROUND   ACTION    READY   AGE   MESSAGE
verify-omnipay-image-signature   false        Enforce   true    10m   Ready
```

Vérifiez que la politique cible explicitement les namespaces protégés (`omnipay-prod` et `omnipay-recette`) et exige la clé publique d'OmniPay :

```bash
kubectl describe clusterpolicy verify-omnipay-image-signature | grep -E "Action|Namespaces|ImageReferences" -A 4
```

---

### Étape 1 : Tentative de déploiement d'une image NON SIGNÉE (Attaque / Anomalie)

Simulez la tentative d'un attaquant (ou d'un développeur distrait) déployant un conteneur non signé directement dans `omnipay-prod` :

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
*Sortie attendue :* `No resources found in omnipay-prod namespace.`

> **Explication pour le jury :**  
> L'API Server de Kubernetes a délégué la validation de la requête au Webhook de Kyverno avant même que le Pod ne soit persisté dans `etcd`. Constatant l'absence d'attestation cryptographique Cosign, Kyverno a bloqué la création avec un code HTTP 403 Forbidden.

---

### Étape 2 : Signature cryptographique de l'image avec Cosign (Pipeline CI)

Prenez le rôle du pipeline Jenkins sécurisé en signant l'image avec la clé privée de l'organisation :

```bash
export COSIGN_PASSWORD="OmniPayCosignKey2026!"

# Signature de l'image conteneur
cosign sign \
  --key platform/kyverno/keys/cosign.key \
  --yes \
  harbor.omnipay.local:30002/omnipay/trusted-service:1.0.0
```

*Sortie attendue :*
```text
Pushing signature to: harbor.omnipay.local:30002/omnipay/trusted-service
```

Vérifiez la signature localement avec la clé publique :

```bash
cosign verify \
  --key platform/kyverno/keys/cosign.pub \
  harbor.omnipay.local:30002/omnipay/trusted-service:1.0.0
```

*Sortie attendue :*
```text
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were successfully verified against the specified public key
[{"critical":{"identity":{"docker-reference":"harbor.omnipay.local:30002/omnipay/trusted-service"},"image":{"docker-manifest-digest":"sha256:..."},"type":"cosign container image signature"}}]
```

---

### Étape 3 : Déploiement de l'image SIGNÉE dans `omnipay-prod`

Déployez à présent la même image après signature cryptographique valide :

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
trusted-service   1/1     Running   0          8s
```

---

### Étape 4 : Inspection des événements d'admission Kyverno

Consultez les événements d'audit enregistrés par Kyverno pour prouver la traçabilité de l'intervention :

```bash
kubectl get events -n omnipay-prod --field-selector reason=PolicyViolation
```

*Sortie attendue :*
```text
LAST SEEN   TYPE      REASON            OBJECT            MESSAGE
1m          Warning   PolicyViolation   pod/rogue-...     Policy 'verify-omnipay-image-signature' failed: image failed signature verification
```

---

### Étape 5 : Nettoyage du pod de démonstration

```bash
kubectl delete pod trusted-service -n omnipay-prod --grace-period=0 --force
```

> **Synthèse finale pour le jury :**  
> Grâce à ce mécanisme, la chaîne d'approvisionnement logicielle d'OmniPay est hermétiquement close. Même si un tiers accédait directement aux commandes `kubectl` du cluster, il lui serait mathématiquement impossible d'exécuter du code conteneur non approuvé et signé par notre autorité interne.
