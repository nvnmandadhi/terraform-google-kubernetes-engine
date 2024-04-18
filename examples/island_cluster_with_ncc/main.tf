/**
 * Copyright 2024 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

resource "random_id" "rand" {
  byte_length = 4
}

resource "google_service_account" "gke-sa" {
  account_id = "gke-sa-${random_id.rand.hex}"
  project    = var.project_id
}

module "net" {
  source  = "terraform-google-modules/network/google"
  version = "~> 9.0"

  network_name = "gke-net-${random_id.rand.hex}"
  routing_mode = "GLOBAL"
  project_id   = var.project_id

  subnets = [
    {
      subnet_name           = "${var.cluster_name}-${var.region}-snet"
      subnet_ip             = var.subnet_cidr
      subnet_region         = var.region
      subnet_private_access = "true"
    },
    {
      subnet_name   = "${var.cluster_name}-${var.region}-proxy-snet"
      subnet_ip     = var.proxy_subnet_cidr
      subnet_region = var.region
      purpose       = "REGIONAL_MANAGED_PROXY"
      role          = "ACTIVE"
    },
    {
      subnet_name           = "${var.cluster_name}-${var.region}-psc-snet"
      subnet_ip             = var.psc_subnet_cidr
      subnet_region         = var.region
      subnet_private_access = "true"
      purpose               = "PRIVATE_SERVICE_CONNECT"
    },
    {
      subnet_name           = "${var.cluster_name}-${var.region}-private-nat-snet"
      subnet_ip             = var.private_nat_subnet_cidr
      subnet_region         = var.region
      subnet_private_access = "true"
      purpose               = "PRIVATE_NAT"
    }
  ]

  secondary_ranges = {
    "${var.cluster_name}-${var.region}-snet" = [
      {
        range_name    = "${var.cluster_name}-${var.region}-snet-pods"
        ip_cidr_range = var.secondary_ranges["pods"]
      },
      {
        range_name    = "${var.cluster_name}-${var.region}-snet-services"
        ip_cidr_range = var.secondary_ranges["services"]
      },
    ]
  }

  firewall_rules = [
    {
      name      = "${var.cluster_name}-iap"
      direction = "INGRESS"
      allow = [
        {
          protocol = "TCP"
          ports    = ["22"]
        }
      ]
      ranges = ["35.235.240.0/20"]
    },
    {
      name      = "${var.cluster_name}-tcp-primary"
      direction = "INGRESS"
      allow = [
        {
          protocol = "TCP"
        }
      ]
      ranges = [
        var.subnet_cidr,
        var.secondary_ranges["pods"]
      ]
    },
    {
      name      = "${var.cluster_name}-allow-psc"
      direction = "INGRESS"
      allow = [
        {
          protocol = "TCP"
        }
      ]
      ranges                  = [var.psc_subnet_cidr]
      target_service_accounts = [google_service_account.gke-sa.email]
    },
    {
      name      = "${var.cluster_name}-allow-proxy"
      direction = "INGRESS"
      allow = [
        {
          protocol = "TCP"
        }
      ]
      ranges                  = [var.proxy_subnet_cidr]
      target_service_accounts = [google_service_account.gke-sa.email]
    },
  ]
}

resource "google_network_connectivity_hub" "hub" {
  provider = google-beta

  name        = "ncc-hub"
  project     = var.project_id
  description = "ncc hub for inter vpc nat"
}

resource "google_network_connectivity_spoke" "spoke" {
  provider = google-beta

  name        = "cluster-spoke-${random_id.rand.hex}"
  project     = var.project_id
  location    = "global"
  description = "vpc spoke for inter vpc nat"
  hub         = google_network_connectivity_hub.hub.id
  linked_vpc_network {
    exclude_export_ranges = [
      var.secondary_ranges["pods"],
      var.secondary_ranges["services"],
      var.secondary_ranges["master_cidr"],
      var.proxy_subnet_cidr,
      var.psc_subnet_cidr,
      var.private_nat_subnet_cidr
    ]
    uri = module.net.network_self_link
  }
}

module "gke" {
  source  = "terraform-google-modules/kubernetes-engine/google//modules/beta-private-cluster"
  version = "~> 30.0"

  name                                 = var.cluster_name
  project_id                           = var.project_id
  region                               = var.region
  release_channel                      = "RAPID"
  zones                                = var.node_locations
  network                              = module.net.network_name
  subnetwork                           = "${var.cluster_name}-${var.region}-snet"
  ip_range_pods                        = "${var.cluster_name}-${var.region}-snet-pods"
  ip_range_services                    = "${var.cluster_name}-${var.region}-snet-services"
  enable_private_endpoint              = true
  enable_private_nodes                 = true
  datapath_provider                    = "ADVANCED_DATAPATH"
  monitoring_enable_managed_prometheus = false
  enable_shielded_nodes                = true
  master_global_access_enabled         = false
  master_ipv4_cidr_block               = var.secondary_ranges["master_cidr"]
  master_authorized_networks           = var.master_authorized_networks
  deletion_protection                  = false
  remove_default_node_pool             = true
  disable_default_snat                 = true
  gateway_api_channel                  = "CHANNEL_STANDARD"

  node_pools = [
    {
      name                      = "default"
      machine_type              = "e2-highcpu-2"
      min_count                 = 1
      max_count                 = 100
      local_ssd_count           = 0
      spot                      = true
      local_ssd_ephemeral_count = 0
      disk_size_gb              = 100
      disk_type                 = "pd-standard"
      image_type                = "COS_CONTAINERD"
      logging_variant           = "DEFAULT"
      auto_repair               = true
      auto_upgrade              = true
      service_account           = google_service_account.gke-sa.email
      initial_node_count        = 1
      enable_secure_boot        = true
    },
  ]

  node_pools_tags = {
    all = ["gke-${random_id.rand.hex}"]
  }

  node_pools_oauth_scopes = {
    all = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]
  }

  timeouts = {
    create = "15m"
    update = "15m"
    delete = "15m"
  }
}

module "cloud_router" {
  source  = "terraform-google-modules/cloud-router/google"
  version = "~> 6.0"
  name    = "router-${random_id.rand.hex}"
  project = var.project_id
  network = module.net.network_name
  region  = var.region
}

resource "google_compute_router_nat" "nat_type" {
  provider = google-beta

  name                               = "private-nat-${random_id.rand.hex}"
  router                             = module.cloud_router.router.name
  project                            = var.project_id
  region                             = var.region
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  type                               = "PRIVATE"
  rules {
    rule_number = 100
    description = "rule for private nat"
    match       = "nexthop.hub == \"//networkconnectivity.googleapis.com/${google_network_connectivity_hub.hub.id}\""
    action {
      source_nat_active_ranges = [
        module.net.subnets["${var.region}/${var.cluster_name}-${var.region}-private-nat-snet"]["self_link"]
      ]
    }
  }
}

resource "google_gke_hub_membership" "primary" {
  provider = google-beta

  project       = var.project_id
  membership_id = "${var.project_id}-${module.gke.name}"
  location      = var.region

  endpoint {
    gke_cluster {
      resource_link = "//container.googleapis.com/${module.gke.cluster_id}"
    }
  }
  authority {
    issuer = "https://container.googleapis.com/v1/${module.gke.cluster_id}"
  }
}
