<#
=============================================================================
install-tempo.ps1 — OmniPay Zero-Trust | P5 Semaine 3 (S3)
Déploiement reproductible de Grafana Tempo sur cluster K3s (Windows PowerShell)
=============================================================================
#>
[CmdletBinding()]
param(
    [string]$Namespace = "monitoring",
    [string]$ReleaseName = "tempo",
    [string]$ChartVersion = "1.10.3"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$valuesFile = Join-Path $scriptDir "values-tempo.yaml"
$datasourceFile = Join-Path $scriptDir "datasource-tempo.yaml"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  OmniPay Zero-Trust — Déploiement Tracing Tempo (S3 P5)   " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# --- 1. Vérification des prérequis ---
Write-Host "[1/5] Vérification des outils requis (helm, kubectl)..." -ForegroundColor Yellow
if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    throw "ERREUR: helm est requis mais introuvable dans le PATH."
}
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw "ERREUR: kubectl est requis mais introuvable dans le PATH."
}
& kubectl cluster-info | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "ERREUR: Impossible de joindre le cluster K3s."
}
Write-Host "  ✅ Prérequis validés." -ForegroundColor Green

# --- 2. Dépôt Helm Grafana ---
Write-Host "[2/5] Mise à jour du dépôt Helm Grafana..." -ForegroundColor Yellow
& helm repo add grafana https://grafana.github.io/helm-charts 2>$null
& helm repo update grafana
Write-Host "  ✅ Dépôt Grafana prêt." -ForegroundColor Green

# --- 3. Namespace monitoring ---
Write-Host "[3/5] Vérification du namespace $Namespace..." -ForegroundColor Yellow
& kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f - | Out-Null
Write-Host "  ✅ Namespace $Namespace prêt." -ForegroundColor Green

# --- 4. Déploiement Tempo ---
Write-Host "[4/5] Déploiement / Mise à jour de Grafana Tempo..." -ForegroundColor Yellow
$helmStatus = & helm status $ReleaseName -n $Namespace 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ♻️  Release '$ReleaseName' existante — mise à niveau (helm upgrade)..." -ForegroundColor Cyan
    & helm upgrade $ReleaseName grafana/tempo `
        --namespace $Namespace `
        --version $ChartVersion `
        --values $valuesFile `
        --timeout 5m `
        --atomic
} else {
    Write-Host "  🆕 Installation initiale de '$ReleaseName'..." -ForegroundColor Cyan
    & helm install $ReleaseName grafana/tempo `
        --namespace $Namespace `
        --version $ChartVersion `
        --values $valuesFile `
        --timeout 5m `
        --atomic
}

if (Test-Path $datasourceFile) {
    Write-Host "  🔗 Application de la ConfigMap datasource Tempo pour Grafana..." -ForegroundColor Cyan
    & kubectl apply -f $datasourceFile -n $Namespace | Out-Null
}

# --- 5. Attente des pods ---
Write-Host "[5/5] Attente de la disponibilité opérationnelle du pod Tempo..." -ForegroundColor Yellow
& kubectl wait --for=condition=ready pod -n $Namespace -l "app.kubernetes.io/name=tempo" --timeout=180s

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  ✅ Grafana Tempo déployé avec succès !" -ForegroundColor Green
Write-Host ""
Write-Host "  Endpoints internes du cluster :" -ForegroundColor White
Write-Host "    - OTLP gRPC : tempo.${Namespace}.svc.cluster.local:4317" -ForegroundColor Gray
Write-Host "    - OTLP HTTP : http://tempo.${Namespace}.svc.cluster.local:4318/v1/traces" -ForegroundColor Gray
Write-Host "    - Jaeger    : tempo.${Namespace}.svc.cluster.local:14268" -ForegroundColor Gray
Write-Host "    - Tempo API : http://tempo.${Namespace}.svc.cluster.local:3100" -ForegroundColor Gray
Write-Host "============================================================" -ForegroundColor Green
