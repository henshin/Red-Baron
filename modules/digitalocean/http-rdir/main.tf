terraform {
  required_version = ">= 0.11.0"
}

resource "random_id" "server" {
  count = "${var.instance_count}"
  byte_length = 4
}

resource "tls_private_key" "ssh" {
  count = "${var.instance_count}"
  algorithm = "RSA"
  rsa_bits = 4096
}

resource "digitalocean_ssh_key" "ssh_key" {
  count = "${var.instance_count}"
  name  = "http-rdir-key-${random_id.server.*.hex[count.index]}"
  public_key = "${tls_private_key.ssh.*.public_key_openssh[count.index]}"
}

resource "digitalocean_droplet" "http-rdir" {
  count = "${var.instance_count}"
  image = "debian-9-x64"
  name = "http-rdir-${random_id.server.*.hex[count.index]}"
  region = "${var.available_regions[element(var.regions, count.index)]}"
  ssh_keys = ["${digitalocean_ssh_key.ssh_key.*.id[count.index]}"]
  size = "${var.size}"

  provisioner "remote-exec" {
    inline = [
        "apt-get update",
        "apt-get install -y tmux socat apache2 mosh",
        "a2enmod rewrite proxy proxy_http ssl",
        "systemctl stop apache2",
        "tmux new -d \"socat TCP4-LISTEN:80,fork TCP4:${element(var.redirect_to, count.index)}:80\" ';' split \"socat TCP4-LISTEN:443,fork TCP4:${element(var.redirect_to, count.index)}:443\""
    ]

    connection {
        type = "ssh"
        user = "root"
        private_key = "${tls_private_key.ssh.*.private_key_pem[count.index]}"
    }
  }

  provisioner "local-exec" {
    command = "echo \"${tls_private_key.ssh.*.private_key_pem[count.index]}\" > ./data/ssh_keys/${self.ipv4_address} && echo \"${tls_private_key.ssh.*.public_key_openssh[count.index]}\" > ./data/ssh_keys/${self.ipv4_address}.pub && chmod 600 ./data/ssh_keys/*"
  }

  provisioner "local-exec" {
    when = "destroy"
    command = "rm ./data/ssh_keys/${self.ipv4_address}*"
  }

}

resource "null_resource" "ansible_provisioner" {
  count = "${signum(length(var.ansible_playbook)) == 1 ? var.instance_count : 0}"

  depends_on = ["digitalocean_droplet.http-rdir"]

  triggers {
    droplet_creation = "${join("," , digitalocean_droplet.http-rdir.*.id)}"
    policy_sha1 = "${sha1(file(var.ansible_playbook))}"
  }

  provisioner "local-exec" {
    command = "ansible-playbook ${join(" ", compact(var.ansible_arguments))} --user=root --private-key=./data/ssh_keys/${digitalocean_droplet.http-rdir.*.ipv4_address[count.index]} -e host=${digitalocean_droplet.http-rdir.*.ipv4_address[count.index]} ${var.ansible_playbook}"

    environment {
      ANSIBLE_HOST_KEY_CHECKING = "False"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

data "template_file" "ssh_config" {

  count    = "${var.instance_count}"

  template = "${file("./data/templates/ssh_config.tpl")}"

  depends_on = ["digitalocean_droplet.http-rdir"]

  vars {
    name = "http_rdir_${digitalocean_droplet.http-rdir.*.ipv4_address[count.index]}"
    hostname = "${digitalocean_droplet.http-rdir.*.ipv4_address[count.index]}"
    user = "root"
    identityfile = "${path.root}/data/ssh_keys/${digitalocean_droplet.http-rdir.*.ipv4_address[count.index]}"
  }

}

resource "null_resource" "gen_ssh_config" {

  count = "${var.instance_count}"

  triggers {
    template_rendered = "${data.template_file.ssh_config.*.rendered[count.index]}"
  }

  provisioner "local-exec" {
    command = "echo '${data.template_file.ssh_config.*.rendered[count.index]}' > ./data/ssh_configs/config_${random_id.server.*.hex[count.index]}"
  }

  provisioner "local-exec" {
    when = "destroy"
    command = "rm ./data/ssh_configs/config_${random_id.server.*.hex[count.index]}"
  }

}