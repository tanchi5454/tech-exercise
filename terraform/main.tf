# main.tf

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.50.0"
    }
  }

  # ★★★ Terraformの状態を管理する事前作成GCSバケットを指定 ★★★
  backend "gcs" {
    bucket = "clgcporg10-169-terraform-state" 
    prefix = "terraform/state"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# ★★★事前作成GitHub Actions用サービスアカウントのIAM設定 ★★★
data "google_service_account" "iac_operations_sa" {
  account_id = "iac-operations-sa"
}

# GitHub Actions用サービスアカウントのIAMロールの定義と付与 
locals {
  iac_operations_roles = toset([
    "roles/storage.objectViewer",
    "roles/secretmanager.secretAccessor",
    "roles/container.developer",
    "roles/artifactregistry.writer",
  ])
}

# for_eachを使い、GitHub Actions用サービスアカウントにロールを付与
resource "google_project_iam_member" "iac_operations_roles" {
  for_each = local.iac_operations_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${data.google_service_account.iac_operations_sa.email}"
}

# --- MongoDB VM用サービスアカウントのIAM設定 ---
resource "google_service_account" "mongodb_vm_sa" {
  account_id   = "mongodb-vm-sa"
  display_name = "Service Account for MongoDB VM"
}

# MongoDB VM用サービスアカウントのIAMロールの定義と付与
locals {
  mongodb_vm_roles = toset([
    "roles/compute.admin",
    "roles/logging.logWriter",
    "roles/secretmanager.secretAccessor",
  ])
}

# for_eachを使い、MongoDB VM用サービスアカウントにロールを付与 
resource "google_project_iam_member" "mongodb_vm_roles" {
  for_each = local.mongodb_vm_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.mongodb_vm_sa.email}"
}

# --- ネットワーク関連リソース ---

# カスタムVPCの作成
resource "google_compute_network" "wiz_vpc" {
  name                    = "wiz-vpc"
  auto_create_subnetworks = false
}

# GKEクラスタ用のプライベートサブネット
resource "google_compute_subnetwork" "private_subnet" {
  name          = "private-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.wiz_vpc.id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.10.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.20.0.0/16"
  }
}

# MongoDB VM用のパブリックサブネット
resource "google_compute_subnetwork" "public_subnet" {
  name          = "public-subnet"
  ip_cidr_range = "10.0.2.0/24"
  region        = var.region
  network       = google_compute_network.wiz_vpc.id
}

# Cloud NATのルーター（プライベートサブネットからのアウトバウンド通信用）
resource "google_compute_router" "router" {
  name    = "wiz-nat-router"
  network = google_compute_network.wiz_vpc.id
  region  = var.region
}

# Cloud NATゲートウェイの設定
resource "google_compute_router_nat" "nat" {
  name                               = "wiz-nat-gateway"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
  subnetwork {
    name                    = google_compute_subnetwork.private_subnet.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# ファイアウォールルール
resource "google_compute_firewall" "allow_internal" {
  name    = "allow-internal"
  network = google_compute_network.wiz_vpc.name
  allow {
    protocol = "all"
  }
  source_ranges = ["10.0.1.0/24", "10.0.2.0/24"]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.wiz_vpc.name
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"] // 要件: インターネットからのSSHを許可
}

# 外部からMongoDBへの接続を許可するファイアウォールルール
resource "google_compute_firewall" "allow_mongo_external" {
  name    = "allow-mongo-external-ingress"
  network = google_compute_network.wiz_vpc.name
  allow {
    protocol = "tcp"
    ports    = ["27017"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["mongodb-server"] # vm.tfでmongodb-vmに設定されているタグ
  description   = "Allow external ingress to MongoDB port"
}

# --- DBバックアップ用のGCSバケット ---

# インターネット非公開、特定のサービスアカウントのみがアクセス
resource "google_storage_bucket" "db_backups" {
  name          = "${var.project_id}-db-backups"
  location      = var.region
  force_destroy = true // デモ環境のクリーンアップを容易する

  # バケット内の全オブジェクトに対して均一なアクセス制御を強制
  uniform_bucket_level_access = true
}

# MongoDB VMのサービスアカウントのみバケットへのオブジェクト管理権限を付与
resource "google_storage_bucket_iam_member" "db_backup_writer" {
  bucket = google_storage_bucket.db_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.mongodb_vm_sa.email}"
}
