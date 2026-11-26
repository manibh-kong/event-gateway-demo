#!/usr/bin/env bash
# End-to-end checks for the Kong Event Gateway demo.
#
# Prerequisites:
#   - Port 9094 (KEG virtual clusters) and an HTTP port for KIC (Kafka UI, Prometheus, Jaeger)
#     reachable on 127.0.0.1, e.g. `sudo minikube tunnel -p <profile>` (HTTP on 80), or
#       kubectl port-forward -n kic svc/kong-gateway-proxy 9094:9094 8080:80   (then HTTP_PORT=8080)
#   - kafkactl, kubectl, curl
#
# Usage: tests/test-keg.sh            (HTTP_PORT defaults to 80)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HTTP="http://localhost:${HTTP_PORT:-80}"
K() { kafkactl --config-file="$REPO_ROOT/.kafkactl.yml" "$@"; }
BACKEND() { kubectl exec -n kafka backend-cluster-broker-0 -c kafka -- "$@"; }

PASS=0; FAIL=0
check() { # check "<name>" <command...>   (passes when the command exits 0)
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "  PASS  $name"; PASS=$((PASS+1));
  else echo "  FAIL  $name"; FAIL=$((FAIL+1)); fi
}

echo "== Platform"
check "KEG pod ready"            kubectl wait --for=condition=Ready pod -l app=kong-event-gateway -n keg --timeout=10s
check "KEG image is 1.3.x"       bash -c "kubectl get deploy kong-event-gateway -n keg -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q ':1\.3\.'"
check "Kafka brokers ready"      kubectl wait --for=condition=Ready pod -l strimzi.io/broker-role=true -n kafka --timeout=10s
check "Connect clusters ready"   kubectl wait --for=condition=Ready kafkaconnect --all -n kafka --timeout=10s
check "All connectors RUNNING"   bash -c "! kubectl get kafkaconnector -n kafka -o jsonpath='{range .items[*]}{.status.connectorStatus.connector.state}{\"\n\"}{end}' | grep -v RUNNING"
check "Certificates Ready"       kubectl wait --for=condition=Ready certificate --all -A --timeout=10s

echo "== SNI routing + virtual clusters (via KIC TLSRoute -> KEG :9094)"
for vc in operations analytics partners; do
  check "$vc: brokers advertised as *.$vc.127-0-0-1.sslip.io" bash -c "kafkactl --config-file='$REPO_ROOT/.kafkactl.yml' --context $vc get brokers | grep -q 'broker-0.$vc.127-0-0-1.sslip.io:9094'"
done

echo "== Multi-tenancy (topic prefix hidden, tenants isolated)"
T="keg-test-$(date +%s)"
check "operations: create topic $T"            K --context operations create topic "$T" -p 1 -r 3
sleep 3
check "operations: produce"                    bash -c "echo hello-$T | kafkactl --config-file='$REPO_ROOT/.kafkactl.yml' --context operations produce $T"
check "operations: consume own record"         bash -c "kafkactl --config-file='$REPO_ROOT/.kafkactl.yml' --context operations consume $T --from-beginning --exit | grep -q hello-$T"
check "backend stores it as operations-$T"     bash -c "kubectl exec -n kafka backend-cluster-broker-0 -c kafka -- bin/kafka-topics.sh --bootstrap-server localhost:9092 --list | grep -qx operations-$T"
check "analytics cannot see it"                bash -c "! kafkactl --config-file='$REPO_ROOT/.kafkactl.yml' --context analytics get topics | grep -q $T"
check "partners cannot see it"                 bash -c "! kafkactl --config-file='$REPO_ROOT/.kafkactl.yml' --context partners get topics | grep -q $T"
check "partners only sees delivery-updates"    bash -c "[ \"\$(kafkactl --config-file='$REPO_ROOT/.kafkactl.yml' --context partners get topics -o compact)\" = delivery-updates ]"
check "operations sees shared delivery-updates" bash -c "kafkactl --config-file='$REPO_ROOT/.kafkactl.yml' --context operations get topics -o compact | grep -qx delivery-updates"
BACKEND bin/kafka-topics.sh --bootstrap-server localhost:9092 --delete --topic "operations-$T" >/dev/null 2>&1

echo "== Encryption (operations vehicle-gps)"
REC=$(K --context operations consume vehicle-gps --tail 1 --print-partitions --exit -o json 2>/dev/null)
P=$(echo "$REC" | awk -F': ' '/"Partition"/{gsub(",","",$2);print $2}'); O=$(echo "$REC" | awk -F': ' '/"Offset"/{gsub(",","",$2);print $2}')
# Read the same partition/offset straight from the backend, bypassing KEG.
RAW=$(BACKEND bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic operations-vehicle-gps \
      --partition "${P:-0}" --offset "${O:-0}" --max-messages 1 --property print.headers=true --timeout-ms 20000 2>/dev/null | LC_ALL=C tr -cd '[:print:]')
has_plaintext()   { grep -q vehicleId <<<"$REC"; }
has_enc_header()  { grep -q 'kong/enc' <<<"$RAW"; }
not_plaintext()   { ! grep -q vehicleId <<<"$RAW"; }
check "client sees plaintext JSON"             has_plaintext
check "backend record carries kong/enc header" has_enc_header
check "backend value is not plaintext"         not_plaintext

echo "== Partner policies (delivery-updates)"
PARTNERS=$(K --context partners consume delivery-updates --tail 100 --exit 2>/dev/null | grep -o '"partner":"[^"]*"' | sort -u)
only_amazon() { [ -n "$PARTNERS" ] && [ "$PARTNERS" = '"partner":"Amazon"' ]; }
check "skip-record: partners only receive Amazon" only_amazon
SV="SV-$(date +%s)"
echo "not-json" | K --context operations produce delivery-updates -k "$SV" >/dev/null 2>&1; sleep 2
check "schema validation marks invalid JSON"   bash -c "kafkactl --config-file='$REPO_ROOT/.kafkactl.yml' --context partners consume delivery-updates --tail 50 --print-keys --print-headers --exit | grep $SV | grep -q 'kong/policy-failure-'"

echo "== UIs and observability (via KIC HTTP at $HTTP)"
check "Kafka UI: all 4 clusters ONLINE"        bash -c "[ \$(curl -s $HTTP/api/clusters | grep -o '\"status\":\"ONLINE\"' | wc -l) -eq 4 ]"
check "Prometheus has KEG 1.3 metrics"         bash -c "curl -s '$HTTP/prometheus/api/v1/query?query=kong_dataplane_lifecycle_service_ready' | grep -q '\"result\":\[{'"
check "Jaeger has traces from service keg"     bash -c "curl -s $HTTP/jaeger/api/services | grep -q '\"keg\"'"

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
