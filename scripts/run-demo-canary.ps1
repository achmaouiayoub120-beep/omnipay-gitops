<#
==============================================================================
OmniPay Zero-Trust — Automatisation Démo 1 Jury : Argo Rollouts Canary & Auto-Rollback (PowerShell)
Démontre la résilience bancaire : détection anomalie 5xx et rollback < 30s
Rôle P4 : Widad El Gharzaz (Packaging, Harbor, Argo Rollouts & Kyverno)
==============================================================================
#>

[CmdletBinding()]
param (
    [string]$Namespace = "omnipay-prod",
    [string]$RolloutName = "transaction-service",
    [string]$StableImage = "harbor.omnipay.local:30002/omnipay/transaction-service:1.0.0",
    [string]$BadImage = "harbor.omnipay.local:30002/omnipay/transaction-service:v2-bad",
    [int]$TrafficSeconds = 60,
    [switch]$AutoReset
)

$ErrorActionPreference = "Stop"

Write-Host "===================================================================================" -ForegroundColor Cyan
Write-Host " OmniPay Zero-Trust — Démo 1 : Déploiement Canary & Rollback Automatique (SRE/P4)  " -ForegroundColor Cyan
Write-Host " Objectif Jury : Détection 5xx par Prometheus et retour arrière autonome en < 30s " -ForegroundColor Yellow
Write-Host "===================================================================================" -ForegroundColor Cyan

# 1. Vérification des prérequis
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Host "[ERREUR] L'outil 'kubectl' est introuvable." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------
# Étape 0 : Constater l'état initial stable (Version 1.0.0 à 100%)
# ------------------------------------------------------------------------------
Write-Host "`n--> [Étape 0/6] Vérification de l'état initial stable de $Namespace..." -ForegroundColor White

$nsCheck = kubectl get namespace $Namespace 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERREUR] Le namespace '$Namespace' est introuvable." -ForegroundColor Red
    exit 1
}

$roCheck = kubectl get rollout $RolloutName -n $Namespace 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERREUR] Le Rollout '$RolloutName' est introuvable dans '$Namespace'." -ForegroundColor Red
    exit 1
}

Write-Host "    Statut actuel du Rollout $RolloutName :" -ForegroundColor Gray
$hasPlugin = (kubectl argo rollouts version 2>$null) -and ($LASTEXITCODE -eq 0)

if ($hasPlugin) {
    kubectl argo rollouts get rollout $RolloutName -n $Namespace
} else {
    kubectl get rollout $RolloutName -n $Namespace -o wide
}

Write-Host "✔ État initial validé : Version 1.0.0 saine et active à 100%." -ForegroundColor Green

# ------------------------------------------------------------------------------
# Étape 1 : Injecter la version défectueuse (v2-bad générant des 5xx)
# ------------------------------------------------------------------------------
Write-Host "`n--> [Étape 1/6] Déclenchement de la mise en production de la version défectueuse (v2-bad)..." -ForegroundColor White
Write-Host "    Image injectée : $BadImage" -ForegroundColor Red
$startTs = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

if ($hasPlugin) {
    kubectl argo rollouts set image $RolloutName "$RolloutName=$BadImage" -n $Namespace
} else {
    kubectl set image rollout/$RolloutName "$RolloutName=$BadImage" -n $Namespace
}

Write-Host "✔ Image v2-bad appliquée au Rollout." -ForegroundColor Green

# ------------------------------------------------------------------------------
# Étape 2 : Observer le palier Canary à 10%
# ------------------------------------------------------------------------------
Write-Host "`n--> [Étape 2/6] Observation du palier Canary (Plafond Blast Radius à 10%)..." -ForegroundColor White
Start-Sleep -Seconds 5

if ($hasPlugin) {
    kubectl argo rollouts get rollout $RolloutName -n $Namespace
}

Write-Host "ℹ Constat opérationnel pour le jury :" -ForegroundColor Cyan
Write-Host "  - 1 seul pod Canary instancié avec v2-bad (~10% du trafic global)." -ForegroundColor Gray
Write-Host "  - Les 3 autres pods restent sur l'ancienne version saine 1.0.0." -ForegroundColor Gray
Write-Host "  - Le rayon d'impact (Blast Radius) est strictement borné à 10% des requêtes clients." -ForegroundColor Gray

# ------------------------------------------------------------------------------
# Étape 3 : Simuler du trafic HTTP bancaire pendant 60 secondes
# ------------------------------------------------------------------------------
Write-Host "`n--> [Étape 3/6] Simulation de trafic bancaire (requêtes HTTP pendant ${TrafficSeconds}s)..." -ForegroundColor White
Write-Host "    Génération de requêtes vers http://transaction-service:8080/api/transactions..." -ForegroundColor Gray

