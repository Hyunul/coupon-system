output "project" {
  description = "Verified Project tag used by destructive residual-resource checks."
  value       = var.project
}
output "primary_region" {
  description = "Primary Seoul region for application and monitoring resources."
  value       = var.aws_region
}

output "external_region" {
  description = "External Tokyo region for the external load generator."
  value       = "ap-northeast-1"
}
output "alb_url" {
  description = "Public HTTPS entry point for approved load-generator CIDRs."
  value       = "https://${var.benchmark_hostname}"
}
output "alb_dns_name" {
  description = "ALB DNS target to which the operator must map benchmark_hostname before smoke/load testing."
  value       = aws_lb.public.dns_name
}

output "dns_mapping_required" {
  description = "User-only DNS prerequisite; Terraform does not mutate the benchmark DNS zone."
  value       = "Map ${var.benchmark_hostname} to ${aws_lb.public.dns_name} and verify the ACM certificate before sending load."
}
output "api_target_group_arn" {
  description = "ALB target group used for API health verification."
  value       = aws_lb_target_group.api.arn
}

output "api_instance_ids" {
  description = "API EC2 instance IDs."
  value       = [for key in sort(keys(aws_instance.api)) : aws_instance.api[key].id]
}

output "worker_instance_ids" {
  description = "Worker EC2 instance IDs."
  value       = [for key in sort(keys(aws_instance.worker)) : aws_instance.worker[key].id]
}

output "mock_notify_instance_id" {
  description = "Mock notification EC2 instance ID."
  value       = aws_instance.mock_notify.id
}
output "mock_notify_private_url" {
  description = "Private mock notification endpoint used by API and worker instances."
  value       = "http://${aws_instance.mock_notify.private_ip}:8090/notify"
}

output "monitoring_ssm_port_forwarding" {
  description = "SSM-only access commands for the monitoring instance; Grafana and Prometheus have no ingress."
  value = {
    grafana    = "aws ssm start-session --target ${aws_instance.monitoring.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=3000,localPortNumber=3000"
    prometheus = "aws ssm start-session --target ${aws_instance.monitoring.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=9090,localPortNumber=9090"
  }
}

output "monitoring_instance_id" {
  description = "Monitoring EC2 instance ID."
  value       = aws_instance.monitoring.id
}

output "rds_endpoint" {
  description = "Private RDS MySQL endpoint."
  value       = aws_db_instance.mysql.address
}

output "redis_endpoint" {
  description = "Private Valkey endpoint."
  value       = aws_elasticache_replication_group.valkey.primary_endpoint_address
}
output "rds_master_user_secret_arn" {
  description = "RDS-managed master credential secret read by the instance role at runtime."
  value       = aws_db_instance.mysql.master_user_secret[0].secret_arn
  sensitive   = true
}

output "artifact_contract" {
  description = "Private S3 location pattern permitted to the EC2 deployment role."
  value       = "s3://${replace(var.artifact_bucket_arn, "arn:aws:s3:::", "")}/${var.artifact_key_prefix}/*"
}
output "generator_evidence_s3_uri" {
  description = "Only S3 key pattern to which the SSM-only load generator role may upload benchmark evidence."
  value       = local.generator_evidence_s3_uri
}

output "expires_at" {
  description = "UTC RFC3339 expiration used by resource tags and the regional TTL safety Lambdas."
  value       = local.expires_at
}

output "ttl_cleanup_limitations" {
  description = "Resources the TTL Lambda cannot stop; Terraform destroy remains required."
  value       = "Five-minute regional TTL Lambdas stop only EC2 and Seoul RDS resources with matching Project, Owner, and ExpiresAt tags after expires_at; Tokyo stops EC2 only. They never delete resources. ALB, ElastiCache, VPC networking, CloudWatch logs, delayed budget alerts, and IAM resources continue to incur or retain charges until terraform destroy is run."
}
output "control_load_generator_instance_ids" {
  description = "Same-region control k6 generator EC2 instance IDs."
  value       = [for key in sort(keys(aws_instance.control_load_generator)) : aws_instance.control_load_generator[key].id]
}

output "control_load_generator_public_ips" {
  description = "Fixed public IPs of same-region control k6 generators."
  value       = [for key in sort(keys(aws_eip.control_load_generator)) : aws_eip.control_load_generator[key].public_ip]
}

output "external_load_generator_instance_ids" {
  description = "Tokyo external k6 generator EC2 instance IDs."
  value       = [for key in sort(keys(aws_instance.external_load_generator)) : aws_instance.external_load_generator[key].id]
}

output "external_load_generator_public_ips" {
  description = "Fixed public IPs of Tokyo external k6 generators."
  value       = [for key in sort(keys(aws_eip.external_load_generator)) : aws_eip.external_load_generator[key].public_ip]
}
output "resolved_ami_ids" {
  description = "Resolved Amazon Linux 2023 AMI IDs used in Seoul and Tokyo."
  value = {
    seoul = nonsensitive(data.aws_ssm_parameter.al2023_ami.value)
    tokyo = nonsensitive(data.aws_ssm_parameter.external_al2023_ami.value)
  }
}

output "rds_engine_version_actual" {
  description = "Actual MySQL engine version resolved by RDS."
  value       = aws_db_instance.mysql.engine_version_actual
}

output "k6_pin" {
  description = "Pinned k6 release and Linux AMD64 SHA256 installed on generators."
  value = {
    version            = var.k6_version
    linux_amd64_sha256 = var.k6_linux_amd64_sha256
  }
}

output "monitoring_image_digests" {
  description = "Pinned AMD64 monitoring container image digests."
  value = {
    prometheus = local.prometheus_image
    grafana    = local.grafana_image
  }
}
