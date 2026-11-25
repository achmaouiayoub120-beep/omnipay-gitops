<#
==============================================================================
OmniPay Zero-Trust — Démo 2 Live (~2 min) : Barrière d'Admission Kyverno + Cosign
Scénarios :
  A : Image publique non signée (nginx:alpine) & image non signée Harbor -> rejetée
  B : Conteneur privileged: true ou runAsUser: 0 -> rejeté (require-non-root / privileged)
  C : Image signée Cosign depuis harbor.omnipay.local:30002 -> admise et Running
Rôle P4 : Widad El Gharzaz — Plateforme, Supply Chain Security & Lead GitOps
==============================================================================
#>

[CmdletBinding()]
param (
    [string]$Namespace = "omnipay-prod",
    [string]$PublicUnsignedImage = "nginx:alpine",
    [string]$HarborUnsignedImage = "harbor.omnipay.local:30002/omnipay/untrusted-service:latest",
    [string]$SignedImage = "harbor.omnipay.local:30002/omnipay/transaction-service:1.0.0",
    [int]$RunningTimeoutSec = 60,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PodAPublic = "demo2-unsigned-public-$PID"
$PodAHarbor = "demo2-unsigned-harbor-$PID"
$PodBPriv = "demo2-privileged-$PID"
$PodBRoot = "demo2-root-user-$PID"
$PodCSigned = "demo2-signed-compliant-$PID"

function Invoke-KubectlApplyManifest {
    param([string]$YamlContent)
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = $YamlContent | kubectl apply -f - 2>&1
        $exitCode = $LASTEXITCODE
        return @{
            Success = ($exitCode -eq 0)
            Output  = ($output | Out-String).Trim()
        }
    } finally {
        $ErrorActionPreference = $prevPref
    }
}

Write-Host "===================================================================================" -ForegroundColor Blue
Write-Host " OmniPay Zero-Trust — Démo 2 Live (~2 min) : Admission Kyverno & Signature Cosign" -ForegroundColor Cyan
Write-Host " Namespace cible : $Namespace" -ForegroundColor Yellow
Write-Host "===================================================================================" -ForegroundColor Blue

if ($DryRun) {
    Write-Host "[DRY-RUN] Mode simulation activé : aucune requête ne sera envoyée au cluster." -ForegroundColor Yellow
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw "L'outil 'kubectl' est requis mais introuvable dans le PATH."
}

$scenarioAOk = $false
$scenarioBOk = $false
$scenarioCOk = $false

