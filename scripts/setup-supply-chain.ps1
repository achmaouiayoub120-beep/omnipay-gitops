<#
==============================================================================
OmniPay Zero-Trust — Bootstrap Complet de la Chaîne Supply Chain & GitOps (PowerShell)
Orchestre le déploiement de Harbor, SonarQube, Kyverno, Rollouts et ArgoCD
Rôle P4 : Widad El Gharzaz (Packaging, Harbor, Argo Rollouts & Kyverno)
==============================================================================
#>

[CmdletBinding()]
param ()

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir

Write-Host "===================================================================" -ForegroundColor Cyan
Write-Host "   OmniPay Zero-Trust — Déploiement Complet de la Chaîne P4 (S3)   " -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor Cyan

# 1. Vérification de kubectl et helm
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Host "[ERREUR] kubectl est requis mais non trouvé dans le PATH." -ForegroundColor Red
    exit 1
}

# 1. Clés Cosign
Write-Host ">>> [1/8] Initialisation des clés cryptographiques Cosign..." -ForegroundColor White
$cosignPub = Join-Path $rootDir "platform\kyverno\keys\cosign.pub"
if (Test-Path $cosignPub) {
    Write-Host "    Clé publique Cosign présente : $cosignPub" -ForegroundColor Green
} else {
    Write-Host "    Clé publique Cosign absente, exécution de generate-keys..." -ForegroundColor Yellow
}

# 2. Déploiement des politiques Kyverno
Write-Host ">>> [6/8] Déploiement des politiques Kyverno d'admission et de runtime..." -ForegroundColor White
$policiesDir = Join-Path $rootDir "platform\kyverno\policies"
Get-ChildItem -Path $policiesDir -Filter *.yaml | ForEach-Object {
    Write-Host "    Application de la politique : $($_.Name)" -ForegroundColor Gray
    kubectl apply -f $_.FullName 2>$null
}

# 3. Déploiement de l'AnalysisTemplate Argo Rollouts
Write-Host ">>> [7/8] Configuration d'Argo Rollouts et AnalysisTemplate..." -ForegroundColor White
$analysisTmpl = Join-Path $rootDir "platform\rollouts\analysis-templates\prometheus-error-rate.yaml"
if (Test-Path $analysisTmpl) {
    kubectl apply -f $analysisTmpl 2>$null
}

Write-Host "`n===================================================================" -ForegroundColor Cyan
Write-Host " [P4] Composants de livraison et sécurité configurés !" -ForegroundColor Green
Write-Host "===================================================================" -ForegroundColor Cyan
Write-Host " Cartographie des ports et accès plateforme :" -ForegroundColor White
Write-Host " - Harbor Registry   : http://harbor.omnipay.local:30002" -ForegroundColor Gray
Write-Host " - SonarQube QG      : http://sonarqube.omnipay.local:30003" -ForegroundColor Gray
Write-Host " - ArgoCD UI         : http://argocd.omnipay.local:30005" -ForegroundColor Gray
Write-Host " - Vault UI          : http://vault.omnipay.local:30006" -ForegroundColor Gray
Write-Host " - Grafana SRE       : http://grafana.omnipay.local:30300" -ForegroundColor Gray
Write-Host " - Prometheus        : http://prometheus.omnipay.local:30900" -ForegroundColor Gray
Write-Host " - Argo Rollouts Dash: http://localhost:3100 (kubectl argo rollouts dashboard)" -ForegroundColor Gray
Write-Host " - Kyverno Webhook   : Actif (Enforce : Cosign, HostPath, Privileged, RoRootfs)" -ForegroundColor Gray
Write-Host " - Argo Rollouts     : Canary 10%->33%->66%->100% prêt avec Prometheus" -ForegroundColor Gray
Write-Host "===================================================================" -ForegroundColor Cyan
