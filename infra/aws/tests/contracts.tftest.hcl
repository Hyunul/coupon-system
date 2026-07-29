# Native offline Terraform contracts. `terraform test` uses only mock providers.
mock_provider "aws" {}
mock_provider "aws" {
  alias = "tokyo"
}
mock_provider "archive" {}


override_data {
  target = data.aws_availability_zones.available
  values = { names = ["ap-northeast-2a", "ap-northeast-2c"] }
}
override_data {
  target = data.aws_availability_zones.control
  values = { names = ["ap-northeast-2a"] }
}
override_data {
  target = data.aws_availability_zones.external
  values = { names = ["ap-northeast-1a"] }
}

variables {
  aws_region                     = "ap-northeast-2"
  project                        = "coupon-benchmark"
  owner                          = "offline-contract@example.test"
  expires_at                     = "2030-01-01T12:00:00Z"
  owner_cidr                     = "203.0.113.10/32"
  additional_load_generator_cidrs = ["198.51.100.10/32"]
  acm_certificate_arn            = "arn:aws:acm:ap-northeast-2:123456789012:certificate/12345678-1234-1234-1234-123456789abc"
  benchmark_hostname             = "benchmark.example.test"
  db_master_username             = "couponadmin"
  artifact_bucket_arn            = "arn:aws:s3:::offline-contract-artifacts"
  artifact_key_prefix            = "coupon-benchmark"
  generator_evidence_key_prefix  = "coupon-benchmark/evidence"
  budget_notification_emails     = ["offline-contract@example.test"]
}

run "valid_bounded_plan_contract" {
  command = plan

  assert {
    condition     = var.aws_region == "ap-northeast-2" && var.operating_budget_usd <= 100 && var.kill_budget_usd <= 120 && var.absolute_budget_usd <= 200
    error_message = "The approved region and budget bounds must remain enforceable offline."
  }
  assert {
    condition     = output.alb_url != null && can(regex("^https://", output.alb_url))
    error_message = "The public endpoint output must remain HTTPS-only."
  }
  assert {
    condition     = can(regex("Five-minute regional TTL", output.ttl_cleanup_limitations))
    error_message = "TTL cleanup limitations must remain explicit."
  }
}
run "reject_malformed_expiry" {
  command = plan
  variables { expires_at = "2026-07-28T12:00:00+09:00" }
  expect_failures = [var.expires_at]
}
run "reject_operating_budget_above_cap" {
  command = plan
  variables { operating_budget_usd = 101 }
  expect_failures = [var.operating_budget_usd]
}
run "reject_kill_budget_above_cap" {
  command = plan
  variables { kill_budget_usd = 121 }
  expect_failures = [var.kill_budget_usd]
}
run "reject_absolute_budget_above_cap" {
  command = plan
  variables { absolute_budget_usd = 201 }
  expect_failures = [var.absolute_budget_usd]
}
run "reject_operating_budget_above_kill_budget" {
  command = plan
  variables {
    operating_budget_usd = 100
    kill_budget_usd      = 99
  }
  expect_failures = [aws_budgets_budget.delayed_alert]
}
run "reject_kill_budget_above_absolute_budget" {
  command = plan
  variables {
    kill_budget_usd     = 120
    absolute_budget_usd = 119
  }
  expect_failures = [aws_budgets_budget.delayed_alert]
}


run "reject_invalid_project" {
  command = plan
  variables { project = "BAD_project" }
  expect_failures = [var.project]
}
run "reject_consecutive_project_hyphens" {
  command = plan
  variables { project = "coupon--benchmark" }
  expect_failures = [var.project]
}
run "reject_ipv6_owner_cidr" {
  command = plan
  variables { owner_cidr = "2001:db8::/64" }
  expect_failures = [var.owner_cidr]
}
run "reject_broad_owner_cidr" {
  command = plan
  variables { owner_cidr = "0.0.0.0/0" }
  expect_failures = [var.owner_cidr]
}
run "reject_non_host_additional_cidr" {
  command = plan
  variables { additional_load_generator_cidrs = ["198.51.100.0/24"] }
  expect_failures = [var.additional_load_generator_cidrs]
}
run "reject_unapproved_instance_type" {
  command = plan
  variables { control_load_generator_instance_type = "t3.micro" }
  expect_failures = [var.control_load_generator_instance_type]
}
run "reject_invalid_budget_email" {
  command = plan
  variables { budget_notification_emails = ["not-an-email"] }
  expect_failures = [var.budget_notification_emails]
}
run "reject_invalid_prefix_syntax" {
  command = plan
  variables {
    artifact_key_prefix           = "coupon benchmark"
    generator_evidence_key_prefix = "/coupon-benchmark/evidence"
  }
  expect_failures = [var.artifact_key_prefix, var.generator_evidence_key_prefix]
}
run "reject_evidence_prefix_outside_artifact_prefix" {
  command = plan
  variables {
    artifact_key_prefix           = "coupon-benchmark"
    generator_evidence_key_prefix = "coupon-benchmark-evidence"
  }
  expect_failures = [aws_iam_role_policy.load_generator_artifact]
}
run "reject_evidence_prefix_equal_to_artifact_prefix" {
  command = plan
  variables {
    artifact_key_prefix           = "coupon-benchmark"
    generator_evidence_key_prefix = "coupon-benchmark"
  }
  expect_failures = [aws_iam_role_policy.load_generator_artifact]
}
run "reject_unsafe_artifact_prefix" {
  command = plan
  variables {
    artifact_key_prefix           = "/"
    generator_evidence_key_prefix = "evidence"
  }
  expect_failures = [var.artifact_key_prefix]
}

