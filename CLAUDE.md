# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Kong Event Gateway (KEG) demonstration deployment on Kubernetes. It showcases KEG as a secure, multi-tenant Kafka gateway that proxies an Apache Kafka cluster managed by Strimzi. The deployment includes:

- **Kong Event Gateway (KEG)**: Provides Kafka virtualization with SNI-based routing, TLS termination, and topic prefixing for multi-tenancy
- **Kafka Cluster**: Managed by Strimzi Operator in KRaft mode (no ZooKeeper)
- **Kong Ingress Controller (KIC)**: Routes external TLS traffic using Gateway API TLSRoute resources
- **Kafka Connect**: Two clusters (operations and analytics) producing mock data
- **Kafka UI**: Web interface at `http://localhost:80` for cluster visualization

## Prerequisites

- Kubernetes 1.24+
- kubectl and helm installed
- Gateway API experimental features installed: `kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install.yaml`
- Kong Konnect control plane credentials (for KEG and KIC)
- cert-manager installed: `kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.18.2/cert-manager.yaml`

## Deployment Commands

### Complete deployment sequence:

```bash
# 1. Create namespaces
kubectl create namespace kafka && kubectl create namespace keg && kubectl create namespace kafka-ui && kubectl create namespace kic

# 2. Setup TLS certificates
kubectl apply -f certificates/ca-bootstrap.yaml -n cert-manager
kubectl apply -f certificates/cluster-certificates.yaml

# 3. Deploy Kafka (Strimzi version MUST match Kafka version)
curl -L https://github.com/strimzi/strimzi-kafka-operator/releases/download/0.47.0/strimzi-cluster-operator-0.47.0.yaml \
  | sed 's/namespace: .*/namespace: kafka/' \
  | kubectl apply -f - -n kafka
kubectl apply -f kafka/kafka-cluster/ -n kafka

# 4. Deploy KEG (requires Konnect credentials)
kubectl create secret generic konnect-env-secret \
  --from-literal=KONNECT_REGION=<your-region> \
  --from-literal=KONNECT_DOMAIN=konghq.com \
  --from-literal=KONNECT_GATEWAY_CLUSTER_ID=<control-plane-id> \
  --from-literal=KONNECT_CLIENT_CERT=<full-client-certificate> \
  --from-literal=KONNECT_CLIENT_KEY=<full-client-key> \
  -n keg
kubectl apply -f keg/

# 5. Deploy Kong Ingress Controller
kubectl create secret tls konnect-client-tls -n kic --cert=<client-certificate>.crt --key=<client-key>.key
kubectl create secret generic konnect-config -n kic \
  --from-literal=CONTROL_PLANE_ID=<control-plane-id> \
  --from-literal=CLUSTER_TELEMETRY_ENDPOINT=<endpoint> \
  --from-literal=CLUSTER_TELEMETRY_SERVER_NAME=<server-name> \
  --from-literal=API_HOSTNAME=<api-hostname>
helm repo add kong https://charts.konghq.com && helm repo update
helm install kong kong/ingress -n kic \
  --values ./kic/values.yaml \
  --set controller.ingressController.konnect.controlPlaneID="$(kubectl get secret konnect-config -n kic -o jsonpath='{.data.CONTROL_PLANE_ID}' | base64 -d)" \
  --set controller.ingressController.konnect.apiHostname="$(kubectl get secret konnect-config -n kic -o jsonpath='{.data.API_HOSTNAME}' | base64 -d)"
kubectl apply -f kic/kic-gateway.yaml

# 6. Deploy Kafka Connect
kubectl apply -f kafka/kafka-connect/kafka-connect-operations.yaml -f kafka/kafka-connect/kafka-connect-analytics.yaml
kubectl apply -f kafka/kafka-connect/connectors/

# 7. Deploy Kafka UI
kubectl apply -f kafka-ui/

# 8. Expose loadbalancer (local clusters)
# For minikube: sudo minikube tunnel -p <your-profile-name>
```

## Architecture

### Traffic Flow

1. **External Client** → `bootstrap.<virtual-cluster>.127-0-0-1.sslip.io:9094`
2. **Kong Ingress Controller** → Routes TLS traffic based on SNI (TLSRoute resources)
3. **Kong Event Gateway (KEG)** → Terminates TLS, applies topic prefixing, proxies to Kafka
4. **Kafka Cluster** → Processes requests with prefixed topics (`<prefix>-<topic-name>`)

### Virtual Clusters

KEG provides three pre-configured virtual clusters with distinct topic prefixes:
- **operations**: Prefix `operations-`, bootstrap at `bootstrap.operations.127-0-0-1.sslip.io:9094`
- **analytics**: Prefix `analytics-`, bootstrap at `bootstrap.analytics.127-0-0-1.sslip.io:9094`
- **partners**: Prefix `partner-`, bootstrap at `bootstrap.partners.127-0-0-1.sslip.io:9094`

