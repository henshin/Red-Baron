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

resource "aws_key_pair" "http-rdir" {
  count      = var.instance_count
  key_name   = "http-rdir-key-${count.index}"
  public_key = tls_private_key.ssh[count.index].public_key_openssh
}

resource "aws_instance" "http-rdir" {
  // Currently, variables in provider fields are not supported :(
  // This severely limits our ability to spin up instances in diffrent regions 
  // https://github.com/hashicorp/terraform/issues/11578

  //provider = "aws.${element(var.regions, count.index)}"

  count = var.instance_count

  tags = {
    Name = "http-rdir-${random_id.server[count.index].hex}"
  }

  ami                         = var.amis[data.aws_region.current.name]
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.http-rdir[count.index].key_name
  vpc_security_group_ids      = [aws_security_group.http-rdir.id]
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y tmux socat apache2 mosh",
      "sudo a2enmod rewrite proxy proxy_http ssl",
      "sudo systemctl stop apache2",
      
    ]
// "tmux new -d \"sudo socat TCP4-LISTEN:80,fork TCP4:${element(var.redirect_to, count.index)}:80\" ';' split \"sudo socat TCP4-LISTEN:443,fork TCP4:${element(var.redirect_to, count.index)}:443\"",
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

  depends_on = [aws_instance.http-rdir]

  triggers = {
    droplet_creation = join(",", aws_instance.http-rdir.*.id)
    policy_sha1      = filesha1(var.ansible_playbook)
  }

  provisioner "local-exec" {
    command = "ansible-playbook ${join(" ", compact(var.ansible_arguments))} --user=admin --private-key=./data/ssh_keys/${aws_instance.http-rdir[count.index].public_ip} -e host=${aws_instance.http-rdir[count.index].public_ip} ${var.ansible_playbook}"

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
  depends_on = [aws_instance.http-rdir]	

  template = file("./data/templates/ssh_config.tpl")
  
  vars = {
    name         = "dns_rdir_${aws_instance.http-rdir[count.index].public_ip}"
    hostname     = aws_instance.http-rdir[count.index].public_ip
    user         = "admin"
    identityfile = "${path.root}/data/ssh_keys/${aws_instance.http-rdir[count.index].public_ip}"
  }
}

resource "null_resource" "gen_ssh_config" {
  count = var.instance_count

  //triggers = {
  //  template_rendered = data.template_file.ssh_config[count.index].rendered
  //}

  provisioner "local-exec" {
    command = "echo '${data.template_file.ssh_config[count.index].rendered}' > ./data/ssh_configs/config_${random_id.server[count.index].hex}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm ./data/ssh_configs/config_${random_id.server[count.index].hex}"
    //command = "echo rm ./data/ssh_configs/config_whatever here"
  }
}

