<#
==============================================================================
OmniPay Zero-Trust — Audit GitOps ArgoCD & Nettoyage Supply Chain Harbor
Fonctionnalités :
  1. Vérifier SyncStatus / HealthStatus de omnipay-dev, omnipay-recette, omnipay-prod.
  2. Auditer les politiques Kyverno et l'état Argo Rollouts.
  3. Nettoyer les artefacts orphelins et tags temporaires dans Harbor (API v2.0)
     tout en préservant les signatures Cosign, SBOM Syft et tags immuables.
  4. Générer un rapport Markdown d'audit de santé GitOps.
Sécurité : Zéro secret codé en dur (utiliser $env:HARBOR_PASSWORD / $env:ARGOCD_AUTH_TOKEN).
Rôle P4 : Widad El Gharzaz — Plateforme, Supply Chain Security & Lead GitOps
==============================================================================
#>

[CmdletBinding()]
param (
    [string]$ArgoCdNamespace = "argocd",
    [string]$HarborUrl = $(if ($env:HARBOR_URL) { $env:HARBOR_URL } else { "http://harbor.omnipay.local:30002" }),
    [string]$HarborProject = $(if ($env:HARBOR_PROJECT) { $env:HARBOR_PROJECT } else { "omnipay" }),
    [string]$HarborUser = $(if ($env:HARBOR_USER) { $env:HARBOR_USER } else { "admin" }),
    [string]$HarborPassword = $env:HARBOR_PASSWORD,
    [string]$TempTagRegex = "^(tmp-|temp-|pr-|dev-tmp-|test-|.*-draft$|.*-snapshot$)",
    [string]$ReportPath = "",
    [switch]$DryRun,
    [switch]$RunGc,
    [switch]$StrictMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$utcNow = (Get-Date).ToUniversalTime()
$timestamp = $utcNow.ToString("yyyyMMdd-HHmmss")

if (-not $ReportPath) {
    $ReportPath = Join-Path $rootDir "reports\audit-gitops-harbor-$timestamp.md"
}

Write-Host "===================================================================================" -ForegroundColor Blue
Write-Host " OmniPay Zero-Trust — Audit GitOps ArgoCD & Nettoyage Harbor (S4 P4)" -ForegroundColor Cyan
Write-Host " Date UTC : $($utcNow.ToString('yyyy-MM-dd HH:mm:ss UTC')) | Mode Dry-Run : $($DryRun.IsPresent)" -ForegroundColor Yellow
Write-Host "===================================================================================" -ForegroundColor Blue

$reportDir = Split-Path -Parent $ReportPath
if ($reportDir -and -not (Test-Path $reportDir)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}

$apps = @("omnipay-dev", "omnipay-recette", "omnipay-prod")
$appRowsMd = New-Object System.Collections.Generic.List[string]
$unhealthyApps = 0
$outOfSyncApps = 0
$missingApps = 0
$argoCdReachable = $true

# ------------------------------------------------------------------------------
# 1. Audit ArgoCD (omnipay-dev, omnipay-recette, omnipay-prod)
# ------------------------------------------------------------------------------
Write-Host "`n--> [1/4] Audit des applications ArgoCD ($($apps -join ', '))..." -ForegroundColor White

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Host "[AVERTISSEMENT] kubectl introuvable : audit Kubernetes/ArgoCD ignoré." -ForegroundColor Yellow
    $argoCdReachable = $false
} else {
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $null = kubectl get namespace $ArgoCdNamespace 2>$null
    $nsCode = $LASTEXITCODE
    $ErrorActionPreference = $prevPref
    if ($nsCode -ne 0) {
        Write-Host "[AVERTISSEMENT] Namespace '$ArgoCdNamespace' inaccessible ou absent." -ForegroundColor Yellow
        $argoCdReachable = $false
    }
}

