# Démonstration 3 — Pipeline DevSecOps & Chaîne d'Approvisionnement Logicielle de Bout en Bout
## OmniPay Zero-Trust | Rôle P1 — Chef Technique & Lead CI/CD DevSecOps (Semaine 3)

---

### 🎯 Objectif pour le Jury (Durée : 10 à 15 minutes)
Démontrer que la chaîne d'intégration et de livraison continue (CI/CD) d'OmniPay applique une **doctrine Zero-Trust absolue** :
> *"Aucun artefact non testé, vulnérable ou non signé cryptographiquement ne peut franchir les portes de sécurité pour atteindre le cluster K3s."*

Cette démonstration prouve en direct les 3 piliers :
1. **Shift-Left Security** : Arrêt immédiat dès le premier commit en cas de fuite d'identifiants (Gitleaks).
2. **Quality Gates & Supply Chain** : Bloquage automatique si la couverture de tests < 80%, si une CVE critique est présente, ou si l'image n'est pas signée.
3. **Promotion GitOps Contrôlée** : Traçabilité complète du déploiement de `dev` ➔ `recette` (avec audit dynamique DAST OWASP ZAP) ➔ `prod` (via Argo Rollouts Canary).

---

## 🏗️ Architecture du Pipeline DevSecOps v3

```
                                  VUE D'ENSEMBLE DU PIPELINE
 ┌───────────────┐     ┌───────────────┐     ┌───────────────┐     ┌───────────────┐
 │  1. Checkout  │────▶│ 2. Gitleaks   │────▶│ 3. Hadolint   │────▶│  4. Maven     │
 │  & Metadata   │     │ (Shift-Left)  │     │ (Docker Lint) │     │  (JaCoCo >80%)│
 └───────────────┘     └───────────────┘     └───────────────┘     └───────┬───────┘
                                                                           │
 ┌───────────────┐     ┌───────────────┐     ┌───────────────┐             ▼
 │ 7. Trivy Scan │◀────│ 6. SCA OWASP  │◀────│ 5. SonarQube  │◀────────────┘
 │ (0 Crit/High) │     │ (Dep-Check)   │     │ Quality Gate  │
 └───────┬───────┘     └───────────────┘     └───────────────┘
         │
         ▼
 ┌───────────────┐     ┌───────────────┐     ┌───────────────┐     ┌───────────────┐
 │ 8. Syft SBOM  │────▶│ 9. Deploy Dev │────▶│ 10. Recette   │────▶│ 11. Gate Prod │
 │ + Cosign Sign │     │ + Smoke Tests │     │ + DAST ZAP    │     │ (Rollouts)    │
 └───────────────┘     └───────────────┘     └───────────────┘     └───────────────┘
```

---

## 🎬 Déroulé Pas à Pas de la Démonstration devant le Jury

---

### SCÉNARIO 1 : Arrêt Immédiat sur Fuite de Secret (Shift-Left Gitleaks)
*Temps : 2 minutes*  
*But : Démontrer l'interdiction formelle de commiter des secrets dans le code source.*

1. **Injection d'un secret bancaire simulé dans une branche de test :**
   ```bash
   git checkout -b test/leak-prevention
   echo 'AWS_SECRET_ACCESS_KEY="AKIAIOSFODNN7EXAMPLE123456789"' >> services/auth/src/main/resources/application.yml
   git commit -am "test: ajout accidentel d'un secret"
   git push origin test/leak-prevention
   ```

2. **Observation sur Jenkins (Console / Blue Ocean) :**
   - Le pipeline démarre.
   - **Étape 2 (Secret Scan Gitleaks)** passe immédiatement au **ROUGE** en < 4 secondes.
   - Sortie console Jenkins :
     ```text
     [GITLEAKS] Scan des secrets en cours sur omnipay-app...
     ERR: Leve une regle aws-secret-access-key sur services/auth/src/main/resources/application.yml
     [ERREUR ZERO-TRUST] 1 secret(s) detecte(s) ! Le build est avorte immediatement.
     Process exited with code 1.
     ```
   - **Conclusion Jury** : Le build est interrompu avant toute compilation, protégeant ainsi l'infrastructure.

3. **Nettoyage :**
   ```bash
   git checkout develop
   git branch -D test/leak-prevention
   ```

---

### SCÉNARIO 2 : Blocage par Quality Gate SonarQube & Trivy
*Temps : 3 minutes*  
*But : Démontrer qu'un code sans tests unitaires suffisants ou une image avec CVE critique est rejeté.*

1. **Démonstration de la règle de gouvernance :**
   - Ouvrir la console SonarQube : `http://sonarqube.omnipay.local:30003`
   - Montrer la **Quality Gate "OmniPay Zero-Trust"** configurée par P4 :
     * *Coverage on New Code* : **> 80.0%**
     * *Vulnerabilities* : **0**
     * *Security Hotspots Reviewed* : **100%**
     * *Bugs Bloquants* : **0**
