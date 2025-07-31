# vm.tf

resource "google_compute_instance" "mongodb_vm" {
  name         = "mongodb-vm"
  machine_type = "e2-medium"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = var.outdated_linux_image # ★★★ 要件: 古いOS ★★★
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.public_subnet.id
    access_config {
      // パブリックIPを自動的に割り当て
    }
  }

  # main.tf で作成したサービスアカウント
  service_account {
    email  = google_service_account.mongodb_vm_sa.email
    scopes = ["cloud-platform"]
  }

  # 起動スクリプトを外部ファイルから読込
  metadata = {
    startup-script = file("${path.module}/startup-script.sh")
  }

  # main.tf のファイアウォールルールを適用
  tags = ["mongodb-server"]

}
