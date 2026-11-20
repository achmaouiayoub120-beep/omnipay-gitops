# Registre Privé OCI Harbor — Durcissement & Supply Chain Zero-Trust

**Projet** : OmniPay Zero-Trust  
**Rôle** : P4 — Ingénieure Packaging, Registre Harbor, SonarQube & Supply Chain GitOps (Widad El Gharzaz)  
**Composants** : Harbor v2.x, Scanner Trivy, Base PostgreSQL, Redis Cache, Storage local-path  
**Namespace Kubernetes** : `harbor`  
**URL d'Accès** : `http://harbor.omnipay.local:30002` (NodePort `30002`)  

---

## 1. Vue d'Ensemble & Rôle dans la Chaîne de Confiance

Dans l'architecture bancaire OmniPay Zero-Trust, **Harbor** constitue le registre d'artefacts central et souverain. Il héberge non seulement les images de conteneurs des microservices (`auth-service`, `transaction-service`, `notification-service`), mais également leurs métadonnées cryptographiques et attestations de sécurité conformes au standard **OCI 1.1** :
- **Attestations SBOM** générées par Syft (`application/vnd.cyclonedx+json` ou SPDX).
- **Signatures numériques** générées par Sigstore Cosign (`.sig`).

```
 +-------------------------------------------------------------------------------+
 |                        PIPELINE SÉCURISÉ HARBOR ZERO-TRUST                    |
 +-------------------------------------------------------------------------------+
 |                                                                               |
 | 1. Push Image (Jenkins P1)                                                    |
 |    └── docker push harbor.omnipay.local:30002/omnipay/transaction-service:tag |
 |                                                                               |
 | 2. Scan Automatique Trivy (Scan on Push)                                      |
 |    ├── Détection CVEs (Critical, High, Medium)                                |
 |    └── Si CVE CRITICAL >= 1 ──> BLOCAGE DU PULL (prevent_vul: true)           |
 |                                                                               |
 | 3. Immuabilité des Tags (Zero-Trust Tamper-Proof)                             |
 |    └── Règle d'immuabilité : Interdiction d'écraser un tag déjà publié         |
 |                                                                               |
 | 4. Attachement SBOM & Signature Cosign (P4)                                   |
 |    ├── cosign attach sbom ... (Accessory OCI)                                 |
 |    └── cosign sign ... (Accessory Signature OCI)                              |
 |                                                                               |
 +-------------------------------------------------------------------------------+
```

---

## 2. Piliers du Durcissement Zero-Trust (Hardening)

| Mécanisme de Sécurité | Configuration Harbor | Objectif de Protection |
| :--- | :--- | :--- |
| **Scan on Push Trivy** | `metadata.auto_scan: "true"` | Tout conteneur poussé est immédiatement scanné pour détecter les CVE connues. |
| **Blocage CVE Critiques** | `metadata.prevent_vul: "true"`<br>`metadata.severity: "critical"` | Empêche tout nœud Kubernetes ou pipeline de télécharger (`docker pull`) une image compromise. |
| **Immuabilité des Tags** | Règle `immutabletagrules` sur `**` | Évite toute attaque par empoisonnement d'image (*tag replacement / supply chain poisoning*). |
| **Robot CI avec Support OCI** | Compte `robot-omnipay-ci` avec ressource `accessory` | Autorise Jenkins à téléverser les signatures Cosign et fichiers SBOM sans droits administrateur globaux. |
| **Isolation Réseau & Stockage** | StorageClass `local-path` persistant | Garantit la souveraineté des données sur le cluster bancaire local K3s. |

---

## 3. Déploiement et Initialisation

### Étape 1 : Déploiement Helm de l'Infrastructure Harbor

```bash
bash platform/harbor/install-harbor.sh
```

Ce script :
1. Ajoute le dépôt officiel `https://helm.goharbor.io`.
2. Déploie Harbor dans le namespace `harbor` avec les valeurs `harbor-values.yaml`.
3. Configure le service HTTP sur le NodePort statique `30002`.
4. Évite tout conflit de port avec SonarQube (`30003`) ou ArgoCD (`30005`).

### Étape 2 : Initialisation du Projet Durci & Compte Robot CI

```bash
bash platform/harbor/init-harbor.sh
```

Ce script configure par API REST :
1. Le projet OCI durci `omnipay`.
2. L'activation du scan Trivy automatique et le blocage strict des CVE critiques.
3. La règle d'immuabilité interdisant toute modification ou suppression d'un tag d'image.
4. La création du compte robot CI `robot-omnipay-ci` doté des permissions requises sur les images et les accessoires OCI (`accessory`, `artifact`, `scan`).
5. La génération et l'injection automatique du secret Kubernetes `harbor-registry-secret` dans les namespaces :
   - `omnipay-dev`
   - `omnipay-recette`
   - `omnipay-prod`
   - `jenkins`
   - `argocd`

---

## 4. Guide d'Accès & Identifiants

### Interface Web (UI)

- **URL** : `http://harbor.omnipay.local:30002`
- **Administrateur** : `admin`
- **Mot de passe initial** : `HarborAdminOmniPay2026!`

### Authentification Docker CLI

```bash
# Connexion avec le compte Robot CI
docker login harbor.omnipay.local:30002 \
  -u 'robot$robot-omnipay-ci' \
  -p 'RobotSecretOmniPay2026!'
```

---

## 5. Intégration Pipeline CI/CD (P1 x P4)

### Publication, SBOM et Signature d'une Image Conteneur

```bash
REGISTRY="harbor.omnipay.local:30002"
IMAGE="${REGISTRY}/omnipay/transaction-service:1.0.0"

# 1. Build & Push de l'image
docker build -t "${IMAGE}" services/transaction
docker push "${IMAGE}"

# 2. Génération du SBOM SPDX et attachement OCI dans Harbor
syft "${IMAGE}" -o spdx-json="sbom-transaction.spdx.json"
cosign attach sbom --sbom "sbom-transaction.spdx.json" "${IMAGE}"

# 3. Signature cryptographique Cosign
export COSIGN_PASSWORD="OmniPayCosignKey2026!"
cosign sign --key platform/kyverno/keys/cosign.key --yes "${IMAGE}"

# 4. Vérification cryptographique
cosign verify --key platform/kyverno/keys/cosign.pub "${IMAGE}"
```

---

## 6. Commandes d'Exploitation & Supervision

```bash
# État des composants Harbor
kubectl get pods -n harbor -o wide

# Vérification du statut du scanner Trivy
kubectl get pods -n harbor -l component=trivy

# Vérification des PVC de persistance
kubectl get pvc -n harbor

# Consultation des secrets Docker injectés
kubectl get secrets -n omnipay-prod harbor-registry-secret
```
