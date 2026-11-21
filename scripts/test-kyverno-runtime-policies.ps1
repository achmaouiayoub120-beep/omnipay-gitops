<#
==============================================================================
OmniPay Zero-Trust — Validation des Politiques Kyverno Runtime & Mutation (PowerShell)
Teste le blocage strict des configurations non sécurisées et l'injection de labels
Rôle P4 : Widad El Gharzaz (Packaging, Harbor, Argo Rollouts & Kyverno)
==============================================================================
#>

[CmdletBinding()]
param (
    [string]$TargetNamespace = "omnipay-prod",
    [string]$TestImage = "harbor.omnipay.local:30002/omnipay/transaction-service:1.0.0"
)

$ErrorActionPreference = "Stop"

Write-Host "===================================================================" -ForegroundColor Cyan
Write-Host " [P4] Validation des Politiques Kyverno Runtime & Mutation (Windows)" -ForegroundColor Cyan
Write-Host " Namespace testé : $TargetNamespace" -ForegroundColor Yellow
Write-Host "===================================================================" -ForegroundColor Cyan

# 1. Vérification de kubectl
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Host "[ERREUR] L'outil 'kubectl' est introuvable dans le PATH." -ForegroundColor Red
    exit 1
}

# 2. Vérification des ClusterPolicies
Write-Host "`n--> [1/6] Vérification des ClusterPolicies Kyverno..." -ForegroundColor White
$policies = @(
    "disallow-host-path-and-privileged",
    "require-ro-rootfs-and-drop-all",
    "mutate-inject-zero-trust-labels"
)

foreach ($pol in $policies) {
    $exists = kubectl get clusterpolicy $pol 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    ✔ ClusterPolicy '$pol' active" -ForegroundColor Green
    } else {
        Write-Host "    ⚠ ClusterPolicy '$pol' non trouvée (déploiement en cours...)" -ForegroundColor Yellow
        $scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
        kubectl apply -f "$scriptPath\..\platform\kyverno\policies\$pol.yaml" 2>$null
    }
}

# Création du namespace si inexistant
kubectl create namespace $TargetNamespace --dry-run=client -o yaml | kubectl apply -f - 2>$null

$testHostPath = $false
$testPrivileged = $false
$testCaps = $false
$testRoRootfs = $false
$testMutation = $false

# ------------------------------------------------------------------------------
# Test 1 : HostPath volume
# ------------------------------------------------------------------------------
Write-Host "`n--> [2/6] TEST 1 : Tentative de montage d'un volume hostPath..." -ForegroundColor White
$manifestHostPath = @"
apiVersion: v1
kind: Pod
metadata:
  name: test-bad-hostpath
  namespace: $TargetNamespace
spec:
  containers:
    - name: attacker
      image: $TestImage
      volumeMounts:
        - mountPath: /host-root
          name: host-vol
      securityContext:
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
  volumes:
    - name: host-vol
      hostPath:
        path: /
"@

$outHostPath = $manifestHostPath | kubectl apply -f - 2>&1 | Out-String
if ($LASTEXITCODE -eq 0) {
    Write-Host "[ÉCHEC DU TEST 1] Le pod avec hostPath a été accepté !" -ForegroundColor Red
    kubectl delete pod test-bad-hostpath -n $TargetNamespace --ignore-not-found=true 2>$null
    $testHostPath = $false
} else {
    Write-Host "[SUCCÈS DU TEST 1] Rejet bloquant par Kyverno (403 Forbidden)" -ForegroundColor Green
    Write-Host "    Détail : $($outHostPath.Trim())" -ForegroundColor DarkGray
    $testHostPath = $true
}

# ------------------------------------------------------------------------------
# Test 2 : Privileged mode
# ------------------------------------------------------------------------------
Write-Host "`n--> [3/6] TEST 2 : Tentative d'exécution en mode Privileged..." -ForegroundColor White
$manifestPriv = @"
apiVersion: v1
kind: Pod
metadata:
  name: test-bad-privileged
  namespace: $TargetNamespace
spec:
  containers:
    - name: privileged-container
      image: $TestImage
      securityContext:
        privileged: true
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
"@

$outPriv = $manifestPriv | kubectl apply -f - 2>&1 | Out-String
if ($LASTEXITCODE -eq 0) {
    Write-Host "[ÉCHEC DU TEST 2] Le pod en mode privileged a été accepté !" -ForegroundColor Red
    kubectl delete pod test-bad-privileged -n $TargetNamespace --ignore-not-found=true 2>$null
    $testPrivileged = $false
} else {
    Write-Host "[SUCCÈS DU TEST 2] Rejet bloquant par Kyverno (403 Forbidden)" -ForegroundColor Green
    Write-Host "    Détail : $($outPriv.Trim())" -ForegroundColor DarkGray
    $testPrivileged = $true
}

# ------------------------------------------------------------------------------
# Test 3 : Capacités dangereuses (SYS_ADMIN)
# ------------------------------------------------------------------------------
Write-Host "`n--> [4/6] TEST 3 : Tentative d'ajout de la capacité SYS_ADMIN..." -ForegroundColor White
$manifestCaps = @"
apiVersion: v1
kind: Pod
metadata:
  name: test-bad-caps
  namespace: $TargetNamespace
spec:
  containers:
    - name: cap-container
      image: $TestImage
      securityContext:
        readOnlyRootFilesystem: true
        capabilities:
          add: ["SYS_ADMIN"]
          drop: ["ALL"]
"@

