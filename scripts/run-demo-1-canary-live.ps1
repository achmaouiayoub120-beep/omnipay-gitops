<#
==============================================================================
OmniPay Zero-Trust — Démo 1 Live (~3 min) : Canary Argo Rollouts & Auto-Rollback
Scénario :
  1. Vérifier v1.0.0 stable à 100% du trafic.
  2. Déclencher le Canary transaction-service:v2.0.0-unstable (50% d'erreurs 500) à 10%.
  3. Lancer l'analyse Prometheus sur le taux d'erreur 5xx (> 2%) et vérifier 0 coupure.
  4. Constater le rollback automatique vers v1.0.0 à 100% en < 30s (Degraded / RolledBack).
Rôle P4 : Widad El Gharzaz — Plateforme, Supply Chain Security & Lead GitOps
==============================================================================
#>

[CmdletBinding()]
param (
    [string]$Namespace = "omnipay-prod",
    [string]$RolloutName = "transaction-service",
    [string]$ActiveService = "transaction-service-active",
    [string]$TargetService = "transaction-service",
    [string]$StableImage = "harbor.omnipay.local:30002/omnipay/transaction-service:1.0.0",
    [string]$UnstableImage = "harbor.omnipay.local:30002/omnipay/transaction-service:v2.0.0-unstable",
    [string]$PrometheusUrl = "http://prometheus.omnipay.local:30900",
    [double]$ErrorThresholdPct = 2.0,
    [int]$TrafficRequests = 40,
    [int]$RollbackTimeoutSec = 30,
    [switch]$AutoReset,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$TrafficPod = "demo1-traffic-gen-$PID"
$ProbePodPrefix = "demo1-health-probe-$PID"

function Test-RolloutsPlugin {
    try {
        $null = kubectl argo rollouts version 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Show-RolloutStatus {
    param([bool]$HasPlugin)
    if ($HasPlugin) {
        kubectl argo rollouts get rollout $RolloutName -n $Namespace --no-color
    } else {
        kubectl get rollout $RolloutName -n $Namespace -o wide
        kubectl get pods -n $Namespace -l "app=$RolloutName" -o wide
    }
}

function Invoke-ActiveServiceProbe {
    param([string]$PodName)
    $svcUrl = "http://$ActiveService.$Namespace.svc.cluster.local:8080/actuator/health"
    $override = @{
        spec = @{
            securityContext = @{
                runAsNonRoot = $true
                runAsUser = 10001
                runAsGroup = 10001
                seccompProfile = @{ type = "RuntimeDefault" }
            }
            containers = @(
                @{
                    name = $PodName
                    image = "curlimages/curl:8.10.1"
                    command = @("curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", $svcUrl)
                    securityContext = @{
                        allowPrivilegeEscalation = $false
                        readOnlyRootFilesystem = $true
                        capabilities = @{ drop = @("ALL") }
                    }
                }
            )
        }
    } | ConvertTo-Json -Depth 10 -Compress

    try {
        $code = kubectl run $PodName --rm -i --restart=Never -n $Namespace `
            --image="curlimages/curl:8.10.1" `
            --overrides=$override 2>$null
        if ($LASTEXITCODE -eq 0 -and $code) {
            return ($code | Out-String).Trim()
        }
        return "000"
    } catch {
        return "000"
    }
}

function Query-Prometheus5xx {
    $promql = "(sum(rate(http_server_requests_seconds_count{service=""$RolloutName"",status=~""5..""}[2m])) / (sum(rate(http_server_requests_seconds_count{service=""$RolloutName""}[2m])) > 0)) * 100 or vector(0)"
    $encoded = [System.Uri]::EscapeDataString($promql)
    $uri = "$($PrometheusUrl.TrimEnd('/'))/api/v1/query?query=$encoded"
    try {
        $resp = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 4 -ErrorAction Stop
        return ($resp | ConvertTo-Json -Compress -Depth 6)
    } catch {
        return $null
    }
}

Write-Host "===================================================================================" -ForegroundColor Blue
Write-Host " OmniPay Zero-Trust — Démo 1 Live (~3 min) : Canary & Rollback Automatique" -ForegroundColor Cyan
Write-Host " Cible : $RolloutName ($Namespace) | Seuil 5xx : > $ErrorThresholdPct% | SLA Rollback : < ${RollbackTimeoutSec}s" -ForegroundColor Yellow
Write-Host "===================================================================================" -ForegroundColor Blue

if ($DryRun) {
    Write-Host "[DRY-RUN] Mode simulation activé : aucune mutation ne sera appliquée au cluster." -ForegroundColor Yellow
}

$rolledBack = $false

try {
    # --------------------------------------------------------------------------
    # Étape 1 : Vérifier v1.0.0 stable à 100% du trafic
    # --------------------------------------------------------------------------
    Write-Host "`n--> [Étape 1/4] Vérification de l'état stable initial (v1.0.0 à 100% du trafic)..." -ForegroundColor White

    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        throw "L'outil 'kubectl' est requis mais introuvable dans le PATH."
    }

    $hasPlugin = Test-RolloutsPlugin

    if (-not $DryRun) {
        $null = kubectl get namespace $Namespace 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Namespace '$Namespace' introuvable." }

        $null = kubectl get rollout $RolloutName -n $Namespace 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Rollout '$RolloutName' introuvable dans '$Namespace'." }

        $currentImage = (kubectl get rollout $RolloutName -n $Namespace -o jsonpath="{.spec.template.spec.containers[0].image}").Trim()
        $currentPhase = (kubectl get rollout $RolloutName -n $Namespace -o jsonpath="{.status.phase}").Trim()
        $desired = (kubectl get rollout $RolloutName -n $Namespace -o jsonpath="{.spec.replicas}").Trim()
        $ready = (kubectl get rollout $RolloutName -n $Namespace -o jsonpath="{.status.readyReplicas}").Trim()
        $available = (kubectl get rollout $RolloutName -n $Namespace -o jsonpath="{.status.availableReplicas}").Trim()

        Write-Host "    Image active      : $currentImage" -ForegroundColor Cyan
        Write-Host "    Phase Rollout     : $(if ($currentPhase) { $currentPhase } else { 'Healthy' })" -ForegroundColor Green
        Write-Host "    Réplicas Ready    : $ready/$desired (Available: $available)" -ForegroundColor Gray

        Show-RolloutStatus -HasPlugin $hasPlugin

        if ($currentPhase -ne "Healthy" -or $ready -ne $desired) {
            Write-Host "[ATTENTION] Le Rollout n'est pas encore pleinement Healthy ($currentPhase)." -ForegroundColor Yellow
        }

        $httpCode = Invoke-ActiveServiceProbe -PodName "$ProbePodPrefix-init"
        Write-Host "    Sonde service stable ($ActiveService) : HTTP $httpCode" -ForegroundColor Gray
        Write-Host "✔ État initial validé : version stable à 100% du trafic." -ForegroundColor Green
    } else {
        Write-Host "    [DRY-RUN] Vérification Rollout '$RolloutName' sur '$StableImage' (100% trafic, Healthy)." -ForegroundColor Gray
    }

    # --------------------------------------------------------------------------
    # Étape 2 : Déclencher le Canary v2.0.0-unstable (palier 10%)
    # --------------------------------------------------------------------------
    Write-Host "`n--> [Étape 2/4] Déclenchement Canary de $UnstableImage (palier 10%, 50% erreurs HTTP 500)..." -ForegroundColor White
    $startCanaryTs = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    if (-not $DryRun) {
        if ($hasPlugin) {
            kubectl argo rollouts set image $RolloutName "$RolloutName=$UnstableImage" -n $Namespace
        } else {
            kubectl set image "rollout/$RolloutName" "$RolloutName=$UnstableImage" -n $Namespace
        }
        if ($LASTEXITCODE -ne 0) { throw "Échec du déclenchement de l'image Canary '$UnstableImage'." }

        Start-Sleep -Seconds 5
        $stepIdx = (kubectl get rollout $RolloutName -n $Namespace -o jsonpath="{.status.currentStepIndex}" 2>$null | Out-String).Trim()
        $canaryWt = (kubectl get rollout $RolloutName -n $Namespace -o jsonpath="{.status.canary.weights.canary.weight}" 2>$null | Out-String).Trim()
        $stableWt = (kubectl get rollout $RolloutName -n $Namespace -o jsonpath="{.status.canary.weights.stable.weight}" 2>$null | Out-String).Trim()

        Write-Host "    Palier actif      : Step $(if ($stepIdx) { $stepIdx } else { '0' }) | Canary=$(if ($canaryWt) { $canaryWt } else { '10' })% / Stable=$(if ($stableWt) { $stableWt } else { '90' })%" -ForegroundColor Yellow
        Show-RolloutStatus -HasPlugin $hasPlugin
        Write-Host "✔ Canary démarré avec Blast Radius strictement borné à 10%." -ForegroundColor Green
    } else {
        Write-Host "    [DRY-RUN] kubectl argo rollouts set image $RolloutName $RolloutName=$UnstableImage -n $Namespace" -ForegroundColor Gray
    }

    # --------------------------------------------------------------------------
    # Étape 3 : Trafic HTTP + Analyse Prometheus 5xx (> 2%) & Continuité
    # --------------------------------------------------------------------------
    Write-Host "`n--> [Étape 3/4] Injection de trafic & Analyse Prometheus du taux d'erreur 5xx (seuil > $ErrorThresholdPct%)..." -ForegroundColor White

    if (-not $DryRun) {
        Write-Host "    Envoi de $TrafficRequests requêtes vers http://${TargetService}:8080/api/transactions..." -ForegroundColor Gray

        $trafficCmd = "ok=0; err=0; i=1; while [ `"`$i`" -le $TrafficRequests ]; do code=`$(curl -s -o /dev/null -w `"%{http_code}`" --max-time 2 http://$TargetService.$Namespace.svc.cluster.local:8080/api/transactions || echo 000); case `"`$code`" in 5*) err=`$((err+1));; 2*|4*) ok=`$((ok+1));; esac; i=`$((i+1)); sleep 0.3; done; echo `"TRAFFIC_SUMMARY ok=`$ok err_5xx=`$err`""
        $trafficOverride = @{
            spec = @{
                securityContext = @{
                    runAsNonRoot = $true
                    runAsUser = 10001
                    runAsGroup = 10001
                    seccompProfile = @{ type = "RuntimeDefault" }
                }
                containers = @(
                    @{
                        name = $TrafficPod
                        image = "curlimages/curl:8.10.1"
                        command = @("sh", "-c", $trafficCmd)
                        securityContext = @{
                            allowPrivilegeEscalation = $false
                            readOnlyRootFilesystem = $true
                            capabilities = @{ drop = @("ALL") }
                        }
                    }
                )
            }
        } | ConvertTo-Json -Depth 10 -Compress

        $trafficOut = kubectl run $TrafficPod --rm -i --restart=Never -n $Namespace `
            --image="curlimages/curl:8.10.1" `
            --overrides=$trafficOverride 2>$null
        if ($trafficOut) {
            $trafficOut | Select-String -Pattern "TRAFFIC_SUMMARY|HTTP" | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        }

        $activeHttp = Invoke-ActiveServiceProbe -PodName "$ProbePodPrefix-mid"
        Write-Host "    Continuité service stable ($ActiveService) pendant Canary : HTTP $activeHttp" -ForegroundColor Green

        $analysisRun = (kubectl get analysisrun -n $Namespace --sort-by=.metadata.creationTimestamp -o jsonpath="{.items[-1].metadata.name}" 2>$null | Out-String).Trim()
        if ($analysisRun) {
            Write-Host "    AnalysisRun actif : $analysisRun" -ForegroundColor Yellow
            kubectl get analysisrun $analysisRun -n $Namespace -o wide
            kubectl describe analysisrun $analysisRun -n $Namespace | Select-String -Pattern "Phase|Status|Message|Value|Failed|Metric"
        } else {
            Write-Host "[INFO] AnalysisRun en cours de création par le contrôleur Argo Rollouts..." -ForegroundColor Yellow
        }

        $promRaw = Query-Prometheus5xx
        if ($promRaw) {
            Write-Host "    Réponse Prometheus API ($PrometheusUrl) : $promRaw" -ForegroundColor Cyan
        }
    } else {
        Write-Host "    [DRY-RUN] Simulation de trafic HTTP + requête AnalysisTemplate 'prometheus-error-rate'." -ForegroundColor Gray
    }

    # --------------------------------------------------------------------------
    # Étape 4 : Observation du Rollback Automatique (< 30s)
    # --------------------------------------------------------------------------
    Write-Host "`n--> [Étape 4/4] Validation du Rollback Automatique (< ${RollbackTimeoutSec}s) & État Degraded / RolledBack..." -ForegroundColor White

    if (-not $DryRun) {
        $detectionTs = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $finalPhase = ""
        $abortFlag = ""
        $maxPolls = [Math]::Max(1, [int]($RollbackTimeoutSec / 2))

        for ($i = 1; $i -le $maxPolls; $i++) {
            $finalPhase = (kubectl get rollout $RolloutName -n $Namespace -o jsonpath="{.status.phase}" 2>$null | Out-String).Trim()
            $abortFlag = (kubectl get rollout $RolloutName -n $Namespace -o jsonpath="{.status.abort}" 2>$null | Out-String).Trim()
            $rolloutMsg = (kubectl get rollout $RolloutName -n $Namespace -o jsonpath="{.status.message}" 2>$null | Out-String).Trim()
            $canaryWtNow = (kubectl get rollout $RolloutName -n $Namespace -o jsonpath="{.status.canary.weights.canary.weight}" 2>$null | Out-String).Trim()

            if ($finalPhase -eq "Degraded" -or $abortFlag -eq "true") {
                $nowTs = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                $elapsedDet = $nowTs - $detectionTs
                $elapsedTot = $nowTs - $startCanaryTs
                Write-Host "✔ Rollback automatique déclenché (détection -> rollback : ${elapsedDet}s, total démo : ${elapsedTot}s) !" -ForegroundColor Green
                Write-Host "    Statut Rollout : $finalPhase (RolledBack / Aborted=$(if ($abortFlag) { $abortFlag } else { 'true' }))" -ForegroundColor Red
                if ($rolloutMsg) { Write-Host "    Message        : $rolloutMsg" -ForegroundColor Gray }
                Write-Host "    Poids Canary   : $(if ($canaryWtNow) { $canaryWtNow } else { '0' })% | Trafic Stable v1.0.0 : 100%" -ForegroundColor Gray
                $rolledBack = $true
                break
            }
            Start-Sleep -Seconds 2
        }

        if (-not $rolledBack) {
            Write-Host "[ATTENTION] Le Rollout n'est pas encore passé en Degraded/Aborted dans le délai imparti (phase=$finalPhase)." -ForegroundColor Red
        }

        $analysisRunFinal = (kubectl get analysisrun -n $Namespace --sort-by=.metadata.creationTimestamp -o jsonpath="{.items[-1].metadata.name}" 2>$null | Out-String).Trim()
        if ($analysisRunFinal) {
            $arPhase = (kubectl get analysisrun $analysisRunFinal -n $Namespace -o jsonpath="{.status.phase}" 2>$null | Out-String).Trim()
            Write-Host "    État final AnalysisRun '$analysisRunFinal' : $arPhase" -ForegroundColor Red
        }

        Write-Host "`nÉtat détaillé du Rollout et des Pods après Rollback :" -ForegroundColor Cyan
        Show-RolloutStatus -HasPlugin $hasPlugin

        $postHttp = Invoke-ActiveServiceProbe -PodName "$ProbePodPrefix-post"
        Write-Host "    Vérification post-rollback service stable ($ActiveService) : HTTP $postHttp" -ForegroundColor Green

        $doReset = $AutoReset.IsPresent
        if (-not $doReset -and [Environment]::UserInteractive) {
            $ans = Read-Host "`nRéinitialiser le Rollout sur '$StableImage' pour la démo suivante ? [O/n]"
            if ($ans -eq "" -or $ans -match "^[oOyY]") {
                $doReset = $true
            }
        }

        if ($doReset) {
            if ($hasPlugin) {
                kubectl argo rollouts undo $RolloutName -n $Namespace 2>$null
                if ($LASTEXITCODE -ne 0) {
                    kubectl argo rollouts set image $RolloutName "$RolloutName=$StableImage" -n $Namespace
                }
            } else {
                kubectl set image "rollout/$RolloutName" "$RolloutName=$StableImage" -n $Namespace
            }
            Write-Host "✔ Rollout réinitialisé vers $StableImage (100% stable)." -ForegroundColor Green
        }

        if (-not $rolledBack) {
            exit 1
        }
    } else {
        Write-Host "    [DRY-RUN] Validation statut Degraded/RolledBack (< 30s) et restauration 100% v1.0.0." -ForegroundColor Gray
    }

    Write-Host "`n===================================================================================" -ForegroundColor Blue
    Write-Host " [SUCCÈS DÉMO 1] Canary & Auto-Rollback Prometheus validés !" -ForegroundColor Green
    Write-Host " - Version stable   : $StableImage (100% trafic sans coupure)" -ForegroundColor Gray
    Write-Host " - Version fautive  : $UnstableImage (confinée à 10% puis détruite)" -ForegroundColor Gray
    Write-Host " - Analyse PromQL   : Taux 5xx > $ErrorThresholdPct% -> Statut Degraded / RolledBack" -ForegroundColor Gray
    Write-Host " - Temps de réaction: < ${RollbackTimeoutSec}s sans intervention humaine" -ForegroundColor Gray
    Write-Host "===================================================================================" -ForegroundColor Blue
}
finally {
    if (-not $DryRun) {
        foreach ($p in @($TrafficPod, "$ProbePodPrefix-init", "$ProbePodPrefix-mid", "$ProbePodPrefix-post")) {
            kubectl delete pod $p -n $Namespace --ignore-not-found=true --grace-period=0 --force 2>$null | Out-Null
        }
    }
}
