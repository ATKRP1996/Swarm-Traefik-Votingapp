#############################################
# Networking Outputs
#############################################

output "vpc_id" {
  value       = aws_vpc.main.id
  description = "ID of the VPC"
}

output "public_subnet_ids" {
  value       = [for s in aws_subnet.public : s.id]
  description = "IDs of public subnets"
}

output "public_subnet_azs" {
  value       = [for s in aws_subnet.public : s.availability_zone]
  description = "AZs of public subnets"
}

#############################################
# Security Outputs
#############################################

output "security_group_id" {
  value       = aws_security_group.swarm.id
  description = "Swarm/Traefik security group ID"
}

#############################################
# EC2 Instance Outputs
#############################################

output "master_ips" {
  value       = [for i in aws_instance.swarm_master : i.public_ip]
  description = "Public IPs of Swarm manager nodes"
}

output "worker_ips" {
  value       = [for i in aws_instance.swarm_worker : i.public_ip]
  description = "Public IPs of Swarm worker nodes"
}

#############################################
# Load Balancer Outputs
#############################################

output "nlb_dns_name" {
  value       = aws_lb.nlb.dns_name
  description = "DNS name of the Network Load Balancer — use this for vote.atkrp.store and result.atkrp.store ALIAS/A-records"
}