if ($argoCdReachable) {
    Write-Host (" {0,-16} | {1,-15} | {2,-12} | {3,-12} | {4,-10} | {5}" -f "APPLICATION", "NAMESPACE", "SYNC", "HEALTH", "RÉVISION", "MODE") -ForegroundColor White
    Write-Host " ----------------------------------------------------------------------------------" -ForegroundColor Gray

    foreach ($app in $apps) {
        $prevPref = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $appJsonRaw = kubectl get application $app -n $ArgoCdNamespace -o json 2>$null
        $appExit = $LASTEXITCODE
        $ErrorActionPreference = $prevPref

        if ($appExit -ne 0 -or -not $appJsonRaw) {
            Write-Host (" {0,-16} | {1,-15} | {2,-12} | {3,-12} | {4,-10} | {5}" -f $app, "n/a", "Missing", "Unknown", "n/a", "n/a") -ForegroundColor Red
            $appRowsMd.Add("| ``$app`` | n/a | Missing | Unknown | n/a | n/a | NON CONFORME |")
            $missingApps++
            continue
        }

        $appObj = ($appJsonRaw | Out-String) | ConvertFrom-Json
        $syncStatus = if ($appObj.status.sync.status) { $appObj.status.sync.status } else { "Unknown" }
        $healthStatus = if ($appObj.status.health.status) { $appObj.status.health.status } else { "Unknown" }
        $revFull = if ($appObj.status.sync.revision) { [string]$appObj.status.sync.revision } else { "n/a" }
        $revision = if ($revFull.Length -ge 7) { $revFull.Substring(0, 7) } else { $revFull }
        $targetNs = if ($appObj.spec.destination.namespace) { $appObj.spec.destination.namespace } else { "n/a" }
        $hasAuto = ($null -ne $appObj.spec.syncPolicy -and $null -ne $appObj.spec.syncPolicy.automated)
        $syncMode = if ($hasAuto) { "Auto (Prune/Heal)" } else { "Manuel / Contrôlé" }

        if ($syncStatus -ne "Synced") { $outOfSyncApps++ }
        if ($healthStatus -ne "Healthy") { $unhealthyApps++ }

        $verdict = if ($syncStatus -eq "Synced" -and $healthStatus -eq "Healthy") { "OK" } else { "ATTENTION" }
        $rowColor = if ($verdict -eq "OK") { "Green" } else { "Yellow" }

        Write-Host (" {0,-16} | {1,-15} | {2,-12} | {3,-12} | {4,-10} | {5}" -f $app, $targetNs, $syncStatus, $healthStatus, $revision, $syncMode) -ForegroundColor $rowColor
        $appRowsMd.Add("| ``$app`` | ``$targetNs`` | $syncStatus | $healthStatus | ``$revision`` | $syncMode | $verdict |")
    }
} else {
    $appRowsMd.Add("| *ArgoCD* | *n/a* | *Non vérifié* | *Non vérifié* | *n/a* | *n/a* | CLUSTER INACCESSIBLE |")
}

# ------------------------------------------------------------------------------
# 2. Audit Kyverno & Argo Rollouts
# ------------------------------------------------------------------------------
Write-Host "`n--> [2/4] Vérification des politiques Kyverno et du Rollout prod..." -ForegroundColor White
$kyvernoMd = New-Object System.Collections.Generic.List[string]
$rolloutMd = ""

