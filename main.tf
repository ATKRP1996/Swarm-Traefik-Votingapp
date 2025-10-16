#############################################
# Provider
#############################################
terraform {
  required_version = ">= 1.4.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name_prefix  = "swarm-traefik"
  vpc_cidr     = var.vpc_cidr
  public_cidrs = var.public_subnet_cidrs
  az_count     = length(local.public_cidrs) <= length(data.aws_availability_zones.available.names) ? length(local.public_cidrs) : length(data.aws_availability_zones.available.names)
  tags = {
    Project     = local.name_prefix
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

#############################################
# VPC + Internet access
#############################################
resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${local.name_prefix}-igw" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-public-rt" })
}

resource "aws_subnet" "public" {
  for_each = {
    for idx, cidr in slice(local.public_cidrs, 0, local.az_count) :
    idx => {
      cidr = cidr
      az   = data.aws_availability_zones.available.names[idx]
    }
  }

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-public-${each.value.az}"
    Tier = "public"
  })
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

#############################################
# Security group for Swarm/Traefik
#############################################
resource "aws_security_group" "swarm" {
  name        = "${local.name_prefix}-sg"
  description = "Ingress for Docker Swarm + Traefik behind NLB"
  vpc_id      = aws_vpc.main.id

  # SSH (tighten in real deployments)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP/HTTPS (NLB health checks + traffic)
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Swarm management
  ingress {
    description = "Swarm manager"
    from_port   = 2377
    to_port     = 2377
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  # Gossip
  ingress {
    description = "Serf TCP"
    from_port   = 7946
    to_port     = 7946
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  ingress {
    description = "Serf UDP"
    from_port   = 7946
    to_port     = 7946
    protocol    = "udp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  # Overlay
  ingress {
    description = "Overlay (VXLAN)"
    from_port   = 4789
    to_port     = 4789
    protocol    = "udp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-sg" })
}

#############################################
# EC2 instances (1 manager, 2 workers)
#############################################
resource "aws_instance" "swarm_master" {
  count                       = 1
  ami                         = var.ami
  instance_type               = var.instance_type
  subnet_id                   = element([for s in aws_subnet.public : s.id], 0)
  vpc_security_group_ids      = [aws_security_group.swarm.id]
  associate_public_ip_address = true
  key_name                    = var.key_name

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-master-${count.index + 1}"
    Role = "manager"
  })
  provisioner "file" {
    source      = var.key_path
    destination = "/home/ubuntu/myawskey.pem"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.key_path)
      host        = self.public_ip
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update -y",
      "sudo apt-get install -y docker.io",
      "sudo systemctl start docker",
      "sudo systemctl enable docker",
      "sudo usermod -aG docker ubuntu",
      "chmod 600 /home/ubuntu/myawskey.pem"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.key_path)
      host        = self.public_ip
    }
  }
}

resource "aws_instance" "swarm_worker" {
  count                       = 2
  ami                         = var.ami
  instance_type               = var.instance_type
  subnet_id                   = element([for s in aws_subnet.public : s.id], (count.index + 1) % length(aws_subnet.public))
  vpc_security_group_ids      = [aws_security_group.swarm.id]
  associate_public_ip_address = true
  key_name                    = var.key_name

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-worker-${count.index + 1}"
    Role = "worker"
  })
  provisioner "file" {
    source      = var.key_path
    destination = "/home/ubuntu/myawskey.pem"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.key_path)
      host        = self.public_ip
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update -y",
      "sudo apt-get install -y docker.io",
      "sudo systemctl start docker",
      "sudo systemctl enable docker",
      "sudo usermod -aG docker ubuntu",
      "chmod 600 /home/ubuntu/myawskey.pem"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.key_path)
      host        = self.public_ip
    }
  }
}

resource "null_resource" "swarm_init" {
  provisioner "remote-exec" {
    inline = [
      "docker swarm init --advertise-addr ${aws_instance.swarm_master[0].public_ip}"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.key_path)
      host        = aws_instance.swarm_master[0].public_ip
    }
  }

  depends_on = [aws_instance.swarm_master]
}

resource "null_resource" "swarm_join_worker" {
  count = 2

  provisioner "remote-exec" {
    inline = [
      "docker swarm join --token $(ssh -o StrictHostKeyChecking=no -i /home/ubuntu/stagingPEM.pem ubuntu@${aws_instance.swarm_master[0].public_ip} 'docker swarm join-token worker -q') ${aws_instance.swarm_master[0].public_ip}:2377"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.key_path)
      host        = aws_instance.swarm_worker[count.index].public_ip
    }
  }

  depends_on = [null_resource.swarm_init]
}

#############################################
# Network Load Balancer + TGs + Listeners
# Strategy: Instance targets (routing-mesh ready)
#############################################
resource "aws_lb" "nlb" {
  name                       = "${local.name_prefix}-nlb"
  load_balancer_type         = "network"
  internal                   = false
  subnets                    = [for s in aws_subnet.public : s.id]
  enable_deletion_protection = false
  enable_cross_zone_load_balancing = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-nlb" })
}

resource "aws_lb_target_group" "tcp80" {
  name        = "${local.name_prefix}-tg-80"
  port        = 80
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-tg-80" })
}

resource "aws_lb_target_group" "tcp443" {
  name        = "${local.name_prefix}-tg-443"
  port        = 443
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-tg-443" })
}

# Register all Swarm nodes to both TGs so routing mesh handles distribution
resource "aws_lb_listener" "l80" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 80
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tcp80.arn
  }
}

resource "aws_lb_listener" "l443" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 443
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tcp443.arn
  }
}

############################
# Target group attachments (index-based keys to avoid unknown IDs at plan time)
#############################################
locals {
  master_indexes = toset([for i in range(length(aws_instance.swarm_master)) : tostring(i)])
  worker_indexes = toset([for i in range(length(aws_instance.swarm_worker)) : tostring(i)])
}

resource "aws_lb_target_group_attachment" "tg80_masters" {
  for_each         = local.master_indexes
  target_group_arn = aws_lb_target_group.tcp80.arn
  target_id        = aws_instance.swarm_master[tonumber(each.value)].id
  port             = 80
}

resource "aws_lb_target_group_attachment" "tg80_workers" {
  for_each         = local.worker_indexes
  target_group_arn = aws_lb_target_group.tcp80.arn
  target_id        = aws_instance.swarm_worker[tonumber(each.value)].id
  port             = 80
}

resource "aws_lb_target_group_attachment" "tg443_masters" {
  for_each         = local.master_indexes
  target_group_arn = aws_lb_target_group.tcp443.arn
  target_id        = aws_instance.swarm_master[tonumber(each.value)].id
  port             = 443
}

resource "aws_lb_target_group_attachment" "tg443_workers" {
  for_each         = local.worker_indexes
  target_group_arn = aws_lb_target_group.tcp443.arn
  target_id        = aws_instance.swarm_worker[tonumber(each.value)].id
  port             = 443
}
