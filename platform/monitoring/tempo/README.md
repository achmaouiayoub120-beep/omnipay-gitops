# 🧭 Guide d'Intégration Tracing Distribué (Grafana Tempo & OpenTelemetry)
## OmniPay Zero-Trust | Rôle P5 (Fiabilité & Observabilité) à destination de P2 (Backend Spring Boot)

---

## 1. Contexte & Architecture du Traçage Distribué

Dans l'architecture bancaire OmniPay Zero-Trust, une transaction traverse plusieurs microservices et couches d'infrastructure :

```
[Client / Frontend Web]
         │
         ▼ (W3C traceparent header)
[Ingress NGINX Controller]
         │
         ▼
[Auth Service :8081]  ──(JWT / Token Validation)──┐
         │                                         │
         ▼ (W3C traceparent propagé)               ▼
[Transaction Service :8082] ────────────────► [PostgreSQL Database]
         │
         ▼ (W3C traceparent propagé)
[Notification Service :8083]
         │
         ▼
[Tracing Exporter OTLP/HTTP]
         │
         ▼
[Grafana Tempo (K3s) :4318/v1/traces]
         │
         ▼ (Corrélation 360°)
[Grafana Explore] ◄──► [Loki Logs (traceId)] ◄──► [Prometheus RED Metrics]
```

Tempo permet d'isoler en un clic quelle composante consomme le plus de latence ou génère des erreurs au sein d'une transaction financière.

---

## 2. Spécification OpenTelemetry pour les Microservices (Spring Boot 3.4 / Java 21)

### A. Dépendances Maven (`pom.xml` des microservices P2)

Pour activer le tracing sans agent JVM lourd, ajouter dans le `pom.xml` de `auth-service`, `transaction-service` et `notification-service` :

```xml
<!-- Pont Micrometer vers OpenTelemetry -->
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-tracing-bridge-otel</artifactId>
</dependency>

<!-- Exportateur OTLP gRPC / HTTP vers Grafana Tempo -->
<dependency>
    <groupId>io.opentelemetry</groupId>
    <artifactId>opentelemetry-exporter-otlp</artifactId>
</dependency>
```

### B. Configuration Spring Boot (`application.yml`)

Ajouter dans la section `management` de chaque service :

```yaml
management:
  tracing:
    sampling:
      # 100% de traces en environnement de test/recette, 10% en production
      probability: 1.0
    propagation:
      # Propagation stricte de la norme W3C Trace Context
      type: W3C
  otlp:
    tracing:
      # Endpoint interne cluster K3s exposé par le service Tempo
      endpoint: "http://tempo.monitoring.svc.cluster.local:4318/v1/traces"
      timeout: 2s
  endpoints:
    web:
      exposure:
        include: "health,info,metrics,prometheus"
```

### C. Propagation HTTP (RestTemplate / WebClient / FeignClient)

Spring Boot 3.4 avec Micrometer Tracing injecte automatiquement l'en-tête standard **W3C `traceparent`** dans les appels sortants :

Exemple d'en-tête propagé :
```http
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
```
- `00` : version W3C
- `4bf92f3577b34da6a3ce929d0e0e4736` : `traceId` unique conservé de bout en bout
- `00f067aa0ba902b7` : `spanId` du sous-segment courant
- `01` : flag d'échantillonnage (sampled)

---

## 3. Endpoints Réseau de Grafana Tempo sur K3s

| Protocole | Port Interne Cluster | URL de Service K8s | Utilisation |
|---|---|---|---|
| **OTLP HTTP** | `4318` | `http://tempo.monitoring.svc.cluster.local:4318/v1/traces` | Envoi des traces Spring Boot via HTTP/JSON ou Protobuf |
| **OTLP gRPC** | `4317` | `tempo.monitoring.svc.cluster.local:4317` | Envoi haute performance via gRPC |
| **Jaeger Thrift** | `14268` | `http://tempo.monitoring.svc.cluster.local:14268/api/traces` | Compatibilité Jaeger legacy |
| **Tempo API** | `3100` | `http://tempo.monitoring.svc.cluster.local:3100` | Interrogation des traces par Grafana |

---

## 4. Procédure de Vérification & Test de Connectivité

### Tester la réception d'une trace via curl (depuis un pod applicatif ou le cluster) :

```bash
# Envoyer une trace synthétique OTLP/HTTP vers Tempo
curl -X POST http://tempo.monitoring.svc.cluster.local:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d '{
    "resourceSpans": [{
      "resource": {
        "attributes": [
          {"key": "service.name", "value": {"stringValue": "omnipay-smoke-test"}}
        ]
      },
      "scopeSpans": [{
        "spans": [{
          "traceId": "5b8aa5a2d2c872e8321cf37308d69d45",
          "spanId": "051581bf3cb55c1e",
          "name": "HTTP POST /api/transactions/transfer",
          "kind": 1,
          "startTimeUnixNano": "1700000000000000000",
          "endTimeUnixNano": "1700000000050000000",
          "status": {"code": 1}
        }]
      }]
    }]
  }'
```

### Consulter la trace dans Grafana :
1. Accéder à Grafana (`http://<NODE_IP>:30300`)
2. Aller dans **Explore** ➔ Sélectionner la datasource **Tempo**
3. Saisir le Trace ID : `5b8aa5a2d2c872e8321cf37308d69d45`
4. Constater l'affichage de la timeline et le bouton **"Logs for this span"** qui filtre automatiquement les logs Loki avec le même Trace ID !
