#!/usr/bin/env bash
# ==============================================================================
# OmniPay Zero-Trust — Audit GitOps ArgoCD & Nettoyage Supply Chain Harbor
# Fonctionnalités :
#   1. Vérifier SyncStatus / HealthStatus de omnipay-dev, omnipay-recette, omnipay-prod.
#   2. Auditer les politiques Kyverno et l'état Argo Rollouts.
#   3. Nettoyer les artefacts orphelins et tags temporaires dans Harbor (API v2.0)
#      tout en préservant les signatures Cosign, SBOM Syft et tags immuables.
#   4. Générer un rapport Markdown d'audit de santé GitOps.
# Sécurité : Zéro secret codé en dur (utiliser HARBOR_PASSWORD / ARGOCD_AUTH_TOKEN).
# Rôle P4 : Widad El Gharzaz — Plateforme, Supply Chain Security & Lead GitOps
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
HARBOR_URL="${HARBOR_URL:-http://harbor.omnipay.local:30002}"
HARBOR_PROJECT="${HARBOR_PROJECT:-omnipay}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:-}"
TEMP_TAG_REGEX="${TEMP_TAG_REGEX:-^(tmp-|temp-|pr-|dev-tmp-|test-|.*-draft$|.*-snapshot$)}"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
REPORT_PATH="${REPORT_PATH:-${ROOT_DIR}/reports/audit-gitops-harbor-${TIMESTAMP}.md}"
DRY_RUN="${DRY_RUN:-false}"
RUN_GC="${RUN_GC:-false}"
STRICT_MODE="${STRICT_MODE:-false}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)   DRY_RUN="true"; shift ;;
        --run-gc)    RUN_GC="true"; shift ;;
        --strict)    STRICT_MODE="true"; shift ;;
        --output|-o)
            [ "$#" -ge 2 ] || { echo "[ERREUR] --output requiert un chemin." >&2; exit 1; }
            REPORT_PATH="$2"; shift 2 ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--dry-run] [--run-gc] [--strict] [--output <fichier.md>]
Variables d'environnement :
  HARBOR_URL       URL du registre Harbor (défaut : http://harbor.omnipay.local:30002)
  HARBOR_PROJECT   Projet Harbor cible (défaut : omnipay)
  HARBOR_USER      Utilisateur Harbor (défaut : admin)
  HARBOR_PASSWORD  Mot de passe Harbor (jamais codé en dur ; requis pour API Harbor)
  ARGOCD_NAMESPACE Namespace ArgoCD (défaut : argocd)
  TEMP_TAG_REGEX   Regex des tags temporaires à purger
  REPORT_PATH      Chemin du rapport Markdown généré
EOF
            exit 0 ;;
        *)
            echo "[ERREUR] Option inconnue : $1" >&2
            exit 1 ;;
    esac
done

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}${BLUE}===================================================================================${NC}"
echo -e " ${BOLD}OmniPay Zero-Trust — Audit GitOps ArgoCD & Nettoyage Harbor (S4 P4)${NC}"
echo -e " Date UTC : $(date -u '+%Y-%m-%d %H:%M:%S UTC') | Mode Dry-Run : ${DRY_RUN}"
echo -e "${BOLD}${BLUE}===================================================================================${NC}"

mkdir -p "$(dirname "${REPORT_PATH}")"

APPS=("omnipay-dev" "omnipay-recette" "omnipay-prod")
APP_ROWS_MD=""
UNHEALTHY_APPS=0
OUTOFSYNC_APPS=0
MISSING_APPS=0
ARGOCD_REACHABLE=true

# ------------------------------------------------------------------------------
# 1. Audit ArgoCD (omnipay-dev, omnipay-recette, omnipay-prod)
# ------------------------------------------------------------------------------
echo -e "\n--> ${BOLD}[1/4] Audit des applications ArgoCD (${APPS[*]})...${NC}"

if ! command -v kubectl >/dev/null 2>&1; then
    echo -e "${YELLOW}[AVERTISSEMENT] kubectl introuvable : audit Kubernetes/ArgoCD ignoré.${NC}"
    ARGOCD_REACHABLE=false