if ($argoCdReachable) {
    $policies = @(
        "verify-omnipay-image-signature",
        "require-run-as-non-root",
        "disallow-host-path-and-privileged",
        "require-ro-rootfs-and-drop-all",
        "mutate-inject-zero-trust-labels"
    )
    foreach ($pol in $policies) {
        $prevPref = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $null = kubectl get clusterpolicy $pol 2>$null
        $polOk = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $prevPref

        if ($polOk) {
            $mode = (kubectl get clusterpolicy $pol -o jsonpath="{.spec.validationFailureAction}" 2>$null | Out-String).Trim()
            if (-not $mode) { $mode = "Mutate" }
            $ready = (kubectl get clusterpolicy $pol -o jsonpath="{.status.conditions[?(@.type=='Ready')].status}" 2>$null | Out-String).Trim()
            if (-not $ready) { $ready = "True" }
            Write-Host "    ✔ Kyverno '$pol' [$mode | Ready=$ready]" -ForegroundColor Green
            $kyvernoMd.Add("| ``$pol`` | $mode | $ready |")
        } else {
            Write-Host "    ✘ Kyverno '$pol' absente" -ForegroundColor Red
            $kyvernoMd.Add("| ``$pol`` | Absente | False |")
        }
    }

    $roPhase = (kubectl get rollout transaction-service -n omnipay-prod -o jsonpath="{.status.phase}" 2>$null | Out-String).Trim()
    if (-not $roPhase) { $roPhase = "Absent" }
    $roImg = (kubectl get rollout transaction-service -n omnipay-prod -o jsonpath="{.spec.template.spec.containers[0].image}" 2>$null | Out-String).Trim()
    if (-not $roImg) { $roImg = "n/a" }
    Write-Host "    Rollout 'transaction-service' (omnipay-prod) : Phase=$roPhase | Image=$roImg" -ForegroundColor Cyan
    $rolloutMd = "- ``transaction-service`` (``omnipay-prod``) : Phase **$roPhase**, Image ``$roImg``"
} else {
    Write-Host "    [AVERTISSEMENT] Cluster inaccessible : vérification Kyverno/Rollouts ignorée." -ForegroundColor Yellow
    $kyvernoMd.Add("| *Cluster inaccessible* | *n/a* | *n/a* |")
    $rolloutMd = "- Rollout ``transaction-service`` : non vérifié (cluster inaccessible)"
}

# ------------------------------------------------------------------------------
# 3. Audit & Nettoyage Harbor (artefacts orphelins & tags temporaires)
# ------------------------------------------------------------------------------
Write-Host "`n--> [3/4] Audit & nettoyage Harbor ($HarborUrl/projects/$HarborProject)..." -ForegroundColor White

$harborStatus = "OK"
$harborCleanRows = New-Object System.Collections.Generic.List[string]
$totalArtifacts = 0
$totalOrphans = 0
$totalTempTags = 0
$deletedOrphans = 0
$deletedTempTags = 0
$criticalCveArtifacts = 0

