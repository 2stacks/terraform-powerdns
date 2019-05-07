# instance the provider
provider "libvirt" {
  uri = "${var.libvirt_uri}"
}

data "template_file" "user_data" {
  template = "${file("${path.module}/templates/cloud_init.yml")}"

  vars {
    user_name          = "${var.user_name}"
    ssh_authorized-key = "${var.ssh_authorized-key}"
  }
}

data "template_file" "meta_data" {
  count    = "${var.guest_count}"
  template = "${file("${path.module}/templates/meta_data.yml")}"

  vars {
    hostname = "${format("${var.hostname}%01d", count.index + 1)}"
  }
}

data "template_file" "network_config" {
  template = "${file("${path.module}/templates/network_config.yml")}"
}

data "template_file" "xslt_config" {
  template = "${file("${path.module}/templates/override.xsl")}"

  vars {
    network    = "${var.network}"
    port_group = "${var.port_group}"
  }
}

data "template_file" "nginx_config" {
  count    = "${var.guest_count}"
  template = "${file("${path.module}/templates/powerdns-admin.conf")}"

  vars {
    hostname    = "${format("${var.hostname}%01d", count.index + 1)}"
    domain_name = "${var.domain_name}"
  }
}

# We fetch the latest ubuntu release image from their mirrors
resource "libvirt_volume" "ubuntu-qcow2" {
  name   = "${var.prefix}-ubuntu.qcow2"
  pool   = "${var.libvirt_volume_pool}"
  source = "${var.libvirt_volume_source}"
  format = "qcow2"
}

resource "libvirt_volume" "ubuntu-qcow2_resized" {
  name           = "${format("${var.prefix}-%01d.qcow2", count.index + 1)}"
  base_volume_id = "${libvirt_volume.ubuntu-qcow2.id}"
  pool           = "${var.libvirt_volume_pool}"
  size           = "${var.libvirt_volume_size}"
  count          = "${var.guest_count}"
}

# for more info about paramater check this out
# https://github.com/dmacvicar/terraform-provider-libvirt/blob/master/website/docs/r/cloudinit.html.markdown
# Use CloudInit to add our ssh-key to the instance
# you can add also meta_data field
resource "libvirt_cloudinit_disk" "commoninit" {
  name           = "${format("${var.prefix}-seed-%01d.iso", count.index + 1)}"
  pool           = "${var.libvirt_volume_pool}"
  user_data      = "${data.template_file.user_data.rendered}"
  meta_data      = "${data.template_file.meta_data.*.rendered[count.index]}"
#  network_config = "${data.template_file.network_config.rendered}"
  count          = "${var.guest_count}"
}

