terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket       = "tfstate-923788823291-us-east-2"
    key          = "parte2-sdn/terraform.tfstate"
    region       = "us-east-2"
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-2"
}

locals {
  ryu_ip = "192.168.3.40"
  ovs_ip = "192.168.3.41"

  hosts = {
    ventas         = { ip = "192.168.0.20",  overlay = "192.168.16.10/20",  vx = "vx_ven" }
    produccion     = { ip = "192.168.2.20",  overlay = "192.168.18.10/20",  vx = "vx_pro" }
    ingenieria     = { ip = "192.168.3.30",  overlay = "192.168.19.10/20",  vx = "vx_ing" }
    administracion = { ip = "192.168.3.140", overlay = "192.168.19.130/20", vx = "vx_adm" }
  }

  ovs_ports = join("\n", [
    for k, h in local.hosts :
    "ovs-vsctl --may-exist add-port s1 ${h.vx} -- set interface ${h.vx} type=vxlan options:remote_ip=${h.ip} options:key=100"
  ])
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

# Red creada en la Parte 1
data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = ["VPC-GlobalTech"]
  }
}

data "aws_subnet" "dep" {
  for_each = toset(["ventas", "produccion", "ingenieria", "administracion"])
  vpc_id   = data.aws_vpc.main.id
  filter {
    name   = "tag:Name"
    values = ["Subred-${each.key}"]
  }
}

resource "aws_security_group" "sdn" {
  name   = "sdn-lab-sg"
  vpc_id = data.aws_vpc.main.id

  ingress {
    description = "ICMP interno"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["192.168.0.0/20"]
  }
  ingress {
    description = "OpenFlow (Ryu)"
    from_port   = 6653
    to_port     = 6653
    protocol    = "tcp"
    cidr_blocks = ["192.168.0.0/20"]
  }
  ingress {
    description = "VXLAN (overlay SDN)"
    from_port   = 4789
    to_port     = 4789
    protocol    = "udp"
    cidr_blocks = ["192.168.0.0/20"]
  }
  ingress {
    description = "SSH desde EC2 Instance Connect (us-east-2)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["3.16.146.0/29"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Controlador Ryu (plano de control)
resource "aws_instance" "ryu" {
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnet.dep["ingenieria"].id
  private_ip                  = local.ryu_ip
  vpc_security_group_ids      = [aws_security_group.sdn.id]
  user_data_replace_on_change = true
  tags                        = { Name = "SDN-Ryu-Controlador" }

  user_data = <<-EOT
    #!/bin/bash
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3-pip python3-ryu
    cat > /etc/systemd/system/ryu.service <<'EOS'
    [Unit]
    Description=Ryu SDN Controller
    After=network-online.target
    Wants=network-online.target
    [Service]
    ExecStart=/usr/bin/env ryu-manager ryu.app.simple_switch_13 --verbose
    [Install]
    WantedBy=multi-user.target
    EOS
    systemctl daemon-reload
    systemctl enable --now ryu
  EOT
}

# Switch Open vSwitch (plano de datos)
resource "aws_instance" "ovs" {
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnet.dep["ingenieria"].id
  private_ip                  = local.ovs_ip
  vpc_security_group_ids      = [aws_security_group.sdn.id]
  user_data_replace_on_change = true
  tags                        = { Name = "SDN-OVS-Switch" }

  user_data = <<-EOT
    #!/bin/bash
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y openvswitch-switch
    ovs-vsctl --may-exist add-br s1
    ovs-vsctl set bridge s1 protocols=OpenFlow13
    ovs-vsctl set-fail-mode s1 secure
    ovs-vsctl set-controller s1 tcp:${local.ryu_ip}:6653
    ovs-vsctl set controller s1 connection-mode=out-of-band
    ${local.ovs_ports}
  EOT
}

# VMs de los departamentos (conectadas al switch por VXLAN)
resource "aws_instance" "host" {
  for_each                    = local.hosts
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnet.dep[each.key].id
  private_ip                  = each.value.ip
  vpc_security_group_ids      = [aws_security_group.sdn.id]
  user_data_replace_on_change = true
  tags                        = { Name = "SDN-${each.key}" }

  user_data = <<-EOT
    #!/bin/bash
    cat > /usr/local/bin/overlay-up.sh <<'EOS'
    #!/bin/bash
    IFACE=$(ip route show default | awk '{print $5}' | head -1)
    ip link add vxlan0 type vxlan id 100 remote ${local.ovs_ip} dstport 4789 dev $IFACE 2>/dev/null
    ip addr add ${each.value.overlay} dev vxlan0 2>/dev/null
    ip link set vxlan0 up
    EOS
    chmod +x /usr/local/bin/overlay-up.sh
    cat > /etc/systemd/system/overlay.service <<'EOS'
    [Unit]
    Description=Overlay VXLAN SDN
    After=network-online.target
    Wants=network-online.target
    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/usr/local/bin/overlay-up.sh
    [Install]
    WantedBy=multi-user.target
    EOS
    systemctl daemon-reload
    systemctl enable --now overlay
  EOT
}

output "servidores" {
  value = merge(
    { ryu = { privada = aws_instance.ryu.private_ip, publica = aws_instance.ryu.public_ip } },
    { ovs = { privada = aws_instance.ovs.private_ip, publica = aws_instance.ovs.public_ip } },
    { for k, i in aws_instance.host : k => { privada = i.private_ip, publica = i.public_ip } }
  )
}