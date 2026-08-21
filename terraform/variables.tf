variable "app_ami_id" {
  type        = string
  description = "Bare LocalStack AMI id ami-<12hex> — not the docker tag localstack-ec2/app:ami-<12hex>."
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type."
  default     = "t3.small"
}

variable "app_port" {
  type        = number
  description = "Port the capacity-api container listens on."
  default     = 3000
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR for SG ingress (never 0.0.0.0/0)."
  default     = "10.0.0.0/16"
}

variable "db_host" {
  type        = string
  description = "Aiven MySQL hostname. Never commit."
}

variable "db_port" {
  type        = number
  description = "Aiven MySQL port (not 3306 on the free plan)."
}

variable "db_username" {
  type        = string
  description = "Aiven MySQL user."
  default     = "avnadmin"
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "Aiven MySQL password. Never commit."
}

variable "db_name" {
  type        = string
  description = "Logical database name in the Secrets Manager envelope."
  default     = "capacity_lab"
}

variable "secret_name" {
  type        = string
  description = "Secrets Manager secret name."
  default     = "regional-health/db"
}
