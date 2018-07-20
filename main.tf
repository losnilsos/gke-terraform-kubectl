# Variables Set these using a tfvars file or through environment variables. See terraform documentation
variable "region" {
  default = "europe-west1"
}

variable "project" {
  default = "myproject"
}

variable "environment" {
  default = "dev"
}

variable "name" {
  default = "myapplication"
}

variable "owner" {
  default = "Someone"
}

variable "sqluser" {
  default = "sqlproxy"
}

variable "sqlpassword" {}

// Configure the Google Cloud provider
provider "google" {
  project = "${var.project}"
  region  = "${var.region}"
}

data "google_compute_zones" "available" {}

#Example of a parameterized external file. See below for GKE configuration
data "template_file" "kubernetes_config" {
  template = "${file("${path.module}/configurekubernetes.txt")}"

  vars {
    name    = "${var.name}"
    project = "${var.project}"
    zone    = "${data.google_compute_zones.available.names[0]}"
  }
}

# Ensuring relevant service APIs are enabled in your project. Alternatively visit and enable the needed services
resource "google_project_service" "serviceapi" {
  service            = "serviceusage.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "sqlapi" {
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
  depends_on         = ["google_project_service.serviceapi"]
}

resource "google_project_service" "redisapi" {
  service            = "redis.googleapis.com"
  disable_on_destroy = false
  depends_on         = ["google_project_service.serviceapi"]
}

# Create a VPC and a subnetwork in our region
resource "google_compute_network" "appnetwork" {
  name                    = "vpc-${var.name}"
  auto_create_subnetworks = "false"
}

resource "google_compute_subnetwork" "network-with-private-secondary-ip-ranges" {
  name          = "${var.name}-${var.environment}-subnetwork"
  ip_cidr_range = "10.2.0.0/16"
  region        = "europe-west1"
  network       = "${google_compute_network.appnetwork.self_link}"

  secondary_ip_range {
    range_name    = "kubernetes-secondary-range-pods"
    ip_cidr_range = "10.60.0.0/16"
  }

  secondary_ip_range {
    range_name    = "kubernetes-secondary-range-services"
    ip_cidr_range = "10.70.0.0/16"
  }
}

# GKE cluster setup
resource "google_container_cluster" "primary" {
  name               = "cluster-${var.name}"
  zone               = "${data.google_compute_zones.available.names[0]}"
  initial_node_count = 1
  description        = "Kubernetes Cluster"
  network            = "${google_compute_network.appnetwork.self_link}"
  subnetwork         = "${google_compute_subnetwork.network-with-private-secondary-ip-ranges.self_link}"
  depends_on         = ["google_project_service.serviceapi"]

  additional_zones = [
    "${data.google_compute_zones.available.names[1]}",
    "${data.google_compute_zones.available.names[2]}",
  ]

  master_auth {
    username = "gkeadministrator"
    password = "Thisisareallylongpassword"
  }

  #Example of local provisioning of container apps after deploy. not recommended for production
  #provisioner "local-exec" {
  #    command = "${data.template_file.kubernetes_config.rendered}"
  #}
  ip_allocation_policy {
    cluster_secondary_range_name  = "kubernetes-secondary-range-pods"
    services_secondary_range_name = "kubernetes-secondary-range-services"
  }

  node_config {
    oauth_scopes = [
      "https://www.googleapis.com/auth/compute",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    labels {
      name        = "${var.name}"
      owner       = "${var.owner}"
      environment = "${var.environment}"
    }

    tags = ["kubernetes", "${var.environment}"]
  }
}

resource "google_sql_database_instance" "master" {
  name             = "${var.name}-sql"
  database_version = "MYSQL_5_7"
  region           = "${var.region}"
  depends_on       = ["google_project_service.sqlapi"]

  settings {
    # Second-generation instance tiers are based on the machine
    # type. See argument reference below.
    tier = "db-n1-standard-1"

    user_labels {
      name        = "${var.name}"
      owner       = "${var.owner}"
      environment = "${var.environment}"
    }
  }
}

resource "google_sql_database" "database1" {
  name     = "db1-db"
  instance = "${google_sql_database_instance.master.name}"
}

resource "google_sql_user" "users" {
  name     = "${var.sqluser}"
  instance = "${google_sql_database_instance.master.name}"
  host     = "%"
  password = "${var.sqlpassword}"
}

resource "google_redis_instance" "redis" {
  name               = "redis"
  tier               = "BASIC"
  memory_size_gb     = 1
  depends_on         = ["google_project_service.redisapi"]
  authorized_network = "${google_compute_network.appnetwork.self_link}"
  region             = "${var.region}"
  location_id        = "${data.google_compute_zones.available.names[0]}"

  redis_version = "REDIS_3_2"
  display_name  = "Redis Instance"

  labels {
    name        = "${var.name}"
    owner       = "${var.owner}"
    environment = "${var.environment}"
  }
}

# The following outputs allow authentication and connectivity to the GKE Cluster.
output "client_certificate" {
  value = "${google_container_cluster.primary.master_auth.0.client_certificate}"
}

output "client_key" {
  value = "${google_container_cluster.primary.master_auth.0.client_key}"
}

output "cluster_ca_certificate" {
  value = "${google_container_cluster.primary.master_auth.0.cluster_ca_certificate}"
}
