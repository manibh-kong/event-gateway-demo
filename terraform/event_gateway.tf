resource "konnect_event_gateway" "event_gateway_terraform" {
  name = var.event_gateway_name
  # Unlocks policy fields that need newer data planes (failure_mode, validate_key, inline schemas, ...).
  # Keep in step with the image tag in keg/keg-deployment.yaml.
  min_runtime_version = var.keg_min_runtime_version
}

resource "konnect_event_gateway_backend_cluster" "backend_cluster" {
  name        = "backend_cluster"
  description = "Strimzi managed 3 node Kafka cluster"
  gateway_id  = konnect_event_gateway.event_gateway_terraform.id

  insecure_allow_anonymous_virtual_cluster_auth = true

  authentication = {
    anonymous = {}
  }

  bootstrap_servers = [
    "backend-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092"
  ]

  tls = {
    enabled = false
  }

}

resource "konnect_event_gateway_virtual_cluster" "operations_team_vc" {
  name     = "Operations Team"
  acl_mode = "passthrough"
  authentication = [
    {
      anonymous = {}
    }
  ]
  destination = {
    id = konnect_event_gateway_backend_cluster.backend_cluster.id
  }
  dns_label = "operations"
  labels = {
  }
  namespace = {
    additional = {
      topics = [
        {
          exact_list = {
            exact_list = [
              {
                backend = "delivery-updates"
              }
            ]
          }
        }
      ]
    }
    mode   = "hide_prefix"
    prefix = "operations-"
  }
  gateway_id = konnect_event_gateway.event_gateway_terraform.id
}

resource "konnect_event_gateway_virtual_cluster" "analytics_team_vc" {
  name     = "Analytics Team"
  acl_mode = "passthrough"
  authentication = [
    {
      anonymous = {}
    }
  ]
  destination = {
    id = konnect_event_gateway_backend_cluster.backend_cluster.id
  }
  dns_label = "analytics"
  labels = {
  }
  namespace = {
    additional = {
    }
    mode   = "hide_prefix"
    prefix = "analytics-"
  }
  gateway_id = konnect_event_gateway.event_gateway_terraform.id
}

resource "konnect_event_gateway_virtual_cluster" "external_partners_vc" {
  name     = "External Partners"
  acl_mode = "passthrough"
  authentication = [
    {
      anonymous = {}
    }
  ]
  destination = {
    id = konnect_event_gateway_backend_cluster.backend_cluster.id
  }
  dns_label = "partners"
  labels = {
  }
  namespace = {
    additional = {
      topics = [
        {
          exact_list = {
            exact_list = [
              {
                backend = "delivery-updates"
              }
            ]
          }
        }
      ]
    }
    mode   = "hide_prefix"
    prefix = "partners-"
  }
  gateway_id = konnect_event_gateway.event_gateway_terraform.id
}

// Internal listener with policies set up for SNI
resource "konnect_event_gateway_listener" "internal_listener" {
  addresses = [
    "0.0.0.0"
  ]
  description = "listener for internal clients"
  labels = {
  }
  name = "Internal"
  ports = [
    "9092"
  ]
  gateway_id = konnect_event_gateway.event_gateway_terraform.id
}
resource "konnect_event_gateway_listener_policy_tls_server" "my_eventgatewaylistenerpolicytlsserver" {
  config = {
    allow_plaintext = false
    certificates = [
      {
        certificate = "$${env[\"KEG_TLS_INTERNAL_CERT\"]}"
        key         = "$${env[\"KEG_TLS_INTERNAL_KEY\"]}"
      }
    ]
    versions = {
      max = "TLSv1.3"
      min = "TLSv1.2"
    }
  }
  enabled = true
  labels = {
  }
  name        = "Internal TLS Server"
  gateway_id  = konnect_event_gateway.event_gateway_terraform.id
  listener_id = konnect_event_gateway_listener.internal_listener.id
}
resource "konnect_event_gateway_listener_policy_forward_to_virtual_cluster" "internal_listener_policy_forward_to_virtual_cluster" {
  name = "Internal Listener Policy Forward to Virtual Cluster"
  config = {
    sni = {
      sni_suffix = ".svc.cluster.local"
    }
  }
  enabled = true
  labels = {
  }
  gateway_id  = konnect_event_gateway.event_gateway_terraform.id
  listener_id = konnect_event_gateway_listener.internal_listener.id
}