Each virtual cluster has:
- Dedicated namespace with ExternalName services (`bootstrap`, `broker-0/1/2`) pointing to KEG
- TLSRoute resource in `kic/kic-gateway.yaml` for SNI-based routing
- Certificate SANs in `certificates/cluster-certificates.yaml`

### Key Components

**KEG Deployment** (`keg/keg-deployment.yaml`):
- Single replica deployment in `keg` namespace
- Requires Konnect credentials in `konnect-env-secret`
- Uses two certificate secrets: `keg-internal-tls-secret` (cluster communication) and `keg-external-tls-secret` (client connections)
- Health endpoint on port 8080: `/health/probes/readiness` and `/health/probes/liveness`
- Metrics available at `/health/metrics`

**Kafka Cluster** (`kafka/kafka-cluster/kafka-cluster.yaml`):
- 3 broker KRaft cluster (Strimzi-managed)
- Plain listener on 9092 (internal), TLS on 9093
- Replication factor 3, min ISR 2

**Gateway API Resources** (`kic/kic-gateway.yaml`):
- GatewayClass: `kong` (unmanaged)
- Gateway: HTTP listener on 80, TLS passthrough on 9094
- TLSRoute resources: Map SNI hostnames to KEG service for each virtual cluster

**Certificates** (`certificates/cluster-certificates.yaml`):
- Internal certs: `*.svc.cluster.local` with virtual cluster SANs for namespaces `keg`, `kafka`, `kafka-ui`
- External cert: `*.127-0-0-1.sslip.io` with virtual cluster SANs for client connections
- All signed by `ca-issuer` ClusterIssuer

## Kafka Client Access

### Using kafkactl (recommended)

Pre-configured contexts in `.kafkactl.yml`:
```bash
kafkactl config use-context operations  # Switch to operations virtual cluster
kafkactl get topics                     # List topics (with operations- prefix)
kafkactl produce <topic>                # Produce to topic
kafkactl consume <topic>                # Consume from topic
```

Direct Kafka access (requires port-forward):
```bash
kubectl port-forward svc/backend-cluster-kafka-bootstrap 9092:9092 -n kafka
kafkactl config use-context kafka-direct
```

### Connection Details

Virtual cluster clients connect to KEG via loadbalancer:
- Bootstrap: `bootstrap.<virtual-cluster>.127-0-0-1.sslip.io:9094`
- TLS: Required (insecure mode enabled in demo, set `insecure: false` in production)
- SASL: Disabled (anonymous auth)

## Common Operations

### Checking deployment status:
```bash
kubectl get pods -n kafka    # Kafka brokers and operators
kubectl get pods -n keg      # KEG gateway
kubectl get pods -n kic      # Kong Ingress Controller
kubectl get gateway -n keg   # Gateway API resources
```

### Viewing logs:
```bash
kubectl logs -n keg deployment/kong-event-gateway
kubectl logs -n kafka <kafka-pod-name>
kubectl logs -n kic <kic-pod-name>
```

### Testing connectivity:
```bash
kafkactl get brokers --context operations
kafkactl get topics --context analytics
```

### Accessing Kafka UI:
```bash
# Ensure loadbalancer is accessible (see step 8 above)
open http://localhost:80
```

## Adding New Virtual Clusters

1. **Create namespace and services** in `keg/keg-vc-broker-dns.yaml`:
   - Add Namespace resource
   - Add ExternalName services (`bootstrap`, `broker-0/1/2`) pointing to `kong-event-gateway.keg.svc.cluster.local`

2. **Add TLSRoute** in `kic/kic-gateway.yaml`:
   - Create TLSRoute with hostnames: `bootstrap.<name>.127-0-0-1.sslip.io`, `broker-{0,1,2}.<name>.127-0-0-1.sslip.io`
   - Backend: `kong-event-gateway` service on port 9094

3. **Update certificates** in `certificates/cluster-certificates.yaml`:
   - Add SANs to internal cert: `*.<name>.svc.cluster.local`
   - Add SANs to external cert: `*.<name>.127-0-0-1.sslip.io`

4. **Configure KEG virtual cluster** in Kong Konnect control plane:
   - Set topic prefix: `<name>-`
   - Configure routing and policies

5. Apply changes: `kubectl apply -f keg/ && kubectl apply -f kic/ && kubectl apply -f certificates/`

## Known Limitations

- **Virtual cluster services are not auto-generated**: Manual Kubernetes Service creation required for each virtual cluster
- **TLSRoute resources are manual**: Must be updated when adding virtual clusters
- **Certificate SANs are static**: Require manual updates for new virtual cluster DNS names
- **Connector timing**: Potential delays between Kafka Connect cluster creation and connector deployment
- **Virtual cluster name changes**: Impact DNS and certificates - requires careful coordination

Future automation planned with Kong Operator.

## Resource Requirements

Minimum cluster resources:
- CPU: ~4.5 cores
- Memory: ~8GB
- Storage: Ephemeral (persistent recommended for production)

See README.md for detailed per-component breakdown.