elif ! kubectl get namespace "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
    echo -e "${YELLOW}[AVERTISSEMENT] Namespace '${ARGOCD_NAMESPACE}' inaccessible ou absent.${NC}"
    ARGOCD_REACHABLE=false
fi

if [ "${ARGOCD_REACHABLE}" = true ]; then
    printf " %-16s | %-15s | %-12s | %-12s | %-10s | %s\n" \
        "APPLICATION" "NAMESPACE" "SYNC" "HEALTH" "RÉVISION" "MODE"
    echo " ----------------------------------------------------------------------------------"

    for app in "${APPS[@]}"; do
        app_json="$(kubectl get application "${app}" -n "${ARGOCD_NAMESPACE}" -o json 2>/dev/null || true)"
        if [ -z "${app_json}" ]; then
            printf " %-16s | %-15s | ${RED}%-12s${NC} | ${RED}%-12s${NC} | %-10s | %s\n" \
                "${app}" "n/a" "Missing" "Unknown" "n/a" "n/a"
            APP_ROWS_MD="${APP_ROWS_MD}| \`${app}\` | n/a | Missing | Unknown | n/a | n/a | NON CONFORME |\n"
            MISSING_APPS=$((MISSING_APPS + 1))
            continue
        fi

        if command -v python3 >/dev/null 2>&1; then
            parsed="$(printf '%s' "${app_json}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
