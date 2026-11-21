# SonarQube Community 10.x — Analyse Statique & Gouvernance Qualité Zero-Trust

**Projet** : OmniPay Zero-Trust  
**Rôle** : P4 — Ingénieure Packaging, Registre Harbor, SonarQube & Supply Chain GitOps (Widad El Gharzaz)  
**Composants** : SonarQube Community 10.x, PostgreSQL 15, Ingress Traefik K3s  
**Namespace Kubernetes** : `sonarqube`  

---

## 1. Vue d'Ensemble & Rôle dans l'Architecture Zero-Trust

Dans l'architecture bancaire OmniPay Zero-Trust, **SonarQube** agit comme la première porte de contrôle qualité et sécurité logicielle (*Shift-Left Security*). Aucun microservice (`auth-service`, `transaction-service`, `notification-service`) ne peut être packagé en image de conteneur, signé cryptographiquement ou déployé via ArgoCD sans avoir préalablement satisfait les exigences absolues de la Quality Gate **OmniPay Zero-Trust**.

```
                  +----------------------------------------------+
                  |  Développeur / Commit Git                    |
                  +----------------------+-----------------------+
                                         |
                                         v
                  +----------------------------------------------+
                  |  Jenkins CI Pipeline (P1)                   |
                  |  - Maven Build & Unit Tests                  |
                  |  - JaCoCo Code Coverage Report               |
                  +----------------------+-----------------------+
                                         |
                                         v
                  +----------------------------------------------+
                  |  SonarQube Analysis & Quality Gate (P4)     |
                  |  - 0 Bug Bloquant (blocker_violations = 0)   |
                  |  - 0 Vulnérabilité (vulnerabilities = 0)     |
                  |  - Couverture de Code > 80%                  |
                  +----------------------+-----------------------+
                                         |
                       [ Quality Gate Passée ? ]
                               /         \
                         OUI  /           \  NON
                             v             v
       +-------------------------------+   +-----------------------------+
       | Publication Harbor & Cosign   |   | Build FAILED (Jenkins Stop) |
       | Promotion GitOps vers ArgoCD  |   | Pas de packaging conteneur  |
       +-------------------------------+   +-----------------------------+
```

---

## 2. Spécifications Techniques & Contraintes K3s

| Paramètre | Valeur | Description |
| :--- | :--- | :--- |
| **Version** | `SonarQube Community 10.7.0` | Image officielle OCI SonarSource |
| **Helm Chart** | `sonarqube/sonarqube` | Dépôt officiel `https://SonarSource.github.io/helm-chart-sonarqube` |
| **Base de Données** | PostgreSQL 15 (subchart) | Persistance dédiée sur stockage local |
| **StorageClass** | `local-path` | Provisionneur natif K3s |
| **Volumétrie PVC** | SonarQube : `10Gi` / BDD : `5Gi` | Données, extensions et base relationnelle |
| **Limites K3s Pod** | CPU : `1` core max, RAM : `2Gi` max | Respect strict des quotas de la machine K3s |
| **Requests Pod** | CPU : `500m`, RAM : `1Gi` | Allocation garantie pour le démarrage |
| **JVM Opts** | `-Xms512m -Xmx1536m -XX:+UseG1GC` | Dimensionnement de la mémoire heap Java |
| **NodePort HTTP** | `30003` | Exposition statique NodePort K3s |
| **Ingress DNS** | `sonarqube.omnipay.local` | Route Ingress Traefik (HTTP port 80) |

---

## 3. Déploiement et Initialisation

### Étape 1 : Déploiement via Helm

Exécutez le script d'installation automatisé :

```bash
bash platform/sonarqube/install-sonarqube.sh
```

Le script effectue les actions suivantes :
1. Ajoute et met à jour le dépôt Helm SonarSource.
2. Crée le namespace `sonarqube`.
3. Déploie le chart avec `values-sonarqube.yaml` en appliquant les limites K3s (`2Gi` RAM, `1` CPU).
4. Attend la disponibilité opérationnelle des pods.

