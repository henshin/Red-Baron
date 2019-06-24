terraform {
  required_version = ">= 0.11.0"
}

data "aws_region" "current" {
}

resource "random_id" "server" {
  count       = var.instance_count
  byte_length = 4
}

resource "tls_private_key" "ssh" {
  count     = var.instance_count
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "phishing-server" {
  count      = var.instance_count
  key_name   = "phishing-server-key-${count.index}"
  public_key = tls_private_key.ssh[count.index].public_key_openssh
}

resource "aws_instance" "phishing-server" {
  // Currently, variables in provider fields are not supported :(
  // This severely limits our ability to spin up instances in diffrent regions 
  // https://github.com/hashicorp/terraform/issues/11578

  //provider = "aws.${element(var.regions, count.index)}"

  count = var.instance_count

  tags = {
    Name = "phishing-server-${random_id.server[count.index].hex}"
  }

  ami                         = var.amis[data.aws_region.current.name]
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.phishing-server[count.index].key_name
  vpc_security_group_ids      = [aws_security_group.phishing-server.id]
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y tmux apache2 certbot mosh",
      "sudo a2enmod ssl",
      "sudo systemctl stop apache2",
    ]

    connection {
      host        = coalesce(self.public_ip, self.private_ip)
      type        = "ssh"
      user        = "admin"
      private_key = tls_private_key.ssh[count.index].private_key_pem
    }
  }

  provisioner "local-exec" {
    command = "echo \"${tls_private_key.ssh[count.index].private_key_pem}\" > ./data/ssh_keys/${self.public_ip} && echo \"${tls_private_key.ssh[count.index].public_key_openssh}\" > ./data/ssh_keys/${self.public_ip}.pub && chmod 600 ./data/ssh_keys/*"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm ./data/ssh_keys/${self.public_ip}*"
  }
}

resource "null_resource" "ansible_provisioner" {
  count = signum(length(var.ansible_playbook)) == 1 ? var.instance_count : 0

  depends_on = [aws_instance.phishing-server]

  triggers = {
    droplet_creation = join(",", aws_instance.phishing-server.*.id)
    policy_sha1      = filesha1(var.ansible_playbook)
  }

  provisioner "local-exec" {
    command = "ansible-playbook ${join(" ", compact(var.ansible_arguments))} --user=admin --private-key=./data/ssh_keys/${aws_instance.phishing-server[count.index].public_ip} -e host=${aws_instance.phishing-server[count.index].public_ip} ${var.ansible_playbook}"

    environment = {
      ANSIBLE_HOST_KEY_CHECKING = "False"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

data "template_file" "ssh_config" {
  count = var.instance_count

  template = file("./data/templates/ssh_config.tpl")

  depends_on = [aws_instance.phishing-server]

  vars = {
    name         = "dns_rdir_${aws_instance.phishing-server[count.index].public_ip}"
    hostname     = aws_instance.phishing-server[count.index].public_ip
    user         = "admin"
    identityfile = "${path.root}/data/ssh_keys/${aws_instance.phishing-server[count.index].public_ip}"
  }
}

resource "null_resource" "gen_ssh_config" {
  count = var.instance_count

  triggers = {
    template_rendered = data.template_file.ssh_config[count.index].rendered
  }

  provisioner "local-exec" {
    command = "echo '${data.template_file.ssh_config[count.index].rendered}' > ./data/ssh_configs/config_${random_id.server[count.index].hex}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm ./data/ssh_configs/config_${random_id.server[count.index].hex}"
  }
}