2. **Si un développeur retire les tests ou régresse la couverture :**
   - Le stage 5b `waitForQualityGate abortPipeline: true` lève une exception Jenkins :
     ```text
     [SONARQUBE] Quality Gate status: ERROR
     [ERREUR] Condition échouée : Line Coverage (74.2% < 80.0%)
     Pipeline aborted by Quality Gate.
     ```
   - Aucune image Docker n'est construite, aucun artefact n'est poussé sur Harbor.

---

### SCÉNARIO 3 : Le Flux Nominal & Supply Chain Cryptographique
*Temps : 8 minutes*  
*But : Présenter le cycle de vie complet d'un commit sain jusqu'au déploiement multi-environnements.*

#### Étape 3.1 : Déclenchement du build sain
Sur la branche `develop`, un commit propre est validé.

#### Étape 3.2 : Validation des Portes de Qualité (Stages 1 à 7)
- **Maven & JaCoCo** : Tous les tests unitaires et MockMvc passent (`BUILD SUCCESS`, couverture > 80%).
- **SonarQube** : Analyse SAST validée (note A, Quality Gate verte).
- **OWASP Dependency-Check** : Zéro vulnérabilité CVSS ≥ 8.
- **Trivy Container Scan** : Analyse des images construites (Zéro vulnérabilité critique/high non corrigée).

#### Étape 3.3 : Sécurisation Cryptographique Supply Chain (Stage 8)
1. **Génération SBOM (Syft)** :
   ```bash
   # Visualiser le SBOM généré
   cat build/sbom/omnipay-transaction-service-build-*.json | jq '.components[0:3]'
   ```
2. **Signature Cosign** :
   ```bash
   # L'image est signée avec la clé privée de l'autorité CI
   cosign sign --key k8s://omnipay-ci/cosign-key harbor.omnipay.local:30002/omnipay/transaction-service:build-42
   ```
3. **Vérification publique pour le jury :**
   ```bash
   cosign verify --key platform/kyverno/keys/cosign.pub harbor.omnipay.local:30002/omnipay/transaction-service:build-42
   ```
   *Sortie attendue :*
   ```text
   The following checks were performed on each of these signatures:
     - The cosign claims were validated
     - The signatures were verified against the specified public key
   ```

#### Étape 3.4 : Déploiement GitOps en Dev & Smoke-Tests (Stage 9)
- Le script `promote-release.sh` met à jour `envs/dev/kustomization.yaml` sur `omnipay-gitops`.
- ArgoCD synchronise instantanément (`Synched` / `Healthy`).
- Les smoke-tests s'exécutent en direct :
  ```text
  [SMOKE-TESTS] Validation Rapide Post-Déploiement
    • Vérification auth (/actuator/health) ... OK (HTTP 200)
    • Vérification transaction (/actuator/health) ... OK (HTTP 200)
    • POST /api/auth/login ... Authentification réussie (Jeton JWT émis)
  ```

#### Étape 3.5 : Promotion en Recette & Audit Dynamique DAST OWASP ZAP (Stage 10)
- Le pipeline promeut le tag vers `omnipay-recette`.
- Le conteneur **OWASP ZAP Baseline Scan** analyse l'API bancaire au runtime :
  ```bash
  ./ci/scripts/scan-dast-zap.sh http://api.omnipay.local/api/transactions HIGH
  ```
- Afficher le rapport HTML généré dans le navigateur : `build/reports/zap/zap-report.html`.
  * Résultat : Zéro faille High, en-têtes Zero-Trust validés.

#### Étape 3.6 : Gate Contrôlée de Mise en Production (Stage 11)
- Pour la production (`omnipay-prod`), le pipeline attend :
  - Soit un Tag Git officiel (`v1.0.0`).
  - Soit l'approbation manuelle du Release Manager dans Jenkins UI.
- Une fois approuvée, la promotion met à jour `envs/prod/transaction-service-rollout.yaml`, activant la stratégie **Canary progressive d'Argo Rollouts** (relai direct avec la Démo 1 de P4 !).

---

## 📊 Matrice Récapitulative des Écrans à Projeter au Jury

| Outil | URL / Commande | Ce que le Jury voit à l'écran |
| :--- | :--- | :--- |
| **Jenkins Blue Ocean** | `http://jenkins.omnipay.local:8088/blue` | Les 11 étapes vertes successives et la timeline de build (< 4 min). |
| **SonarQube** | `http://sonarqube.omnipay.local:30003` | Quality Gate Passed, JaCoCo > 80%, 0 Security Hotspots. |
| **Harbor Registry** | `http://harbor.omnipay.local:30002` | Images certifiées, badge Trivy (0 CVE), artefact `.sig` Cosign et `.sbom` Syft. |
| **Rapport ZAP DAST** | `build/reports/zap/zap-report.html` | Matrice des risques OWASP validée au runtime. |
| **ArgoCD GitOps** | `http://argocd.omnipay.local:30005` | Déploiement synchronisé en vert sur `dev`, `recette` et `prod`. |