### Étape 2 : Initialisation du Projet & de la Quality Gate

Une fois les pods prêts, initialisez la configuration Zero-Trust :

```bash
bash platform/sonarqube/init-sonarqube.sh
```

Ce script configure automatiquement :
- L'attente active du statut `UP` sur `/api/system/status`.
- La sécurisation du mot de passe `admin`.
- Le projet : `omnipay-banking-platform` ("OmniPay Banking Platform").
- La Quality Gate : **`OmniPay Zero-Trust`** avec les seuils obligatoires :
  * `blocker_violations` : 0 (GT:0)
  * `vulnerabilities` : 0 (GT:0)
  * `coverage` : > 80% (LT:80)
- L'association de cette Quality Gate au projet `omnipay-banking-platform`.
- Le webhook Jenkins : `http://jenkins.omnipay.local:8088/sonarqube-webhook/`.
- La génération d'un token d'analyse Jenkins injecté dans le secret Kubernetes `sonar-token-secret`.

---

## 4. Guide d'Accès & Identifiants

### Accès Web UI

| Méthode d'Accès | URL | Remarques |
| :--- | :--- | :--- |
| **NodePort Direct** | `http://sonarqube.omnipay.local:30003` | Accessible depuis l'hôte et les VM du cluster |
| **Ingress Traefik** | `http://sonarqube.omnipay.local` | Résolution DNS locale requise (`/etc/hosts`) |

Pour la résolution locale sur votre machine ou nœud K3s, ajoutez à `/etc/hosts` :
```text
127.0.0.1  sonarqube.omnipay.local harbor.omnipay.local argocd.omnipay.local jenkins.omnipay.local
```

### Identifiants d'Administration

- **Utilisateur** : `admin`
- **Mot de passe** : `SonarQubeAdminOmniPay2026!`
- **Token CI Jenkins** : généré par `init-sonarqube.sh` et stocké dans le Secret `sonar-token-secret` (namespaces `jenkins` et `sonarqube`).

---

## 5. Intégration Jenkins CI (Collaboration P1 & P4)

### Configuration Jenkins (JCasC / Credentials)

Dans Jenkins, le token SonarQube est enregistré sous l'identifiant :
- **Credential ID** : `sonar-auth-token` (Secret Text)

### Snippet d'Analyse Maven dans le Jenkinsfile

```groovy
stage('SonarQube Quality Gate Analysis') {
    steps {
        withSonarQubeEnv('SonarQube-OmniPay') {
            sh '''
                mvn -B clean verify sonar:sonar \
                  -Dsonar.projectKey=omnipay-banking-platform \
                  -Dsonar.projectName="OmniPay Banking Platform" \
                  -Dsonar.host.url=http://sonarqube.omnipay.local:30003 \
                  -Dsonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml
            '''
        }
        timeout(time: 5, unit: 'MINUTES') {
            script {
                def qg = waitForQualityGate()
                if (qg.status != 'OK') {
                    error "Échec Quality Gate SonarQube : statut ${qg.status}. Blocage de la chaîne de livraison !"
                }
            }
        }
    }
}
```

---

## 6. Commandes d'Exploitation & Troubleshooting

### Vérifier l'état des composants

```bash
# État des pods
kubectl get pods -n sonarqube -o wide

# Logs du serveur SonarQube
kubectl logs -n sonarqube -l app=sonarqube -c sonarqube -f

# État du stockage persistant (PVC)
kubectl get pvc -n sonarqube

# Vérification du service NodePort
kubectl get svc -n sonarqube sonarqube -o jsonpath='{.spec.ports}'
```

### Redémarrage ou purge du service

```bash
# Redémarrage propre
kubectl rollout restart deployment sonarqube -n sonarqube

# Désinstallation complète (en cas de réinitialisation)
helm uninstall sonarqube -n sonarqube
```
