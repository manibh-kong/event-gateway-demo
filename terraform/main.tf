terraform {
  required_providers {
    konnect = {
      source  = "Kong/konnect"
      version = "~> 3.30"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "konnect" {
  server_url            = var.konnect_server_url
  personal_access_token = var.konnect_token
}

provider "random" {
}