st = d.get("status", {})
sp = d.get("spec", {})
sync = st.get("sync", {}).get("status", "Unknown")
health = st.get("health", {}).get("status", "Unknown")
rev = (st.get("sync", {}).get("revision") or "n/a")[:7]
ns = sp.get("destination", {}).get("namespace", "n/a")
auto = "Auto (Prune/Heal)" if sp.get("syncPolicy", {}).get("automated") else "Manuel / Contrôlé"
print(f"{ns}|{sync}|{health}|{rev}|{auto}")
')"
            IFS='|' read -r target_ns sync_status health_status revision sync_mode <<< "${parsed}"
        else
            sync_status="$(printf '%s' "${app_json}" | grep -o '"sync":{"status":"[^"]*"' | head -n1 | cut -d'"' -f6 || echo "Unknown")"
            health_status="$(printf '%s' "${app_json}" | grep -o '"health":{"status":"[^"]*"' | head -n1 | cut -d'"' -f6 || echo "Unknown")"
            target_ns="$(printf '%s' "${app_json}" | grep -o '"destination":{"namespace":"[^"]*"' | head -n1 | cut -d'"' -f6 || echo "n/a")"
            revision="n/a"
            if printf '%s' "${app_json}" | grep -q '"automated":{'; then
                sync_mode="Auto (Prune/Heal)"
            else
                sync_mode="Manuel / Contrôlé"
            fi
        fi

        [ "${sync_status}" != "Synced" ] && OUTOFSYNC_APPS=$((OUTOFSYNC_APPS + 1))
        [ "${health_status}" != "Healthy" ] && UNHEALTHY_APPS=$((UNHEALTHY_APPS + 1))

        verdict="OK"
        [ "${sync_status}" != "Synced" ] || [ "${health_status}" != "Healthy" ] && verdict="ATTENTION"

        c_sync="${GREEN}"; [ "${sync_status}" != "Synced" ] && c_sync="${YELLOW}"
        c_health="${GREEN}"; [ "${health_status}" != "Healthy" ] && c_health="${RED}"

        printf " %-16s | %-15s | ${c_sync}%-12s${NC} | ${c_health}%-12s${NC} | %-10s | %s\n" \
            "${app}" "${target_ns}" "${sync_status}" "${health_status}" "${revision}" "${sync_mode}"
        APP_ROWS_MD="${APP_ROWS_MD}| \`${app}\` | \`${target_ns}\` | ${sync_status} | ${health_status} | \`${revision}\` | ${sync_mode} | ${verdict} |\n"
    done
else
    APP_ROWS_MD="| *ArgoCD* | *n/a* | *Non vérifié* | *Non vérifié* | *n/a* | *n/a* | CLUSTER INACCESSIBLE |\n"
fi

# ------------------------------------------------------------------------------
# 2. Audit Kyverno & Argo Rollouts
# ------------------------------------------------------------------------------
echo -e "\n--> ${BOLD}[2/4] Vérification des politiques Kyverno et du Rollout prod...${NC}"
KYVERNO_MD=""
ROLLOUT_MD=""

if [ "${ARGOCD_REACHABLE}" = true ]; then
    for pol in "verify-omnipay-image-signature" "require-run-as-non-root" "disallow-host-path-and-privileged" "require-ro-rootfs-and-drop-all" "mutate-inject-zero-trust-labels"; do
        if kubectl get clusterpolicy "${pol}" >/dev/null 2>&1; then
            mode="$(kubectl get clusterpolicy "${pol}" -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null || echo "Mutate")"
            ready="$(kubectl get clusterpolicy "${pol}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "True")"
            echo -e "    ${GREEN}✔${NC} Kyverno '${pol}' [${mode:-Mutate} | Ready=${ready:-True}]"
            KYVERNO_MD="${KYVERNO_MD}| \`${pol}\` | ${mode:-Mutate} | ${ready:-True} |\n"
        else
            echo -e "    ${RED}✘${NC} Kyverno '${pol}' absente"
            KYVERNO_MD="${KYVERNO_MD}| \`${pol}\` | Absente | False |\n"
        fi
    done

    ro_phase="$(kubectl get rollout transaction-service -n omnipay-prod -o jsonpath='{.status.phase}' 2>/dev/null || echo "Absent")"
    ro_img="$(kubectl get rollout transaction-service -n omnipay-prod -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "n/a")"
    echo -e "    Rollout 'transaction-service' (omnipay-prod) : Phase=${CYAN}${ro_phase}${NC} | Image=${ro_img}"
    ROLLOUT_MD="- \`transaction-service\` (\`omnipay-prod\`) : Phase **${ro_phase}**, Image \`${ro_img}\`"
else
    echo -e "    ${YELLOW}[AVERTISSEMENT] Cluster inaccessible : vérification Kyverno/Rollouts ignorée.${NC}"
    KYVERNO_MD="| *Cluster inaccessible* | *n/a* | *n/a* |\n"
    ROLLOUT_MD="- Rollout \`transaction-service\` : non vérifié (cluster inaccessible)"
fi

# ------------------------------------------------------------------------------
# 3. Audit & Nettoyage Harbor (artefacts orphelins & tags temporaires)
# ------------------------------------------------------------------------------
echo -e "\n--> ${BOLD}[3/4] Audit & nettoyage Harbor (${HARBOR_URL}/projects/${HARBOR_PROJECT})...${NC}"

HARBOR_STATUS="OK"
HARBOR_SUMMARY_MD=""
HARBOR_CLEAN_ROWS_MD=""
TOTAL_ARTIFACTS=0
TOTAL_ORPHANS=0
TOTAL_TEMP_TAGS=0
DELETED_ORPHANS=0
DELETED_TEMP_TAGS=0
CRITICAL_CVE_ARTIFACTS=0

if [ -z "${HARBOR_PASSWORD}" ] && [ -t 0 ] && [ "${DRY_RUN}" != "true" ]; then
    read -r -s -p "Mot de passe Harbor pour '${HARBOR_USER}' (laisser vide pour ignorer le nettoyage API) : " HARBOR_PASSWORD || true
    echo ""
fi

if ! command -v curl >/dev/null 2>&1; then
    echo -e "${YELLOW}[AVERTISSEMENT] curl introuvable : audit Harbor ignoré.${NC}"
    HARBOR_STATUS="SKIPPED (curl absent)"
elif [ -z "${HARBOR_PASSWORD}" ]; then
    echo -e "${YELLOW}[INFO] HARBOR_PASSWORD non défini : nettoyage Harbor ignoré (définissez HARBOR_PASSWORD en variable d'env).${NC}"
    HARBOR_STATUS="SKIPPED (HARBOR_PASSWORD non défini)"
elif ! curl -sf -u "${HARBOR_USER}:${HARBOR_PASSWORD}" --max-time 5 "${HARBOR_URL}/api/v2.0/systeminfo" >/dev/null 2>&1; then
    echo -e "${YELLOW}[AVERTISSEMENT] API Harbor injoignable sur ${HARBOR_URL}.${NC}"
    HARBOR_STATUS="UNREACHABLE (${HARBOR_URL})"
else
    echo -e "    ${GREEN}✔${NC} Connecté à l'API Harbor v2.0 (${HARBOR_URL})"
    REPOS_JSON="$(curl -sf -u "${HARBOR_USER}:${HARBOR_PASSWORD}" \
        "${HARBOR_URL}/api/v2.0/projects/${HARBOR_PROJECT}/repositories?page_size=100" || echo "[]")"

    if command -v python3 >/dev/null 2>&1; then
        AUDIT_RESULT="$(REPOS_JSON="${REPOS_JSON}" HARBOR_URL="${HARBOR_URL}" HARBOR_PROJECT="${HARBOR_PROJECT}" \
            HARBOR_USER="${HARBOR_USER}" HARBOR_PASSWORD="${HARBOR_PASSWORD}" \
            TEMP_TAG_REGEX="${TEMP_TAG_REGEX}" DRY_RUN="${DRY_RUN}" \
            python3 - <<'PY'
import base64
import json
import os
import re
import urllib.parse
import urllib.request
import urllib.error

harbor_url = os.environ["HARBOR_URL"].rstrip("/")
project = os.environ["HARBOR_PROJECT"]
user = os.environ["HARBOR_USER"]
password = os.environ["HARBOR_PASSWORD"]
temp_regex = re.compile(os.environ["TEMP_TAG_REGEX"])
semver_regex = re.compile(r"^v?\d+\.\d+\.\d+$")
dry_run = os.environ["DRY_RUN"].lower() == "true"

auth_token = base64.b64encode(f"{user}:{password}".encode()).decode()
headers = {"Authorization": f"Basic {auth_token}", "Accept": "application/json"}

def api_req(path, method="GET"):
    req = urllib.request.Request(f"{harbor_url}{path}", headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = resp.read().decode("utf-8")
        return json.loads(body) if body else None

repos = json.loads(os.environ["REPOS_JSON"])
total_artifacts = 0
total_orphans = 0
total_temp_tags = 0
deleted_orphans = 0
deleted_temp_tags = 0
critical_cves = 0
rows = []

for repo in repos:
    full_name = repo.get("name", "")
    repo_name = full_name.split("/", 1)[1] if "/" in full_name else full_name
    repo_enc = urllib.parse.quote(urllib.parse.quote(repo_name, safe=""), safe="")
    artifacts = api_req(
        f"/api/v2.0/projects/{project}/repositories/{repo_enc}/artifacts"
        "?page_size=100&with_tag=true&with_accessory=true&with_scan_overview=true"
    ) or []

    # Collecter les digests référencés comme accessoires (signatures Cosign, SBOM Syft)
    protected_digests = set()
    for art in artifacts:
        for acc in (art.get("accessories") or []):
            if acc.get("digest"):
                protected_digests.add(acc["digest"])

    for art in artifacts:
        total_artifacts += 1
        digest = art.get("digest", "")
        short_digest = digest[:19]
        art_type = (art.get("type") or "").upper()
        tags = art.get("tags") or []

        # Compter CVE critiques si scan présent
        scan = art.get("scan_overview") or {}
        for _, overview in scan.items():
            summary = overview.get("summary", {}).get("summary", {})
            if summary.get("Critical", 0) > 0:
                critical_cves += 1

        # Protéger les accessoires Cosign / SBOM
        if digest in protected_digests or art_type in ("SIGNATURE", "SBOM", "COSIGN"):
            continue

        # 1) Tags temporaires
        for tag in tags:
            tname = tag.get("name", "")
            if not tname or semver_regex.match(tname) or tname in ("latest", "1.0.0"):
                continue
            if temp_regex.match(tname) and not tag.get("immutable", False):
                total_temp_tags += 1
                action = "SIMULÉ (dry-run)" if dry_run else "SUPPRIMÉ"
                if not dry_run:
                    try:
                        api_req(
                            f"/api/v2.0/projects/{project}/repositories/{repo_enc}/artifacts/{digest}/tags/{urllib.parse.quote(tname, safe='')}",
                            method="DELETE"
                        )
                        deleted_temp_tags += 1
                    except urllib.error.HTTPError as e:
                        action = f"ERREUR HTTP {e.code}"
                rows.append(f"| `{repo_name}` | Tag temporaire `{tname}` | `{short_digest}` | {action} |")

        # 2) Artefacts orphelins sans tag
        if len(tags) == 0:
            total_orphans += 1
            action = "SIMULÉ (dry-run)" if dry_run else "SUPPRIMÉ"
            if not dry_run:
                try:
                    api_req(
                        f"/api/v2.0/projects/{project}/repositories/{repo_enc}/artifacts/{digest}",
                        method="DELETE"
                    )
                    deleted_orphans += 1
                except urllib.error.HTTPError as e:
                    action = f"ERREUR HTTP {e.code}"
            rows.append(f"| `{repo_name}` | Artefact orphelin (sans tag) | `{short_digest}` | {action} |")

print(json.dumps({
    "total_artifacts": total_artifacts,
    "total_orphans": total_orphans,
    "total_temp_tags": total_temp_tags,
    "deleted_orphans": deleted_orphans,
    "deleted_temp_tags": deleted_temp_tags,
    "critical_cves": critical_cves,
    "rows": rows,
}))
PY
)"
        TOTAL_ARTIFACTS="$(printf '%s' "${AUDIT_RESULT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total_artifacts"])')"
        TOTAL_ORPHANS="$(printf '%s' "${AUDIT_RESULT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total_orphans"])')"
        TOTAL_TEMP_TAGS="$(printf '%s' "${AUDIT_RESULT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total_temp_tags"])')"
        DELETED_ORPHANS="$(printf '%s' "${AUDIT_RESULT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["deleted_orphans"])')"
        DELETED_TEMP_TAGS="$(printf '%s' "${AUDIT_RESULT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["deleted_temp_tags"])')"
        CRITICAL_CVE_ARTIFACTS="$(printf '%s' "${AUDIT_RESULT}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["critical_cves"])')"
        HARBOR_CLEAN_ROWS_MD="$(printf '%s' "${AUDIT_RESULT}" | python3 -c 'import json,sys; r=json.load(sys.stdin)["rows"]; print("\n".join(r) if r else "| *Aucun* | *Registre propre* | *-* | *AUCUNE ACTION REQUISE* |")')"
    else
        echo -e "${YELLOW}[INFO] python3 absent : vérification sommaire de la liste des dépôts Harbor.${NC}"
        HARBOR_CLEAN_ROWS_MD="| *${HARBOR_PROJECT}* | *Audit détaillé requiert python3* | *-* | *INFO* |"
    fi

    if [ "${RUN_GC}" = "true" ] && [ "${DRY_RUN}" != "true" ]; then
        echo "    Déclenchement du Garbage Collector Harbor..."
        curl -sf -X POST -u "${HARBOR_USER}:${HARBOR_PASSWORD}" \
            -H "Content-Type: application/json" \
            -d '{"schedule":{"type":"Manual"}}' \
            "${HARBOR_URL}/api/v2.0/system/gc/schedule" >/dev/null 2>&1 || true
    fi

    echo -e "    Artefacts analysés         : ${BOLD}${TOTAL_ARTIFACTS}${NC}"
    echo -e "    Artefacts CVE Critiques    : ${BOLD}${CRITICAL_CVE_ARTIFACTS}${NC}"
    echo -e "    Orphelins détectés/purgés  : ${BOLD}${TOTAL_ORPHANS}${NC} / ${GREEN}${DELETED_ORPHANS}${NC}"
    echo -e "    Tags temp détectés/purgés  : ${BOLD}${TOTAL_TEMP_TAGS}${NC} / ${GREEN}${DELETED_TEMP_TAGS}${NC}"
fi

# ------------------------------------------------------------------------------
# 4. Génération du Rapport d'Audit GitOps & Harbor
# ------------------------------------------------------------------------------
printf "\n--> ${BOLD}[4/4] Génération du rapport d'audit : %s${NC}\n" "${REPORT_PATH}"

GLOBAL_STATUS="CONFORME (PASS)"
if [ "${MISSING_APPS}" -gt 0 ] || [ "${UNHEALTHY_APPS}" -gt 0 ]; then
    GLOBAL_STATUS="CRITIQUE (ACTION REQUISE)"
elif [ "${OUTOFSYNC_APPS}" -gt 0 ] || [ "${CRITICAL_CVE_ARTIFACTS}" -gt 0 ]; then
    GLOBAL_STATUS="ATTENTION (DÉRIVE OU CVE DÉTECTÉE)"
elif [ "${ARGOCD_REACHABLE}" != true ]; then
    GLOBAL_STATUS="PARTIEL (CLUSTER HORS LIGNE)"
fi

cat > "${REPORT_PATH}" <<EOF
# Rapport d'Audit Santé GitOps & Registre Harbor — OmniPay Zero-Trust

- **Date UTC** : $(date -u '+%Y-%m-%d %H:%M:%S UTC')
- **Responsable (P4)** : Widad El Gharzaz
- **Dépôt GitOps** : \`omnipay-gitops\` (branche \`$(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")\`)
- **Mode Dry-Run** : \`${DRY_RUN}\`
- **Verdict Global** : **${GLOBAL_STATUS}**

---

## 1. État de Synchronisation ArgoCD (\`ApplicationSet: omnipay-environments\`)

| Application | Namespace | SyncStatus | HealthStatus | Révision | Mode Sync | Verdict |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
$(printf '%b' "${APP_ROWS_MD}")

---

## 2. Gouvernance Runtime & Déploiement Progressif (Kyverno & Argo Rollouts)

### Politiques Kyverno

| ClusterPolicy | Action | Ready |
| :--- | :--- | :--- |
$(printf '%b' "${KYVERNO_MD}")

### État Argo Rollouts (Production)
${ROLLOUT_MD}

---

## 3. Audit & Nettoyage du Registre Harbor (\`${HARBOR_PROJECT}\`)

- **Statut connexion Harbor** : \`${HARBOR_STATUS}\`
- **Artefacts inspectés** : ${TOTAL_ARTIFACTS}
- **Artefacts avec CVE Critical (Trivy)** : ${CRITICAL_CVE_ARTIFACTS}
- **Artefacts orphelins détectés / nettoyés** : ${TOTAL_ORPHANS} / ${DELETED_ORPHANS}
- **Tags temporaires détectés / nettoyés** : ${TOTAL_TEMP_TAGS} / ${DELETED_TEMP_TAGS}
- **Protection Zero-Trust** : Les signatures OCI Cosign, attestations SBOM Syft et tags immuables SemVer sont systématiquement préservés.

| Dépôt | Cible | Digest | Action |
| :--- | :--- | :--- | :--- |
$(printf '%b' "${HARBOR_CLEAN_ROWS_MD}")

---
*Rapport généré automatiquement par \`scripts/audit-gitops-harbor.sh\` — Aucun secret exposé.*
EOF

printf "${GREEN}✔ Rapport d'audit généré avec succès : %s${NC}\n" "${REPORT_PATH}"
printf "    Verdict global : ${BOLD}%s${NC}\n" "${GLOBAL_STATUS}"

if [ "${STRICT_MODE}" = "true" ] && [ "${GLOBAL_STATUS}" != "CONFORME (PASS)" ]; then
    echo -e "${RED}[STRICT MODE] Échec : statut global '${GLOBAL_STATUS}'.${NC}" >&2
    exit 1
fi
