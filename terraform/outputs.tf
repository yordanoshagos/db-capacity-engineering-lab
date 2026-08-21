output "db_endpoint" {
  value = module.data.db_endpoint
}

output "db_port" {
  value = module.data.db_port
}

output "secret_arn" {
  value     = module.data.secret_arn
  sensitive = true
}

output "instance_id" {
  value = module.service.instance_id
}

output "app_url" {
  value = "http://${module.service.app_host}:${module.service.app_port}"
}