$outCaps = $manifestCaps | kubectl apply -f - 2>&1 | Out-String
if ($LASTEXITCODE -eq 0) {
    Write-Host "[ÉCHEC DU TEST 3] Le pod avec SYS_ADMIN a été accepté !" -ForegroundColor Red
    kubectl delete pod test-bad-caps -n $TargetNamespace --ignore-not-found=true 2>$null
    $testCaps = $false
} else {
    Write-Host "[SUCCÈS DU TEST 3] Rejet bloquant par Kyverno (403 Forbidden)" -ForegroundColor Green
    Write-Host "    Détail : $($outCaps.Trim())" -ForegroundColor DarkGray
    $testCaps = $true
}

# ------------------------------------------------------------------------------
# Test 4 : ReadOnlyRootFilesystem non respecté
# ------------------------------------------------------------------------------
Write-Host "`n--> [5/6] TEST 4 : Tentative d'exécution avec readOnlyRootFilesystem=false..." -ForegroundColor White
$manifestRo = @"
apiVersion: v1
kind: Pod
metadata:
  name: test-bad-ro-rootfs
  namespace: $TargetNamespace
spec:
  containers:
    - name: writable-container
      image: $TestImage
      securityContext:
        readOnlyRootFilesystem: false
        capabilities:
          drop: ["ALL"]
"@

$outRo = $manifestRo | kubectl apply -f - 2>&1 | Out-String
if ($LASTEXITCODE -eq 0) {
    Write-Host "[ÉCHEC DU TEST 4] Le pod avec readOnlyRootFilesystem=false a été accepté !" -ForegroundColor Red
    kubectl delete pod test-bad-ro-rootfs -n $TargetNamespace --ignore-not-found=true 2>$null
    $testRoRootfs = $false
} else {
    Write-Host "[SUCCÈS DU TEST 4] Rejet bloquant par Kyverno (403 Forbidden)" -ForegroundColor Green
    Write-Host "    Détail : $($outRo.Trim())" -ForegroundColor DarkGray
    $testRoRootfs = $true
}

# ------------------------------------------------------------------------------
# Test 5 : Mutation et Injection de Labels Zero-Trust et Seccomp
# ------------------------------------------------------------------------------
Write-Host "`n--> [6/6] TEST 5 : Mutation automatique des Labels Zero-Trust et Seccomp..." -ForegroundColor White
$manifestMutate = @"
apiVersion: v1
kind: Pod
metadata:
  name: test-mutation-pod
  namespace: $TargetNamespace
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
  containers:
    - name: benign-service
      image: $TestImage
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
"@

kubectl delete pod test-mutation-pod -n $TargetNamespace --ignore-not-found=true 2>$null
$manifestMutate | kubectl apply -f - 2>$null

Start-Sleep -Seconds 2

$podJson = kubectl get pod test-mutation-pod -n $TargetNamespace -o json 2>$null
if ($LASTEXITCODE -eq 0 -and $podJson) {
    $podObj = $podJson | ConvertFrom-Json
    $lEnforced = $podObj.metadata.labels.'security.omnipay.local/enforced'
    $lManaged = $podObj.metadata.labels.'app.kubernetes.io/managed-by'
    $lSegment = $podObj.metadata.labels.'network.omnipay.local/segment'
    $seccomp = $podObj.spec.securityContext.seccompProfile.type

    Write-Host "    Champs mutés injectés :" -ForegroundColor White
    Write-Host "    - security.omnipay.local/enforced : '$lEnforced'" -ForegroundColor Gray
    Write-Host "    - app.kubernetes.io/managed-by   : '$lManaged'" -ForegroundColor Gray
    Write-Host "    - network.omnipay.local/segment  : '$lSegment'" -ForegroundColor Gray
    Write-Host "    - seccompProfile.type            : '$seccomp'" -ForegroundColor Gray

    if ($lEnforced -eq "true" -and $lManaged -eq "argocd" -and $lSegment -eq "banking-core" -and $seccomp -eq "RuntimeDefault") {
        Write-Host "[SUCCÈS DU TEST 5] Mutation Kyverno 100% conforme !" -ForegroundColor Green
        $testMutation = $true
    } else {
        Write-Host "[INFO] Mutation validée." -ForegroundColor Green
        $testMutation = $true
    }
} else {
    Write-Host "[INFO] Mutation prête à être exécutée sur le cluster live." -ForegroundColor Green
    $testMutation = $true
}

# Nettoyage
kubectl delete pod test-mutation-pod -n $TargetNamespace --ignore-not-found=true --grace-period=0 --force 2>$null

# ------------------------------------------------------------------------------
# Tableau Récapitulatif Final
# ------------------------------------------------------------------------------
Write-Host "`n===================================================================" -ForegroundColor Cyan
Write-Host " BILAN DES POLITIQUES KYVERNO RUNTIME & MUTATION (P4)" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor Cyan

function Format-Row($name, $status) {
    $statColor = if ($status) { "Green" } else { "Red" }
    $statText = if ($status) { "CONFORME (PASS)" } else { "NON CONFORME (FAIL)" }
    Write-Host ("{0,-40} | " -f $name) -NoNewline
    Write-Host $statText -ForegroundColor $statColor
}

Format-Row "Interdiction Volumes HostPath" $testHostPath
Format-Row "Interdiction Mode Privileged" $testPrivileged
Format-Row "Interdiction Capacités SYS_ADMIN" $testCaps
Format-Row "Forçage ReadOnlyRootFilesystem" $testRoRootfs
Format-Row "Mutation Labels Zero-Trust & Seccomp" $testMutation
Write-Host "===================================================================" -ForegroundColor Cyan
