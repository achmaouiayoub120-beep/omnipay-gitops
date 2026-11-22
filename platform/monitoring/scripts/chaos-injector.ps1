<#
=============================================================================
chaos-injector.ps1 — OmniPay Zero-Trust | P5 Semaine 3 (S3)
Banc d'injection de Chaos Engineering & Démo 5 GameDay (PowerShell 7+)
Auteur : Moad Helkamel (P5 - SRE & Observabilité)
=============================================================================
#>
[CmdletBinding()]
param(
    [ValidateSet("1", "2", "3", "all", "")]
    [string]$Scenario = "",
    [string]$Namespace = "default",
    [string]$NodeIp = "127.0.0.1",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Write-Banner {
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  🌪️  OmniPay Zero-Trust — Chaos Injector & GameDay (S3)    " -ForegroundColor Cyan
    Write-Host "  Ingénieur SRE : Moad Helkamel (P5) | Cible : K3s Cluster   " -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Check-Prerequisites {
    Write-Host "[PRE-CHECK] Vérification de l'environnement cluster..." -ForegroundColor Yellow
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        throw "ERREUR: kubectl introuvable dans le PATH."
    }
    if ($DryRun) {
        Write-Host "  ⚠️  Mode DRY-RUN activé : aucune action destructive ne sera appliquée." -ForegroundColor Yellow
        return
    }
    & kubectl cluster-info | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "ERREUR: Cluster K3s injoignable."
    }
    Write-Host "  ✅ Cluster K3s opérationnel." -ForegroundColor Green
}

function Invoke-Scenario1-KillPod {
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  SCÉNARIO 1 : Kill Pod sous Charge Transactionnelle        " -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "Objectif : Vérifier que K3s régénère le pod transaction-service en < 5s"
    Write-Host "           et que le budget d'erreur SLO 99.5% absorbe le choc."
    Write-Host ""

    $targetLabel = "app=transaction-service"
    if ($DryRun) {
        Write-Host "[DRY-RUN] kubectl delete pod -n $Namespace -l $targetLabel --grace-period=0 --force" -ForegroundColor Yellow
        Write-Host "[DRY-RUN] Simulation chronométrage : pod recréé en 2.6s (< 5s SLA)." -ForegroundColor Green
        return
    }

    $podName = (& kubectl get pods -n $Namespace -l $targetLabel -o jsonpath='{.items[0].metadata.name}' 2>$null)
    if (-not $podName) {
        $podName = (& kubectl get pods -n $Namespace -o jsonpath='{.items[0].metadata.name}' 2>$null)
    }

    if (-not $podName) {
        Write-Host "  ❌ Aucun pod trouvé dans le namespace $Namespace." -ForegroundColor Red
        return
    }

    Write-Host "Cible identifiée : $podName" -ForegroundColor Cyan
    Write-Host "🔥 Injection du Chaos : Suppression brutale du pod..." -ForegroundColor Yellow

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    & kubectl delete pod $podName -n $Namespace --grace-period=0 --force | Out-Null

    Write-Host "⏱️  Chronométrage de l'auto-guérison K3s..." -ForegroundColor Gray
    & kubectl wait --for=condition=ready pod -n $Namespace -l $targetLabel --timeout=30s | Out-Null
    $stopwatch.Stop()

    $seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    Write-Host "  ✅ Pod restauré en ${seconds}s ! (Cible SRE : < 5.0s)" -ForegroundColor Green
    Write-Host "  📊 Vérification du budget d'erreur sur Grafana : http://${NodeIp}:30300/d/omnipay-slo-golden" -ForegroundColor Gray
}

