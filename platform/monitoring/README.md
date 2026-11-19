# 🔭 OmniPay Zero-Trust — Guide d'Exploitation Monitoring (S1)

> **Rôle** : P5 — Fiabilité, Observabilité & SRE  
> **Stack** : kube-prometheus-stack (Prometheus + Grafana + Alertmanager)  
> **Cluster** : K3s

---

## 1. Prérequis

| Outil | Vérification |
|---|---|
| `kubectl` ≥ 1.27 | `kubectl version --client` |
| `helm` ≥ 3.12 | `helm version` |
| Cluster K3s | `kubectl get nodes` |

---

## 2. Installation

### 2.1 Ajouter le repo Helm et créer le namespace

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl create namespace monitoring
```

### 2.2 Installer kube-prometheus-stack

```bash
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f values-prometheus.yaml \
  --wait --timeout 10m
```

### 2.3 Appliquer le ServiceMonitor

```bash
kubectl apply -f servicemonitor-omnipay.yaml
```

---

## 3. Vérification

### 3.1 Pods

```bash
kubectl get pods -n monitoring
```

Tous les pods doivent être `Running` et `Ready` :
- `monitoring-grafana-*` (3/3)
- `monitoring-kube-prometheus-operator-*` (1/1)
- `monitoring-kube-state-metrics-*` (1/1)
- `monitoring-prometheus-node-exporter-*` (1/1)
- `prometheus-monitoring-kube-prometheus-prometheus-0` (2/2)
- `alertmanager-monitoring-kube-prometheus-alertmanager-0` (2/2)

### 3.2 Services

```bash
kubectl get svc -n monitoring
```

| Service | NodePort |
|---|---|
| `monitoring-grafana` | **30300** |
| `monitoring-kube-prometheus-prometheus` | **30900** |
| `monitoring-kube-prometheus-alertmanager` | **30903** |

### 3.3 ServiceMonitor

```bash
kubectl get servicemonitor -n monitoring
# omnipay-services-monitor   <AGE>
```

### 3.4 CRD Prometheus Operator

```bash
kubectl get crd | grep monitoring.coreos.com
```

---

## 4. Accès aux interfaces

### Récupérer l'IP du nœud K3s

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
```

| Interface | URL | Identifiants |
|---|---|---|
| **Grafana** | `http://<NODE_IP>:30300` | `admin` / `GrafanaOmniPay2026!` |
| **Prometheus** | `http://<NODE_IP>:30900` | — |
| **Alertmanager** | `http://<NODE_IP>:30903` | — |

### Alternative (port-forward)

```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80 &
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090 &
```

---

## 5. Datasource Prometheus dans Grafana

La datasource est **auto-provisionnée**. Vérification :

1. Grafana → **Configuration** → **Data Sources**
2. Vérifier **Prometheus** avec l'URL : `http://monitoring-kube-prometheus-prometheus.monitoring.svc:9090`
3. Cliquer **Save & Test**

---

## 6. Import des Dashboards

Dans Grafana → **Dashboards** → **Import** :

| Dashboard | ID | Usage |
|---|----|---|
| Kubernetes Pods (Namespace) | `15760` | CPU, mémoire, réseau par pod |
| JVM Micrometer Spring Boot | `4701` | Heap, GC, threads JVM |
| Node Exporter Full | `1860` | Métriques système par nœud |
| Spring Boot Statistics | `12900` | Stats HTTP Spring Boot |

---

## 7. Vérification des Targets

### Dans l'UI Prometheus

1. `http://<NODE_IP>:30900` → **Status** → **Targets**
2. Vérifier que tous les targets sont **UP**

### Via l'API

```bash
curl -s "http://${NODE_IP}:30900/api/v1/targets" | \
  jq '.data.activeTargets[] | {job: .labels.job, health: .health}'
```

> **Note** : Les targets OmniPay ne seront visibles qu'une fois les microservices déployés avec le label `monitored: "true"`.

---

## 8. Mise à jour

```bash
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring -f values-prometheus.yaml --wait
```

---

## 9. Désinstallation

```bash
helm uninstall monitoring --namespace monitoring
kubectl delete namespace monitoring
```

---

## 10. Quick Reference

```bash
# INSTALL
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl create namespace monitoring
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring -f values-prometheus.yaml --wait --timeout 10m
kubectl apply -f servicemonitor-omnipay.yaml

# CHECK
kubectl get pods -n monitoring
kubectl get svc -n monitoring
kubectl get servicemonitor -n monitoring

# ACCESS
# Grafana     : http://<NODE_IP>:30300  (admin / GrafanaOmniPay2026!)
# Prometheus  : http://<NODE_IP>:30900
# Alertmanager: http://<NODE_IP>:30903
```