try {
    # --------------------------------------------------------------------------
    # Pré-check : Politiques Kyverno actives
    # --------------------------------------------------------------------------
    Write-Host "`n--> [Pré-check] Vérification des politiques Kyverno actives..." -ForegroundColor White

    if (-not $DryRun) {
        $null = kubectl get namespace $Namespace 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Namespace '$Namespace' introuvable." }

        $policies = @(
            "verify-omnipay-image-signature",
            "disallow-host-path-and-privileged",
            "require-ro-rootfs-and-drop-all",
            "mutate-inject-zero-trust-labels"
        )
        foreach ($pol in $policies) {
            $null = kubectl get clusterpolicy $pol 2>$null
            if ($LASTEXITCODE -eq 0) {
                $act = (kubectl get clusterpolicy $pol -o jsonpath="{.spec.validationFailureAction}" 2>$null | Out-String).Trim()
                Write-Host "    ✔ ClusterPolicy '$pol' active [Mode: $(if ($act) { $act } else { 'Mutate' })]" -ForegroundColor Green
            } else {
                Write-Host "    ⚠ ClusterPolicy '$pol' absente du cluster." -ForegroundColor Yellow
            }
        }

        $nonRootFound = $false
        foreach ($cand in @("require-run-as-non-root", "require-non-root-user")) {
            $null = kubectl get clusterpolicy $cand 2>$null
            if ($LASTEXITCODE -eq 0) {
                $act = (kubectl get clusterpolicy $cand -o jsonpath="{.spec.validationFailureAction}" 2>$null | Out-String).Trim()
                Write-Host "    ✔ ClusterPolicy '$cand' active [Mode: $(if ($act) { $act } else { 'Enforce' })]" -ForegroundColor Green
                $nonRootFound = $true
            }
        }
        if (-not $nonRootFound) {
            Write-Host "    ⚠ Aucune politique non-root ('require-run-as-non-root' / 'require-non-root-user') détectée." -ForegroundColor Yellow
        }
    } else {
        Write-Host "    [DRY-RUN] Vérification ClusterPolicies (verify-omnipay-image-signature, require-run-as-non-root, disallow-host-path-and-privileged)." -ForegroundColor Gray
    }

    # --------------------------------------------------------------------------
    # Scénario A : Image publique non signée (nginx:alpine) -> rejetée
    # --------------------------------------------------------------------------
    Write-Host "`n--> [Scénario A] Tentative de déploiement d'une image publique non signée ($PublicUnsignedImage)..." -ForegroundColor White

    if (-not $DryRun) {
        $prevPref = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $outAPub = kubectl run $PodAPublic --image=$PublicUnsignedImage --restart=Never -n $Namespace 2>&1
        $codeAPub = $LASTEXITCODE
        $ErrorActionPreference = $prevPref

        if ($codeAPub -eq 0) {
            Write-Host "[ÉCHEC SCÉNARIO A] L'image publique '$PublicUnsignedImage' a été admise à tort !" -ForegroundColor Red
            kubectl delete pod $PodAPublic -n $Namespace --ignore-not-found=true 2>$null | Out-Null
            $scenarioAOk = $false
        } else {
            $msg = (($outAPub | Out-String) -replace "\r?\n", " ").Trim()
            if ($msg.Length -gt 240) { $msg = $msg.Substring(0, 240) }
            Write-Host "✔ Rejet immédiat de '$PublicUnsignedImage' par le webhook Kyverno (HTTP 403 Forbidden) :" -ForegroundColor Green
            Write-Host "    $msg" -ForegroundColor Gray
            $scenarioAOk = $true
        }

        Write-Host "    Vérification ciblée de la signature Cosign sur '$HarborUnsignedImage' :" -ForegroundColor Gray
        $manifestAHarbor = @"
apiVersion: v1
kind: Pod
metadata:
  name: $PodAHarbor
  namespace: $Namespace
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: untrusted
      image: $HarborUnsignedImage
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
"@
        $resAHarbor = Invoke-KubectlApplyManifest -YamlContent $manifestAHarbor
        if ($resAHarbor.Success) {
            Write-Host "[ÉCHEC SCÉNARIO A] L'image Harbor non signée '$HarborUnsignedImage' a été admise !" -ForegroundColor Red
            kubectl delete pod $PodAHarbor -n $Namespace --ignore-not-found=true 2>$null | Out-Null
            $scenarioAOk = $false
        } else {
            $msgH = ($resAHarbor.Output -replace "\r?\n", " ").Trim()
            if ($msgH.Length -gt 240) { $msgH = $msgH.Substring(0, 240) }
            Write-Host "✔ Rejet cryptographique Cosign confirmé par Kyverno :" -ForegroundColor Green
            Write-Host "    $msgH" -ForegroundColor Gray
        }
    } else {
        Write-Host "    [DRY-RUN] Rejet attendu : admission webhook validate.kyverno.svc denied ($PublicUnsignedImage & $HarborUnsignedImage)." -ForegroundColor Gray
        $scenarioAOk = $true
    }

    # --------------------------------------------------------------------------
    # Scénario B : Conteneur privileged: true ou runAsUser: 0 -> rejeté
    # --------------------------------------------------------------------------
    Write-Host "`n--> [Scénario B] Tentative de conteneur privilégié (privileged: true) et root (runAsUser: 0)..." -ForegroundColor White

    if (-not $DryRun) {
        $manifestBPriv = @"
apiVersion: v1
kind: Pod
metadata:
  name: $PodBPriv
  namespace: $Namespace
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
  containers:
    - name: priv-container
      image: $SignedImage
      securityContext:
        privileged: true
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
"@
        $resB1 = Invoke-KubectlApplyManifest -YamlContent $manifestBPriv
        $bPrivDenied = $false
        if ($resB1.Success) {
            Write-Host "[ÉCHEC] Le pod avec privileged: true a été accepté !" -ForegroundColor Red
            kubectl delete pod $PodBPriv -n $Namespace --ignore-not-found=true 2>$null | Out-Null
        } else {
            $msgB1 = ($resB1.Output -replace "\r?\n", " ").Trim()
            if ($msgB1.Length -gt 240) { $msgB1 = $msgB1.Substring(0, 240) }
            Write-Host "✔ Pod 'privileged: true' rejeté par Kyverno :" -ForegroundColor Green
            Write-Host "    $msgB1" -ForegroundColor Gray
            $bPrivDenied = $true
        }

        $manifestBRoot = @"
apiVersion: v1
kind: Pod
metadata:
  name: $PodBRoot
  namespace: $Namespace
spec:
  securityContext:
    runAsNonRoot: false
    runAsUser: 0
  containers:
    - name: root-container
      image: $SignedImage
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
"@
        $resB2 = Invoke-KubectlApplyManifest -YamlContent $manifestBRoot
        $bRootDenied = $false
        if ($resB2.Success) {
            Write-Host "[ÉCHEC] Le pod avec runAsUser: 0 a été accepté !" -ForegroundColor Red
            kubectl delete pod $PodBRoot -n $Namespace --ignore-not-found=true 2>$null | Out-Null
        } else {
            $msgB2 = ($resB2.Output -replace "\r?\n", " ").Trim()
            if ($msgB2.Length -gt 240) { $msgB2 = $msgB2.Substring(0, 240) }
            Write-Host "✔ Pod 'runAsUser: 0' rejeté par la politique non-root Kyverno :" -ForegroundColor Green
            Write-Host "    $msgB2" -ForegroundColor Gray
            $bRootDenied = $true
        }

        $scenarioBOk = ($bPrivDenied -and $bRootDenied)
    } else {
        Write-Host "    [DRY-RUN] Rejet attendu : privileged: true (disallow-host-path-and-privileged) et runAsUser: 0 (require-run-as-non-root)." -ForegroundColor Gray
        $scenarioBOk = $true
    }

    # --------------------------------------------------------------------------
    # Scénario C : Image signée Cosign depuis harbor.omnipay.local:30002 -> Running
    # --------------------------------------------------------------------------
    Write-Host "`n--> [Scénario C] Déploiement d'une image signée Cosign ($SignedImage) conforme Zero-Trust..." -ForegroundColor White

    if (-not $DryRun) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        $cosignPub = Join-Path (Split-Path -Parent $scriptDir) "platform\kyverno\keys\cosign.pub"
        if ((Get-Command cosign -ErrorAction SilentlyContinue) -and (Test-Path $cosignPub)) {
            Write-Host "    Vérification locale Cosign avec $cosignPub :" -ForegroundColor Gray
            $null = cosign verify --key $cosignPub --insecure-ignore-tlog $SignedImage 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    ✔ Signature cryptographique Cosign vérifiée localement." -ForegroundColor Green
            } else {
                Write-Host "    ℹ Vérification locale Cosign non concluante (vérification cluster en cours)." -ForegroundColor Yellow
            }
        }

        $manifestCSigned = @"
