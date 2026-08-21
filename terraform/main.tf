# Composes group modules from akezasaloi/regional-health-platform at a pinned SHA.
# No aws_db_instance (Hobby RDS 501 — MySQL is Aiven) and no aws_lb (ELBv2 501).
# app_ami_id is the bare ami-<12hex>, not the docker tag localstack-ec2/app:ami-<12hex>.

locals {
  platform     = "git::https://github.com/akezasaloi/regional-health-platform.git"
  platform_ref = "d56f94d742cb4238a19a707f416a945423b74ae2"
}

module "data" {
  source = "${local.platform}//terraform/modules/data?ref=${local.platform_ref}"

  db_host     = var.db_host
  db_port     = var.db_port
  db_username = var.db_username
  db_password = var.db_password
  db_name     = var.db_name
  secret_name = var.secret_name
}

module "service" {
  source = "${local.platform}//terraform/modules/service?ref=${local.platform_ref}"

  app_ami_id    = var.app_ami_id
  instance_type = var.instance_type
  secret_arn    = module.data.secret_arn
  db_endpoint   = module.data.db_endpoint
  db_port       = module.data.db_port
  app_port      = var.app_port
  vpc_cidr      = var.vpc_cidr
}
