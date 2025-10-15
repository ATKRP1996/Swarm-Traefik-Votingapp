variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "key_name" {
  description = "Existing EC2 key pair name"
  type        = string
  default     = "myawskey"
}

variable "key_path" {
  default = "C:/Users/user/.ssh/myawskey.pem"
}


variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "ami" {
  description = "Ubuntu AMI ID"
  type        = string
  default     = "ami-0360c520857e3138f" # Verify per-region
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs across AZs"
  type        = list(string)
  default     = ["10.0.1.0/24","10.0.2.0/24","10.0.3.0/24"]
}

variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "dev"
}