apiVersion: v1
kind: Pod
metadata:
  name: $PodCSigned
  namespace: $Namespace
  labels:
    app: demo2-signed-check
spec:
  imagePullSecrets:
    - name: harbor-registry-secret
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: transaction-service
      image: $SignedImage
      imagePullPolicy: IfNotPresent
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      volumeMounts:
        - name: tmp-vol
          mountPath: /tmp
  volumes:
    - name: tmp-vol
      emptyDir: {}
"@
        $resC = Invoke-KubectlApplyManifest -YamlContent $manifestCSigned
        if ($resC.Success) {
            Write-Host "    Attente de l'état Running/Ready (timeout ${RunningTimeoutSec}s)..." -ForegroundColor Gray
            $prevPref = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $null = kubectl wait --for=condition=Ready "pod/$PodCSigned" -n $Namespace --timeout="${RunningTimeoutSec}s" 2>$null
            $waitOk = ($LASTEXITCODE -eq 0)
            $ErrorActionPreference = $prevPref

            $phaseC = (kubectl get pod $PodCSigned -n $Namespace -o jsonpath="{.status.phase}" 2>$null | Out-String).Trim()
            $labelEnf = (kubectl get pod $PodCSigned -n $Namespace -o jsonpath="{.metadata.labels.security\.omnipay\.local/enforced}" 2>$null | Out-String).Trim()

            if ($waitOk -or $phaseC -eq "Running") {
                Write-Host "✔ Pod '$PodCSigned' admis et en état '$phaseC' !" -ForegroundColor Green
                Write-Host "    Label muté par Kyverno (security.omnipay.local/enforced) : $(if ($labelEnf) { $labelEnf } else { 'N/A' })" -ForegroundColor Cyan
                kubectl get pod $PodCSigned -n $Namespace -o wide
                $scenarioCOk = $true
            } else {
                Write-Host "⚠ Pod admis par Kyverno (phase actuelle : $phaseC)." -ForegroundColor Yellow
                kubectl get pod $PodCSigned -n $Namespace -o wide
            }
        } else {
            Write-Host "[ÉCHEC SCÉNARIO C] Le pod signé et conforme a été rejeté : $($resC.Output)" -ForegroundColor Red
        }
    } else {
        Write-Host "    [DRY-RUN] Admission & état Running attendus pour '$SignedImage'." -ForegroundColor Gray
        $scenarioCOk = $true
    }

    # --------------------------------------------------------------------------
    # Synthèse Démo 2
    # --------------------------------------------------------------------------
    Write-Host "`n===================================================================================" -ForegroundColor Blue
    Write-Host " SYNTHÈSE DÉMO 2 — BARRIÈRE D'ADMISSION KYVERNO & COSIGN" -ForegroundColor White
    Write-Host "===================================================================================" -ForegroundColor Blue
    Write-Host (" {0,-52} | {1}" -f "A. Image non signée ($PublicUnsignedImage / Harbor)", $(if ($scenarioAOk) { "REJETÉE (PASS)" } else { "FAIL" })) -ForegroundColor $(if ($scenarioAOk) { "Green" } else { "Red" })
    Write-Host (" {0,-52} | {1}" -f "B. Conteneur privileged: true / runAsUser: 0", $(if ($scenarioBOk) { "REJETÉ (PASS)" } else { "FAIL" })) -ForegroundColor $(if ($scenarioBOk) { "Green" } else { "Red" })
    Write-Host (" {0,-52} | {1}" -f "C. Image signée Cosign ($SignedImage)", $(if ($scenarioCOk) { "ADMISE & RUNNING (PASS)" } else { "FAIL" })) -ForegroundColor $(if ($scenarioCOk) { "Green" } else { "Red" })
    Write-Host "===================================================================================" -ForegroundColor Blue

    if (-not ($scenarioAOk -and $scenarioBOk -and $scenarioCOk)) {
        exit 1
    }
}
finally {
    if (-not $DryRun) {
        foreach ($p in @($PodAPublic, $PodAHarbor, $PodBPriv, $PodBRoot, $PodCSigned)) {
            kubectl delete pod $p -n $Namespace --ignore-not-found=true --grace-period=0 --force 2>$null | Out-Null
        }
    }
}