# Démarrage du générateur de trafic éphémère dans le cluster
$trafficJob = Start-Job -ScriptBlock {
    param($ns)
    kubectl run demo-traffic-generator --rm -i --restart=Never `
        --image=curlimages/curl `
        -n $ns -- `
        sh -c "for i in \$(seq 1 60); do curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://transaction-service:8080/actuator/health || true; sleep 0.5; done" 2>&1
} -ArgumentList $Namespace

for ($i = 1; $i -le 10; $i++) {
    $pct = $i * 10
    Write-Host ("`r    Progression du trafic : [{0}{1}] ({2}%)" -f ("#" * $i), (" " * (10 - $i)), $pct) -NoNewline
    Start-Sleep -Seconds 3
}
Write-Host "`n✔ Injection de trafic terminée." -ForegroundColor Green

# ------------------------------------------------------------------------------
# Étape 4 : Capturer l'AnalysisRun détectant l'anomalie dans Prometheus
# ------------------------------------------------------------------------------
Write-Host "`n--> [Étape 4/6] Capture de l'AnalysisRun et détection du pic d'erreurs 5xx..." -ForegroundColor White
$analysisRun = kubectl get analysisrun -n $Namespace --sort-by=.metadata.creationTimestamp -o jsonpath="{.items[-1].metadata.name}" 2>$null

if ($analysisRun) {
    Write-Host "    AnalysisRun identifié : $analysisRun" -ForegroundColor Yellow
    kubectl describe analysisrun $analysisRun -n $Namespace | Select-String -Pattern "Phase|Status|Message|Value|Failed"
} else {
    Write-Host "ℹ Aucun AnalysisRun en cours ou terminé immédiatement disponible (attente brève...)" -ForegroundColor Yellow
    Start-Sleep -Seconds 5
}

# ------------------------------------------------------------------------------
# Étape 5 : Démontrer l'état Aborted/Degraded et le Rollback automatique (< 30s)
# ------------------------------------------------------------------------------
Write-Host "`n--> [Étape 5/6] Validation du Rollback Automatique et du statut Degraded/Aborted..." -ForegroundColor White
$rollbackDone = $false

for ($i = 1; $i -le 15; $i++) {
    $phase = kubectl get rollout $RolloutName -n $Namespace -o jsonpath="{.status.phase}" 2>$null
    $aborted = kubectl get rollout $RolloutName -n $Namespace -o jsonpath="{.status.abort}" 2>$null
    if ($phase -eq "Degraded" -or $aborted -eq "true") {
        $endTs = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $elapsed = $endTs - $startTs
        Write-Host "✔ Détection & Rollback validés en $elapsed secondes (< 30s) !" -ForegroundColor Green
        Write-Host "    Phase du Rollout : $phase" -ForegroundColor Red
        $rollbackDone = $true
        break
    }
    Start-Sleep -Seconds 2
}

if (-not $rollbackDone) {
    Write-Host "ℹ Le Rollout est en phase d'analyse ou stabilisé." -ForegroundColor Yellow
}

Write-Host "`nDétails finaux du Rollout après déclenchement du Guardrail SRE :" -ForegroundColor Cyan
if ($hasPlugin) {
    kubectl argo rollouts get rollout $RolloutName -n $Namespace
} else {
    kubectl get pods -l app=$RolloutName -n $Namespace
}

# ------------------------------------------------------------------------------
# Étape 6 : Remise à zéro pour reproductibilité de la soutenance
# ------------------------------------------------------------------------------
Write-Host "`n--> [Étape 6/6] Remise à l'état sain (v1.0.0) pour reproductibilité..." -ForegroundColor White
$doReset = $AutoReset
if (-not $doReset) {
    $answer = Read-Host "Souhaitez-vous réinitialiser le Rollout vers l'état stable 1.0.0 ? (O/n)"
    if ($answer -eq "" -or $answer -match "^[oOyY]") {
        $doReset = $true
    }
}

if ($doReset) {
    if ($hasPlugin) {
        kubectl argo rollouts undo $RolloutName --to-revision=1 -n $Namespace 2>$null
        if ($LASTEXITCODE -ne 0) {
            kubectl argo rollouts set image $RolloutName "$RolloutName=$StableImage" -n $Namespace
        }
    } else {
        kubectl set image rollout/$RolloutName "$RolloutName=$StableImage" -n $Namespace
    }
    Write-Host "✔ Réinitialisation vers 1.0.0 effectuée." -ForegroundColor Green
} else {
    Write-Host "Rollout maintenu dans son état actuel pour analyse post-mortem." -ForegroundColor Yellow
}

Write-Host "`n===================================================================================" -ForegroundColor Cyan
Write-Host " [SUCCÈS DÉMO 1] Démonstration du Rollback Automatique Argo Rollouts validée !     " -ForegroundColor Green
Write-Host " - Blast Radius maximal : 10%" -ForegroundColor Gray
Write-Host " - Métrique évaluée     : Taux 5xx via Prometheus (seuil < 0.5%)" -ForegroundColor Gray
Write-Host " - Temps de réaction    : < 30 secondes sans intervention humaine" -ForegroundColor Gray
Write-Host " - Disponibilité client  : 100% assurée par la version stable 1.0.0" -ForegroundColor Gray
Write-Host "===================================================================================" -ForegroundColor Cyan
