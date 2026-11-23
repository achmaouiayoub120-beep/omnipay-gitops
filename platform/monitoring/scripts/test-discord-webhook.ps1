<#
=============================================================================
test-discord-webhook.ps1 — OmniPay Zero-Trust | P5 Semaine 3 (S3)
Test d'envoi de cartes d'incident professionnelles vers Discord (PowerShell 7+)
Usage : .\test-discord-webhook.ps1 [-WebhookUrl <URL>] [-NodeIp <IP>]
=============================================================================
#>
[CmdletBinding()]
param(
    [string]$WebhookUrl = $env:DISCORD_WEBHOOK_URL,
    [string]$NodeIp = "127.0.0.1"
)

$ErrorActionPreference = "Stop"

if (-not $WebhookUrl) {
    $WebhookUrl = "WEBHOOK_URL_PLACEHOLDER"
}

$timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  OmniPay SRE — Test Webhook Alertmanager & Discord (S3)    " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

if ($WebhookUrl -eq "WEBHOOK_URL_PLACEHOLDER") {
    Write-Host "⚠️  NOTE ZERO-TRUST : Aucun webhook réel spécifié." -ForegroundColor Yellow
    Write-Host "    Usage : .\test-discord-webhook.ps1 -WebhookUrl https://discord.com/api/webhooks/<ID>/<TOKEN>" -ForegroundColor Gray
    Write-Host "    Validation de la génération du payload JSON synthétique (Dry-Run)..." -ForegroundColor Yellow
}

$payloadFiring = @{
    username = "OmniPay SRE Alertmanager"
    avatar_url = "https://raw.githubusercontent.com/prometheus/prometheus/main/documentation/images/prometheus-logo.png"
    content = "🚨 **[INCIDENT EN COURS] Notification prioritaire P5 — Fiabilité Plateforme**"
    embeds = @(
        @{
            title = "🚨 [ALERTE SRE OMNIPAY] OmniPayBurnRateCritical (CRITICAL)"
            description = "Le budget d'erreur de la plateforme bancaire se consume à vitesse critique ! Risque imminent de rupture du SLA 99.5%."
            color = 15158332 # Red
            fields = @(
                @{ name = "🏦 Service impacté"; value = "`transaction-service`"; inline = $true },
                @{ name = "🏷️ Namespace"; value = "`default`"; inline = $true },
                @{ name = "🔥 Vitesse de consommation (Burn Rate)"; value = "**14.5x** (> 2% du budget en 1h)"; inline = $true },
                @{ name = "📉 Budget d'erreur restant"; value = "**12.4%** (Seuil critique < 20%)"; inline = $true },
                @{ name = "⏱️ Latence P95 actuelle"; value = "`385ms` (SLO max: 200ms)"; inline = $true },
                @{ name = "🎯 Objectif de Service (SLO)"; value = "99.5% disponibilité sur 30 jours"; inline = $true },
                @{ name = "📊 Dashboard Grafana"; value = "[Accéder au Dashboard SLO](http://${NodeIp}:30300/d/omnipay-slo-golden)"; inline = $false },
                @{ name = "📖 Runbook d'intervention"; value = "[Runbook SLO Breach](https://github.com/achmaouiayoub120-beep/omnipay-gitops/blob/main/demos/demo-5-gameday-slo.md)"; inline = $false }
            )
            footer = @{ text = "OmniPay Zero-Trust SRE Bot • Cluster K3s • Moad Helkamel (P5)" }
            timestamp = $timestamp
        }
    )
} | ConvertTo-Json -Depth 6

$payloadResolved = @{
    username = "OmniPay SRE Alertmanager"
    avatar_url = "https://raw.githubusercontent.com/prometheus/prometheus/main/documentation/images/prometheus-logo.png"
    content = "✅ **[INCIDENT RÉSOLU] Retour à la normale — Fiabilité rétablie**"
    embeds = @(
        @{
            title = "✅ [RESOLVED] OmniPayBurnRateCritical (NORMAL)"
            description = "Le trafic bancaire s'est stabilisé. Le taux de consommation du budget d'erreur est redescendu sous le seuil nominal."
            color = 3066993 # Green
            fields = @(
                @{ name = "🏦 Service restauré"; value = "`transaction-service`"; inline = $true },
                @{ name = "🛡️ Auto-guérison"; value = "Pod K3s régénéré avec succès"; inline = $true },
                @{ name = "⏱️ Latence P95 stabilisée"; value = "`42ms` (< 200ms SLO)"; inline = $true },
                @{ name = "📊 Dashboard Grafana"; value = "[Vérifier le statut](http://${NodeIp}:30300/d/omnipay-slo-golden)"; inline = $false }
            )
            footer = @{ text = "OmniPay Zero-Trust SRE Bot • Incident clos automatiquement" }
            timestamp = $timestamp
        }
    )
} | ConvertTo-Json -Depth 6

if ($WebhookUrl -ne "WEBHOOK_URL_PLACEHOLDER") {
    Write-Host "📤 [1/2] Envoi de l'alerte CRITIQUE vers le webhook..." -ForegroundColor Yellow
    $response = Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $payloadFiring -ContentType "application/json" -StatusCodeVariable "statusCode"
    Write-Host "  ✅ Alerte CRITIQUE transmise (HTTP $statusCode)." -ForegroundColor Green

    Write-Host "⏳ Pause de 3 secondes avant notification de résolution..." -ForegroundColor Gray
    Start-Sleep -Seconds 3

    Write-Host "📤 [2/2] Envoi de la notification de RÉSOLUTION..." -ForegroundColor Yellow
    $response = Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $payloadResolved -ContentType "application/json" -StatusCodeVariable "statusCode2"
    Write-Host "  ✅ Notification RÉSOLUE transmise (HTTP $statusCode2)." -ForegroundColor Green
} else {
    Write-Host "  ✅ Structure du payload validée avec succès (Dry-Run exécuté)." -ForegroundColor Green
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  ✅ Test webhook Alertmanager terminé avec succès !" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
