// ==============================================================================
// OmniPay Zero-Trust — Snippet Pipeline Jenkins (P1 x P4)
// Étapes Supply-Chain : SBOM Syft, Cosign Sign & Mise à jour GitOps
// ==============================================================================

stage('Supply Chain Security & Packaging') {
    environment {
        HARBOR_REGISTRY = 'harbor.omnipay.local:30002'
        HARBOR_PROJECT  = 'omnipay'
        COSIGN_PASSWORD = credentials('cosign-private-key-password')
    }
    steps {
        echo '=== ÉTAPE P4 : BUILD, SBOM SYFT, PUBLICATION HARBOR & SIGNATURE COSIGN ==='
        withCredentials([
            usernamePassword(
                credentialsId: 'harbor-robot-ci-creds',
                usernameVariable: 'HARBOR_ROBOT_USER',
                passwordVariable: 'HARBOR_ROBOT_SECRET'
            ),
            file(credentialsId: 'cosign-private-key-file', variable: 'COSIGN_KEY_FILE'),
            file(credentialsId: 'cosign-public-key-file', variable: 'COSIGN_PUB_FILE')
        ]) {
            sh '''
                set -euo pipefail

                # 1. Connexion au registre privé Harbor
                echo "${HARBOR_ROBOT_SECRET}" | docker login "${HARBOR_REGISTRY}" \
                    -u "${HARBOR_ROBOT_USER}" --password-stdin

                IMAGE_TAG="${GIT_COMMIT:0:7}"
                SERVICES=("auth" "transaction" "notification")

                for SVC in "${SERVICES[@]}"; do
                    if [ -d "services/${SVC}" ]; then
                        FULL_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${SVC}-service:${IMAGE_TAG}"
                        LATEST_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${SVC}-service:latest"

                        echo "===> Traitement du microservice : ${SVC}"

                        # A. Build du conteneur
                        docker build -t "${FULL_IMAGE}" -t "${LATEST_IMAGE}" "services/${SVC}"

                        # B. Génération du SBOM Syft
                        syft "${FULL_IMAGE}" -o spdx-json="sbom-${SVC}-${IMAGE_TAG}.spdx.json"
                        syft "${FULL_IMAGE}" -o table

                        # C. Push vers Harbor
                        docker push "${FULL_IMAGE}"
                        docker push "${LATEST_IMAGE}"

                        # D. Attachement SBOM & Signature Cosign
                        cosign attach sbom --sbom "sbom-${SVC}-${IMAGE_TAG}.spdx.json" "${FULL_IMAGE}"
                        cosign sign --key "${COSIGN_KEY_FILE}" --yes "${FULL_IMAGE}"

                        # E. Vérification cryptographique
                        cosign verify --key "${COSIGN_PUB_FILE}" "${FULL_IMAGE}"
                    fi
                done
            '''
        }
    }
}

stage('Promote to GitOps (Dev)') {
    steps {
        echo '=== ÉTAPE P4 : PROPAGATION DE LA NOUVELLE VERSION VERS OMNIPAY-GITOPS ==='
        withCredentials([usernamePassword(
            credentialsId: 'github-gitops-token',
            usernameVariable: 'GIT_USER',
            passwordVariable: 'GIT_TOKEN'
        )]) {
            sh '''
                set -euo pipefail
                IMAGE_TAG="${GIT_COMMIT:0:7}"

                git clone "https://${GIT_USER}:${GIT_TOKEN}@github.com/achmaouiayoub120-beep/omnipay-gitops.git" gitops-repo
                cd gitops-repo/envs/dev

                # Mise à jour des tags d'images dans kustomization.yaml
                sed -i -E "s/(newTag: ).*/\1${IMAGE_TAG}/" kustomization.yaml

                git config user.name "OmniPay CI Robot"
                git config user.email "ci-robot@omnipay.local"

                git add kustomization.yaml
                if ! git diff --cached --quiet; then
                    git commit -m "chore(release): bump services to image tag ${IMAGE_TAG} [skip ci]"
                    git push origin main
                    echo "--> Déploiement GitOps déclenché via ArgoCD pour le tag : ${IMAGE_TAG}"
                else
                    echo "--> Aucun changement d'image à propager."
                fi
            '''
        }
    }
}