# These checks intentionally inspect the planned model rather than provider responses.
run "infrastructure_security_invariants" {
  command = plan
  assert {
    condition     = aws_lb_listener.https.port == 443 && aws_lb_listener.https.protocol == "HTTPS"
    error_message = "ALB must expose HTTPS on port 443 only."
  }
  assert {
    condition     = aws_cloudwatch_event_rule.ttl_cleanup.schedule_expression == "rate(5 minutes)" && aws_lambda_function.ttl_cleanup.timeout == 30
    error_message = "Seoul TTL cleanup must retain its five-minute, bounded Lambda contract."
  }
  assert {
    condition     = aws_cloudwatch_event_rule.ttl_cleanup_tokyo.schedule_expression == "rate(5 minutes)" && aws_lambda_function.ttl_cleanup_tokyo.timeout == 30
    error_message = "Tokyo TTL cleanup must retain its five-minute, bounded Lambda contract."
  }
  assert {
    condition = (
      output.expires_at == var.expires_at &&
      local.common_tags["ExpiresAt"] == var.expires_at &&
      aws_lambda_function.ttl_cleanup.environment[0].variables["EXPIRES_AT"] == var.expires_at &&
      aws_lambda_function.ttl_cleanup_tokyo.environment[0].variables["EXPIRES_AT"] == var.expires_at
    )
    error_message = "The exact explicit expiration must be retained in output, common tags, and both regional TTL Lambda environments."
  }
  assert {
    condition     = alltrue([for instance in values(aws_instance.control_load_generator) : instance.tags["Role"] == "control-load-generator"]) && alltrue([for instance in values(aws_instance.external_load_generator) : instance.tags["Role"] == "external-load-generator"])
    error_message = "Control and external generators must preserve exact distinct role tags."
  }
  assert {
    condition     = aws_instance.mock_notify.user_data_replace_on_change && aws_instance.monitoring.user_data_replace_on_change
    error_message = "Cloud-init-only mock notification and monitoring configuration must replace instances when changed."
  }
  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.load_generator_artifact.policy).Statement) == 3 &&
      jsondecode(aws_iam_role_policy.load_generator_artifact.policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.load_generator_artifact.policy).Statement[0].Action == ["s3:GetObject", "s3:GetObjectVersion"] &&
      jsondecode(aws_iam_role_policy.load_generator_artifact.policy).Statement[0].Resource == "arn:aws:s3:::offline-contract-artifacts/coupon-benchmark/*" &&
      jsondecode(aws_iam_role_policy.load_generator_artifact.policy).Statement[1].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.load_generator_artifact.policy).Statement[1].Action == ["s3:PutObject"] &&
      jsondecode(aws_iam_role_policy.load_generator_artifact.policy).Statement[1].Resource == "arn:aws:s3:::offline-contract-artifacts/coupon-benchmark/evidence/*" &&
      jsondecode(aws_iam_role_policy.load_generator_artifact.policy).Statement[2].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.load_generator_artifact.policy).Statement[2].Action == ["s3:ListBucket"] &&
      jsondecode(aws_iam_role_policy.load_generator_artifact.policy).Statement[2].Resource == "arn:aws:s3:::offline-contract-artifacts" &&
      jsondecode(aws_iam_role_policy.load_generator_artifact.policy).Statement[2].Condition.StringLike["s3:prefix"] == ["coupon-benchmark/*"] &&
      output.generator_evidence_s3_uri == "s3://offline-contract-artifacts/coupon-benchmark/evidence/*"
    )
    error_message = "Load generators must have only scoped artifact reads, evidence writes, and bucket listing permissions."
  }
}