// External listener with policies set up for SNI
resource "konnect_event_gateway_listener" "external_listener" {
  addresses = [
    "0.0.0.0"
  ]
  description = "listener for external clients"
  labels = {
  }
  name = "External"
  ports = [
    "9094"
  ]
  gateway_id = konnect_event_gateway.event_gateway_terraform.id
}
resource "konnect_event_gateway_listener_policy_tls_server" "external_listener_policy_tls_server" {
  config = {
    allow_plaintext = false
    certificates = [
      {
        certificate = "$${env[\"KEG_TLS_EXTERNAL_CERT\"]}"
        key         = "$${env[\"KEG_TLS_EXTERNAL_KEY\"]}"
      }
    ]
    versions = {
      max = "TLSv1.3"
      min = "TLSv1.2"
    }
  }
  enabled = true
  labels = {
  }
  name        = "External TLS Server"
  gateway_id  = konnect_event_gateway.event_gateway_terraform.id
  listener_id = konnect_event_gateway_listener.external_listener.id
}
resource "konnect_event_gateway_listener_policy_forward_to_virtual_cluster" "external_listener_policy_forward_to_virtual_cluster" {
  name = "External Listener Policy Forward to Virtual Cluster"
  config = {
    sni = {
      sni_suffix = ".127-0-0-1.sslip.io"
    }
  }
  enabled = true
  labels = {
  }
  gateway_id  = konnect_event_gateway.event_gateway_terraform.id
  listener_id = konnect_event_gateway_listener.external_listener.id
}

# Generate a 32-byte random key and encode it in base64
# Equivalent to: openssl rand -base64 32
resource "random_bytes" "operations_gps_encryption_key" {
  length = 32
}

# Resources for use in policies
resource "konnect_event_gateway_static_key" "operations_gps_encryption_key" {
  name       = "operations-gps-key"
  gateway_id = konnect_event_gateway.event_gateway_terraform.id
  value      = random_bytes.operations_gps_encryption_key.base64

  lifecycle {
    # A replaced key makes records already encrypted with the old key unreadable.
    # Keep the name static (no timestamp()) so routine applies never rotate it.
    create_before_destroy = true
    # The API never returns the key value, so without this every plan would replace it.
    ignore_changes = [value]
  }
}

# Operations VC Policies
resource "konnect_event_gateway_produce_policy_encrypt" "operations_gps_encrypt" {
  name               = "operations-gps-encrypt"
  description        = "Policy to encrypt operations GPS topic"
  gateway_id         = konnect_event_gateway.event_gateway_terraform.id
  virtual_cluster_id = konnect_event_gateway_virtual_cluster.operations_team_vc.id

  enabled   = true
  condition = "context.topic.name == 'vehicle-gps'"
  config = {
    failure_mode   = "passthrough"
    part_of_record = ["value"]
    encryption_key = {
      static = {
        key = {
          id = konnect_event_gateway_static_key.operations_gps_encryption_key.id
        }
      }
    }
  }
}

resource "konnect_event_gateway_consume_policy_decrypt" "operations_gps_decrypt" {
  name               = "operations-gps-decrypt"
  description        = "Policy to decrypt operations GPS topic"
  gateway_id         = konnect_event_gateway.event_gateway_terraform.id
  virtual_cluster_id = konnect_event_gateway_virtual_cluster.operations_team_vc.id

  enabled   = true
  condition = "context.topic.name == 'vehicle-gps'"
  config = {
    failure_mode   = "passthrough"
    part_of_record = ["value"]
    key_sources = [{
      static = {}
      }
    ]
  }
}

# External Partners VC Policies
resource "konnect_event_gateway_consume_policy_schema_validation" "external_partners_consume_schema_validation" {
  name               = "external-partners-consume-schema-validation"
  description        = "Policy to validate schema on external partners topic"
  gateway_id         = konnect_event_gateway.event_gateway_terraform.id
  virtual_cluster_id = konnect_event_gateway_virtual_cluster.external_partners_vc.id

  enabled   = true
  condition = "context.topic.name == 'delivery-updates'"
  config = {
    json = {
      failure_mode   = "mark"
      validate_key   = false # record keys are plain IDs (e.g. DEL-1234), not JSON
      validate_value = true
    }
  }
}

resource "konnect_event_gateway_consume_policy_skip_record" "my_eventgatewayconsumepolicyskiprecord" {
  condition          = " record.value.content['partner'] != 'Amazon'"
  enabled            = true
  name               = "external-partners-consume-skip-record"
  description        = "Policy to skip records based on partner"
  gateway_id         = konnect_event_gateway.event_gateway_terraform.id
  virtual_cluster_id = konnect_event_gateway_virtual_cluster.external_partners_vc.id
  parent_policy_id   = konnect_event_gateway_consume_policy_schema_validation.external_partners_consume_schema_validation.id
}
