# Deploy PowerDNS with Terraform
Used to provision a PowerDNS server with PowerDNS-Admin interface in a libvirt environment

Adapted from - https://blog.jonaharagon.com/installing-powerdns-admin-on-ubuntu-18-04/

Note: This project is customized for KVM servers running Openvswitch.  Installation of these dependencies can be
complex and is outside the scope of this project.

The PowerDNS server configuration provided by this project will install an authoritative and recursive server as documented here:

- https://doc.powerdns.com/authoritative/guides/recursion.html#scenario-1-authoritative-server-as-recursor-with-private-zones

It has also been customized for use with the Terraform PowerDNS provider.
- https://www.terraform.io/docs/providers/powerdns/index.html

### Prereqs
KVM Server running Openvswitch

- https://github.com/mrlesmithjr/ansible-kvm
- https://docs.openvswitch.org/en/latest/intro/install/distributions/

Terraform and the terraform-provider-libvirt

- https://www.terraform.io/downloads.html
- https://github.com/dmacvicar/terraform-provider-libvirt#installing


### Setup
Clone Repository
```bash
git clone https://github.com/2stacks/terraform-powerdns.git
cd terraform-powerdns
```

Create secrets variable file, add your SSH public key and update database passwords.
```bash
cp secret.auto.tfvars.example secret.auto.tfvars
```

Deploy libvirt guest with Terraform
```bash
terraform init
terraform plan
terraform apply
```

When Terraform finishes it will output the libvirt guest IP

Example:
```bash
Outputs:

ip = [
    [
        192.168.100.12,
        fe80::5054:ff:fec2:43bd
    ]
]
```

Open `https://(output_ip)/login` in your browser and register a new admin account.

### TODO
- Secure PowerDNS-Admin interface with LetsEncrypt
- Secure PowerDNS API server with LetsEncrypt
- Move Terraform 'remote-exec' calls to shell scripts