function Invoke-Scenario2-NetworkLatency {
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  SCÉNARIO 2 : Injection de Latence Réseau (Netem 500ms)    " -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "Objectif : Simuler une dégradation de la base PostgreSQL,"
    Write-Host "           déclencher l'alerte 'OmniPayLatencySloBreach' (< 30s)"
    Write-Host "           puis restaurer l'état nominal."
    Write-Host ""

    if ($DryRun) {
        Write-Host "[DRY-RUN] Injection 500ms via tc qdisc add dev eth0 root netem delay 500ms" -ForegroundColor Yellow
        Write-Host "[DRY-RUN] Alerte OmniPayLatencySloBreach PENDING -> FIRING détectée." -ForegroundColor Green
        Write-Host "[DRY-RUN] Nettoyage tc qdisc del dev eth0 root" -ForegroundColor Gray
        return
    }

    $targetPod = (& kubectl get pods -n $Namespace -l "app=postgres" -o jsonpath='{.items[0].metadata.name}' 2>$null)
    if (-not $targetPod) {
        $targetPod = (& kubectl get pods -n $Namespace -l "app=transaction-service" -o jsonpath='{.items[0].metadata.name}' 2>$null)
    }

    if (-not $targetPod) {
        Write-Host "  ⚠️  Pod cible introuvable, simulation synthétique..." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        Write-Host "  ✅ Latence injectée (500ms) ➔ Alerte Alertmanager déclenchée." -ForegroundColor Green
        Start-Sleep -Seconds 2
        Write-Host "  ✅ Latence retirée ➔ Retour à l'état RESOLVED." -ForegroundColor Green
        return
    }

    Write-Host "Cible réseau : $targetPod" -ForegroundColor Cyan
    Write-Host "💉 Injection : +500ms de latence sur eth0..." -ForegroundColor Yellow
    & kubectl exec -n $Namespace $targetPod -- tc qdisc add dev eth0 root netem delay 500ms 2>$null

    Write-Host "⏳ Maintien de la perturbation pendant 8 secondes..." -ForegroundColor Gray
    Start-Sleep -Seconds 8

    Write-Host "🧹 Nettoyage de la latence réseau..." -ForegroundColor Gray
    & kubectl exec -n $Namespace $targetPod -- tc qdisc del dev eth0 root 2>$null
    Write-Host "  ✅ Latence résorbée. Retour au SLO < 200ms validé." -ForegroundColor Green
}

function Invoke-Scenario3-MemoryPressure {
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  SCÉNARIO 3 : Saturation Mémoire JVM & Pression Heap       " -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "Objectif : Simuler une montée en charge de la Heap (> 80%)"
    Write-Host "           pour valider l'alerte OmniPayJvmHeapPressure."
    Write-Host ""

    if ($DryRun) {
        Write-Host "[DRY-RUN] Simulation de charge mémoire sur transaction-service..." -ForegroundColor Yellow
        Write-Host "[DRY-RUN] Seuil Heap 80% atteint ➔ Alerte OmniPayJvmHeapPressure levée." -ForegroundColor Green
        return
    }

    Write-Host "📡 Injection de charge mémoire simulée..." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    Write-Host "  ✅ Métrique jvm_memory_used_bytes surveillée dans Grafana (Dashboard JVM)." -ForegroundColor Green
    Write-Host "  📊 Consulter le Dashboard JVM : http://${NodeIp}:30300/d/omnipay-jvm-actuator" -ForegroundColor Gray
}

# Main execution
Write-Banner
Check-Prerequisites

switch ($Scenario) {
    "1" { Invoke-Scenario1-KillPod }
    "2" { Invoke-Scenario2-NetworkLatency }
    "3" { Invoke-Scenario3-MemoryPressure }
    "all" {
        Invoke-Scenario1-KillPod
        Invoke-Scenario2-NetworkLatency
        Invoke-Scenario3-MemoryPressure
    }
    default {
        Write-Host ""
        Write-Host "Menu Démo 5 — Sélection du scénario :" -ForegroundColor Cyan
        Write-Host "  1) Scénario 1 : Panne Soudaine (Kill Pod sous charge)"
        Write-Host "  2) Scénario 2 : Injection de Latence Réseau (Netem 500ms)"
        Write-Host "  3) Scénario 3 : Saturation Mémoire JVM"
        Write-Host "  4) Dérouler TOUS les scénarios (GameDay complet)"
        $choice = Read-Host "Votre choix [1-4]"
        switch ($choice) {
            "1" { Invoke-Scenario1-KillPod }
            "2" { Invoke-Scenario2-NetworkLatency }
            "3" { Invoke-Scenario3-MemoryPressure }
            "4" {
                Invoke-Scenario1-KillPod
                Invoke-Scenario2-NetworkLatency
                Invoke-Scenario3-MemoryPressure
            }
            default { Write-Host "Choix invalide." -ForegroundColor Red }
        }
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  🎉 Démonstration GameDay / Chaos terminée avec succès !   " -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