# Create the machine
resource "libvirt_domain" "domain-ubuntu" {
  count      = "${var.guest_count}"
  name       = "${format("${var.hostname}%01d-${var.prefix}", count.index + 1)}"
  memory     = "${var.memory}"
  vcpu       = "${var.vcpu}"
  qemu_agent = true
  cloudinit  = "${element(libvirt_cloudinit_disk.commoninit.*.id, count.index)}"

  network_interface {
    network_name   = "${var.network}"
    mac            = "${format("${var.mac_prefix}:%02d", count.index + 1)}"
    wait_for_lease = true
  }
  # used to support features the provider does not allow to set from the schema
  xml {
    xslt = "${data.template_file.xslt_config.rendered}"
  }
  # IMPORTANT: this is a known bug on cloud images, since they expect a console
  # we need to pass it
  # https://bugs.launchpad.net/cloud-images/+bug/1573095
  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }
  console {
    type        = "pty"
    target_type = "virtio"
    target_port = "1"
  }
  disk {
    volume_id = "${element(libvirt_volume.ubuntu-qcow2_resized.*.id, count.index)}"
  }
  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }

  connection {
    type        = "ssh"
    private_key = "${file("~/.ssh/do_rsa")}"
    user        = "${var.user_name}"
    timeout     = "2m"
  }

  provisioner "file" {
    source      = "templates/configure_db.sh"
    destination = "/tmp/configure_db.sh"
  }

  provisioner "file" {
    source      = "templates/powerdns-admin.service"
    destination = "/tmp/powerdns-admin.service"
  }

  provisioner "file" {
    source      = "templates/self-signed.conf"
    destination = "/tmp/self-signed.conf"
  }

  provisioner "file" {
    source      = "templates/ssl-params.conf"
    destination = "/tmp/ssl-params.conf"
  }

  provisioner "file" {
    content     = "${data.template_file.nginx_config.*.rendered[count.index]}"
    destination = "/tmp/powerdns-admin.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/configure_db.sh",
      "/tmp/configure_db.sh ${var.mysql_root_pass} ${var.mysql_user} ${var.mysql_user_pass} ${var.domain_name}",
      "sudo systemctl disable systemd-resolved",
      "sudo systemctl stop systemd-resolved",
      "sudo sh -c \"sed -i 's/gmysql-user=.*/gmysql-user=${var.mysql_user}/g' /etc/powerdns/pdns.d/pdns.local.gmysql.conf\"",
      "sudo sh -c \"sed -i 's/gmysql-password=.*/gmysql-password=${var.mysql_user_pass}/g' /etc/powerdns/pdns.d/pdns.local.gmysql.conf\"",
      "sudo sh -c \"sed -i 's/# webserver=.*/webserver=yes/g' /etc/powerdns/pdns.conf\"",
      "sudo sh -c \"sed -i 's/# api=.*/api=yes/g' /etc/powerdns/pdns.conf\"",
      "sudo sh -c \"sed -i 's/# api-key=.*/api-key=${var.api_key}/g' /etc/powerdns/pdns.conf\"",
      "sudo sh -c \"sed -i 's/# default-soa-name=.*/default-soa-name=${format("${var.hostname}%01d", count.index + 1)}.${var.domain_name}./g' /etc/powerdns/pdns.conf\"",
      "sudo sh -c \"sed -i 's/# local-address=.*/local-address=127.0.0.1/g' /etc/powerdns/pdns.conf\"",
      "sudo sh -c \"sed -i 's/# local-port=.*/local-port=5300/g' /etc/powerdns/pdns.conf\"",
      "sudo sh -c \"sed -i 's/# webserver-address=.*/webserver-address=0.0.0.0/g' /etc/powerdns/pdns.conf\"",
      "sudo sh -c \"sed -i 's/# webserver-allow-from=.*/webserver-allow-from=${var.api_allow_from}/g' /etc/powerdns/pdns.conf\"",
      "sudo sh -c \"sed -i 's/local-address=.*/local-address=0.0.0.0/g' /etc/powerdns/recursor.conf\"",
      "sudo sh -c \"sed -i 's/# forward-zones=.*/forward-zones=${var.domain_name}=127.0.0.1:5300/g' /etc/powerdns/recursor.conf\"",
      "sudo systemctl restart pdns",
      "sudo systemctl restart pdns-recursor",
      "sudo rm /etc/resolv.conf",
      "sudo sh -c 'echo \"nameserver 127.0.0.1\nsearch ${var.domain_name}\" > /etc/resolv.conf'",
      "sudo git clone https://github.com/ngoduykhanh/PowerDNS-Admin.git /opt/powerdns-admin",
      "sudo chown -R ${var.user_name}:${var.user_name} /opt/powerdns-admin",
      "cd /opt/powerdns-admin",
      "virtualenv -p python3 flask",
      ". ./flask/bin/activate",
      "pip install -r requirements.txt",
      "cp config_template.py config.py && chmod 600 config.py",
      "sed -i \"s/SQLA_DB_USER =.*/SQLA_DB_USER = '${var.mysql_user}'/g\" config.py",
      "sed -i \"s/SQLA_DB_PASSWORD =.*/SQLA_DB_PASSWORD = '${var.mysql_user_pass}'/g\" config.py",
      "sed -i \"s/SQLA_DB_NAME =.*/SQLA_DB_NAME = 'pdnsadmin'/g\" config.py",
      "export FLASK_APP=app/__init__.py",
      "flask db upgrade",
      "flask db migrate -m \"Init DB\"",
      "yarn install --pure-lockfile",
      "flask assets build",
      "sudo mv /tmp/powerdns-admin.service /etc/systemd/system/",
      "sudo systemctl daemon-reload",
      "sudo systemctl start powerdns-admin",
      "sudo systemctl enable powerdns-admin",
      "sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout /etc/ssl/private/nginx-selfsigned.key -out /etc/ssl/certs/nginx-selfsigned.crt -subj \"/C=${var.ssl_c}/ST=${var.ssl_st}/L=${var.ssl_l}/O=${var.ssl_o}/OU=${var.ssl_ou}/CN=${format("${var.hostname}%01d", count.index + 1)}.${var.domain_name}\"",
      "sudo openssl dhparam -out /etc/nginx/dhparam.pem 2048",
      "sudo mv /tmp/self-signed.conf /etc/nginx/snippets/self-signed.conf",
      "sudo mv /tmp/ssl-params.conf /etc/nginx/snippets/ssl-params.conf",
      "sudo mv /tmp/powerdns-admin.conf /etc/nginx/conf.d/powerdns-admin.conf",
      "sudo rm /etc/nginx/sites-enabled/default",
      "sudo nginx -t",
      "sudo systemctl restart nginx",
    ]
  }
}

# IPs: use wait_for_lease true or after creation use terraform refresh and terraform show for the ips of domain
output "ip" {
  value = "${libvirt_domain.domain-ubuntu.*.network_interface.0.addresses}"
}