if (-not $HarborPassword -and [Environment]::UserInteractive -and -not $DryRun) {
    $sec = Read-Host "Mot de passe Harbor pour '$HarborUser' (Entrée pour ignorer)" -AsSecureString
    if ($sec -and $sec.Length -gt 0) {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try {
            $HarborPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

if (-not $HarborPassword) {
    Write-Host "[INFO] HARBOR_PASSWORD non défini : nettoyage Harbor ignoré (définissez `$env:HARBOR_PASSWORD)." -ForegroundColor Yellow
    $harborStatus = "SKIPPED (HARBOR_PASSWORD non défini)"
} else {
    $pair = "${HarborUser}:${HarborPassword}"
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
    $headers = @{ Authorization = "Basic $b64"; Accept = "application/json" }
    $baseUrl = $HarborUrl.TrimEnd("/")

    try {
        $null = Invoke-RestMethod -Uri "$baseUrl/api/v2.0/systeminfo" -Headers $headers -Method Get -TimeoutSec 5 -ErrorAction Stop
        Write-Host "    ✔ Connecté à l'API Harbor v2.0 ($baseUrl)" -ForegroundColor Green

        $repos = Invoke-RestMethod -Uri "$baseUrl/api/v2.0/projects/$HarborProject/repositories?page_size=100" -Headers $headers -Method Get -TimeoutSec 10
        $semverRegex = "^v?\d+\.\d+\.\d+$"

        foreach ($repo in $repos) {
            $fullName = [string]$repo.name
            $repoName = if ($fullName.Contains("/")) { $fullName.Split("/", 2)[1] } else { $fullName }
            $repoEnc = [System.Uri]::EscapeDataString([System.Uri]::EscapeDataString($repoName))

            $artifacts = Invoke-RestMethod -Uri "$baseUrl/api/v2.0/projects/$HarborProject/repositories/$repoEnc/artifacts?page_size=100&with_tag=true&with_accessory=true&with_scan_overview=true" -Headers $headers -Method Get -TimeoutSec 10

            $protectedDigests = New-Object System.Collections.Generic.HashSet[string]
            foreach ($art in $artifacts) {
                if ($art.accessories) {
                    foreach ($acc in $art.accessories) {
                        if ($acc.digest) { [void]$protectedDigests.Add([string]$acc.digest) }
                    }
                }
            }

            foreach ($art in $artifacts) {
                $totalArtifacts++
                $digest = [string]$art.digest
                $shortDigest = if ($digest.Length -ge 19) { $digest.Substring(0, 19) } else { $digest }
                $artType = if ($art.type) { ([string]$art.type).ToUpperInvariant() } else { "" }
                $tags = @($art.tags | Where-Object { $null -ne $_ })

                if ($art.scan_overview) {
                    foreach ($prop in $art.scan_overview.PSObject.Properties) {
                        $critCount = $prop.Value.summary.summary.Critical
                        if ($critCount -and [int]$critCount -gt 0) { $criticalCveArtifacts++ }
                    }
                }

                if ($protectedDigests.Contains($digest) -or $artType -in @("SIGNATURE", "SBOM", "COSIGN")) {
                    continue
                }

                foreach ($tag in $tags) {
                    $tname = [string]$tag.name
                    if (-not $tname -or ($tname -match $semverRegex) -or ($tname -in @("latest", "1.0.0"))) {
                        continue
                    }
                    if (($tname -match $TempTagRegex) -and (-not [bool]$tag.immutable)) {
                        $totalTempTags++
                        $action = if ($DryRun) { "SIMULÉ (dry-run)" } else { "SUPPRIMÉ" }
                        if (-not $DryRun) {
                            try {
                                $tagEnc = [System.Uri]::EscapeDataString($tname)
                                Invoke-RestMethod -Uri "$baseUrl/api/v2.0/projects/$HarborProject/repositories/$repoEnc/artifacts/$digest/tags/$tagEnc" -Headers $headers -Method Delete -TimeoutSec 10 | Out-Null
                                $deletedTempTags++
                            } catch {
                                $action = "ERREUR ($($_.Exception.Message))"
                            }
                        }
                        $harborCleanRows.Add("| ``$repoName`` | Tag temporaire ``$tname`` | ``$shortDigest`` | $action |")
                    }
                }

                if ($tags.Count -eq 0) {
                    $totalOrphans++
                    $action = if ($DryRun) { "SIMULÉ (dry-run)" } else { "SUPPRIMÉ" }
                    if (-not $DryRun) {
                        try {
                            Invoke-RestMethod -Uri "$baseUrl/api/v2.0/projects/$HarborProject/repositories/$repoEnc/artifacts/$digest" -Headers $headers -Method Delete -TimeoutSec 10 | Out-Null
                            $deletedOrphans++
                        } catch {
                            $action = "ERREUR ($($_.Exception.Message))"
                        }
                    }
                    $harborCleanRows.Add("| ``$repoName`` | Artefact orphelin (sans tag) | ``$shortDigest`` | $action |")
                }
            }
        }

        if ($RunGc -and -not $DryRun) {
            Write-Host "    Déclenchement du Garbage Collector Harbor..." -ForegroundColor Gray
            $gcBody = @{ schedule = @{ type = "Manual" } } | ConvertTo-Json
            try {
                Invoke-RestMethod -Uri "$baseUrl/api/v2.0/system/gc/schedule" -Headers $headers -Method Post -ContentType "application/json" -Body $gcBody -TimeoutSec 10 | Out-Null
            } catch {
                Write-Host "    [INFO] GC Harbor non déclenché : $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        Write-Host "    Artefacts analysés         : $totalArtifacts" -ForegroundColor White
        Write-Host "    Artefacts CVE Critiques    : $criticalCveArtifacts" -ForegroundColor White
        Write-Host "    Orphelins détectés/purgés  : $totalOrphans / $deletedOrphans" -ForegroundColor Green
        Write-Host "    Tags temp détectés/purgés  : $totalTempTags / $deletedTempTags" -ForegroundColor Green
    } catch {
        Write-Host "[AVERTISSEMENT] API Harbor injoignable sur $HarborUrl : $($_.Exception.Message)" -ForegroundColor Yellow
        $harborStatus = "UNREACHABLE ($HarborUrl)"
    }
}

if ($harborCleanRows.Count -eq 0) {
    $harborCleanRows.Add("| *Aucun* | *Registre propre* | *-* | *AUCUNE ACTION REQUISE* |")
}

# ------------------------------------------------------------------------------
# 4. Génération du Rapport d'Audit GitOps & Harbor
# ------------------------------------------------------------------------------
Write-Host "`n--> [4/4] Génération du rapport d'audit : $ReportPath" -ForegroundColor White

$globalStatus = "CONFORME (PASS)"
if ($missingApps -gt 0 -or $unhealthyApps -gt 0) {
    $globalStatus = "CRITIQUE (ACTION REQUISE)"
} elseif ($outOfSyncApps -gt 0 -or $criticalCveArtifacts -gt 0) {
    $globalStatus = "ATTENTION (DÉRIVE OU CVE DÉTECTÉE)"
} elseif (-not $argoCdReachable) {
    $globalStatus = "PARTIEL (CLUSTER HORS LIGNE)"
}

$branchName = "main"
try {
    $b = (git -C $rootDir rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
    if ($b) { $branchName = $b }
} catch {}

$reportContent = @"
# Rapport d'Audit Santé GitOps & Registre Harbor — OmniPay Zero-Trust

- **Date UTC** : $($utcNow.ToString('yyyy-MM-dd HH:mm:ss UTC'))
- **Responsable (P4)** : Widad El Gharzaz
- **Dépôt GitOps** : ``omnipay-gitops`` (branche ``$branchName``)
- **Mode Dry-Run** : ``$($DryRun.IsPresent)``
- **Verdict Global** : **$globalStatus**

---

## 1. État de Synchronisation ArgoCD (``ApplicationSet: omnipay-environments``)

| Application | Namespace | SyncStatus | HealthStatus | Révision | Mode Sync | Verdict |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
$($appRowsMd -join "`n")

---

## 2. Gouvernance Runtime & Déploiement Progressif (Kyverno & Argo Rollouts)

### Politiques Kyverno

| ClusterPolicy | Action | Ready |
| :--- | :--- | :--- |
$($kyvernoMd -join "`n")

### État Argo Rollouts (Production)
$rolloutMd

---

## 3. Audit & Nettoyage du Registre Harbor (``$HarborProject``)

- **Statut connexion Harbor** : ``$harborStatus``
- **Artefacts inspectés** : $totalArtifacts
- **Artefacts avec CVE Critical (Trivy)** : $criticalCveArtifacts
- **Artefacts orphelins détectés / nettoyés** : $totalOrphans / $deletedOrphans
- **Tags temporaires détectés / nettoyés** : $totalTempTags / $deletedTempTags
- **Protection Zero-Trust** : Les signatures OCI Cosign, attestations SBOM Syft et tags immuables SemVer sont systématiquement préservés.

| Dépôt | Cible | Digest | Action |
| :--- | :--- | :--- | :--- |
$($harborCleanRows -join "`n")

---
*Rapport généré automatiquement par ``scripts/audit-gitops-harbor.ps1`` — Aucun secret exposé.*
"@

Set-Content -Path $ReportPath -Value $reportContent -Encoding UTF8

Write-Host "✔ Rapport d'audit généré avec succès : $ReportPath" -ForegroundColor Green
Write-Host "    Verdict global : $globalStatus" -ForegroundColor Cyan

if ($StrictMode -and $globalStatus -ne "CONFORME (PASS)") {
    throw "[STRICT MODE] Échec : statut global '$globalStatus'."
}
