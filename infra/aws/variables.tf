variable "aws_region" {
  type        = string
  description = "AWS region for the benchmark."
  default     = "ap-northeast-2"

  validation {
    condition     = var.aws_region == "ap-northeast-2"
    error_message = "This approved benchmark is limited to ap-northeast-2."
  }
}
variable "acm_certificate_arn" {
  type        = string
  description = "ACM certificate ARN for the public HTTPS ALB listener."

  validation {
    condition     = can(regex("^arn:aws:acm:ap-northeast-2:[0-9]{12}:certificate/[0-9a-f-]+$", var.acm_certificate_arn))
    error_message = "acm_certificate_arn must be a valid ACM certificate ARN."
  }
}
variable "benchmark_hostname" {
  type        = string
  description = "Lowercase DNS hostname covered by acm_certificate_arn and mapped by the operator to the ALB DNS name."

  validation {
    condition     = length(var.benchmark_hostname) <= 253 && lower(var.benchmark_hostname) == var.benchmark_hostname && can(regex("^([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", var.benchmark_hostname))
    error_message = "benchmark_hostname must be a lowercase fully qualified DNS hostname."
  }
}

variable "project" {
  type        = string
  description = "Lowercase AWS-safe project identifier."
  default     = "coupon-benchmark"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,26}[a-z0-9]$", var.project)) && !strcontains(var.project, "--")
    error_message = "project must be 3-28 lowercase letters, digits, or single hyphens, start with a letter, and not end with a hyphen."
  }
}

variable "owner" {
  type        = string
  description = "Owner tag value used to bind TTL cleanup permissions to this benchmark deployment."

  validation {
    condition     = length(trimspace(var.owner)) > 0 && length(var.owner) <= 128
    error_message = "owner must be a non-empty value no longer than 128 characters."
  }
}

variable "owner_cidr" {
  type        = string
  description = "Trusted IPv4 /24-/32 CIDR permitted to reach the ALB."

  validation {
    condition     = can(regex("^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}/(2[4-9]|3[0-2])$", var.owner_cidr)) && can(cidrnetmask(var.owner_cidr))
    error_message = "owner_cidr must be a valid IPv4 CIDR with a /24 through /32 prefix."
  }
}

variable "additional_load_generator_cidrs" {
  type        = set(string)
  description = "Optional IPv4 /32 CIDRs in addition to fixed generator EIPs and owner CIDR allowed to invoke the public ALB."
  default     = []

  validation {
    condition     = alltrue([for cidr in var.additional_load_generator_cidrs : can(regex("^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}/32$", cidr)) && can(cidrnetmask(cidr))])
    error_message = "additional_load_generator_cidrs must contain only valid IPv4 /32 CIDRs."
  }
}

variable "control_load_generator_count" {
  type        = number
  description = "Number of isolated same-region control k6 generators."
  default     = 1

  validation {
    condition     = var.control_load_generator_count >= 1 && var.control_load_generator_count <= 2 && floor(var.control_load_generator_count) == var.control_load_generator_count
    error_message = "control_load_generator_count must be a whole number from 1 through 2."
  }
}

variable "external_load_generator_count" {
  type        = number
  description = "Number of isolated Tokyo external k6 generators."
  default     = 1

  validation {
    condition     = var.external_load_generator_count >= 1 && var.external_load_generator_count <= 2 && floor(var.external_load_generator_count) == var.external_load_generator_count
    error_message = "external_load_generator_count must be a whole number from 1 through 2."
  }
}

variable "control_load_generator_instance_type" {
  type        = string
  description = "Approved EC2 instance type for same-region control k6 generators."
  default     = "c7i.2xlarge"

  validation {
    condition     = contains(["c7i.2xlarge"], var.control_load_generator_instance_type)
    error_message = "control_load_generator_instance_type must be c7i.2xlarge."
  }
}

variable "external_load_generator_instance_type" {
  type        = string
  description = "Approved EC2 instance type for Tokyo external k6 generators."
  default     = "c7i.2xlarge"

  validation {
    condition     = contains(["c7i.2xlarge"], var.external_load_generator_instance_type)
    error_message = "external_load_generator_instance_type must be c7i.2xlarge."
  }
}
variable "k6_version" {
  type        = string
  description = "Immutable k6 release version installed on load generators."
  default     = "2.1.0"

  validation {
    condition     = var.k6_version == "2.1.0"
    error_message = "k6_version is pinned to the approved 2.1.0 release."
  }
}

variable "k6_linux_amd64_sha256" {
  type        = string
  description = "Official SHA256 for the k6 v2.1.0 linux-amd64 tarball."
  default     = "295d961ebfca306f295f1133068dcd403a8171c87f387928f5f30b0fbcff858a"

  validation {
    condition     = var.k6_linux_amd64_sha256 == "295d961ebfca306f295f1133068dcd403a8171c87f387928f5f30b0fbcff858a"
    error_message = "k6_linux_amd64_sha256 must match the approved k6 v2.1.0 linux-amd64 checksum."
  }
}


variable "expires_at" {
  type        = string
  description = "Explicit UTC RFC3339 expiration for this benchmark. Preflight requires it to be in the future and no more than 12 hours away."

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$", var.expires_at)) && can(formatdate("YYYY-MM-DD'T'hh:mm:ssZ", var.expires_at))
    error_message = "expires_at must be a valid RFC3339 UTC timestamp ending in Z."
  }

}

variable "api_instance_type" {
  type    = string
  default = "c7i.large"

  validation {
    condition     = contains(["c7i.large"], var.api_instance_type)
    error_message = "api_instance_type must be c7i.large."
  }
}

variable "worker_instance_type" {
  type    = string
  default = "c7i.large"

  validation {
    condition     = contains(["c7i.large"], var.worker_instance_type)
    error_message = "worker_instance_type must be c7i.large."
  }
}

variable "mock_notify_instance_type" {
  type    = string
  default = "c7i.large"

  validation {
    condition     = contains(["c7i.large"], var.mock_notify_instance_type)
    error_message = "mock_notify_instance_type must be c7i.large."
  }
}

variable "monitoring_instance_type" {
  type    = string
  default = "m7i.large"

  validation {
    condition     = contains(["m7i.large"], var.monitoring_instance_type)
    error_message = "monitoring_instance_type must be m7i.large."
  }
}

variable "worker_count" {
  type        = number
  description = "Number of asynchronous workers."
  default     = 1

  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 4 && floor(var.worker_count) == var.worker_count
    error_message = "worker_count must be a whole number from 1 through 4."
  }
}

variable "db_instance_class" {
  type    = string
  default = "db.m7g.large"

  validation {
    condition     = contains(["db.m7g.large"], var.db_instance_class)
    error_message = "db_instance_class must be db.m7g.large."
  }
}

variable "cache_node_type" {
  type    = string
  default = "cache.m7g.large"

  validation {
    condition     = contains(["cache.m7g.large"], var.cache_node_type)
    error_message = "cache_node_type must be cache.m7g.large."
  }
}

variable "db_name" {
  type    = string
  default = "coupon"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9]{0,63}$", var.db_name))
    error_message = "db_name must start with a letter and contain only letters and numbers."
  }
}

variable "db_master_username" {
  type      = string
  sensitive = true

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{0,15}$", var.db_master_username))
    error_message = "db_master_username must start with a letter and be 1-16 alphanumeric or underscore characters."
  }
}

variable "artifact_bucket_arn" {
  type        = string
  description = "ARN of the private S3 bucket containing deployable JAR artifacts."

  validation {
    condition     = can(regex("^arn:aws:s3:::[A-Za-z0-9][A-Za-z0-9.-]{1,61}[A-Za-z0-9]$", var.artifact_bucket_arn))
    error_message = "artifact_bucket_arn must be an S3 bucket ARN, not an object ARN."
  }
}

variable "artifact_key_prefix" {
  type        = string
  description = "Non-empty private S3 key prefix to which EC2 artifact reads are limited."

  validation {
    condition     = trim(var.artifact_key_prefix, "/") == var.artifact_key_prefix && can(regex("^[A-Za-z0-9][A-Za-z0-9._/-]*$", var.artifact_key_prefix))
    error_message = "artifact_key_prefix must be a non-empty, slash-trimmed S3 key prefix containing only letters, digits, dots, underscores, slashes, and hyphens."
  }
}
variable "generator_evidence_key_prefix" {
  type        = string
  description = "Non-empty S3 key prefix beneath artifact_key_prefix where load generators may upload benchmark evidence."

  validation {
    condition     = trim(var.generator_evidence_key_prefix, "/") == var.generator_evidence_key_prefix && can(regex("^[A-Za-z0-9][A-Za-z0-9._/-]*$", var.generator_evidence_key_prefix))
    error_message = "generator_evidence_key_prefix must be a non-empty, slash-trimmed S3 key prefix containing only letters, digits, dots, underscores, slashes, and hyphens."
  }
}

variable "mock_notify_latency_ms" {
  type        = number
  description = "Fixed mock notification response latency in milliseconds."
  default     = 0

  validation {
    condition     = var.mock_notify_latency_ms >= 0 && floor(var.mock_notify_latency_ms) == var.mock_notify_latency_ms
    error_message = "mock_notify_latency_ms must be a non-negative whole number."
  }
}

variable "mock_notify_error_rate" {
  type        = number
  description = "Default mock notification error rate from 0 through 1."
  default     = 0

  validation {
    condition     = var.mock_notify_error_rate >= 0 && var.mock_notify_error_rate <= 1
    error_message = "mock_notify_error_rate must be between 0 and 1."
  }
}

variable "budget_notification_emails" {
  type        = set(string)
  description = "Required email subscribers for delayed AWS Budget alerts."

  validation {
    condition     = length(var.budget_notification_emails) > 0 && alltrue([for email in var.budget_notification_emails : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", email))])
    error_message = "budget_notification_emails must be a non-empty set of valid email addresses."
  }
}

variable "operating_budget_usd" {
  type    = number
  default = 100

  validation {
    condition     = var.operating_budget_usd > 0 && var.operating_budget_usd <= 100
    error_message = "operating_budget_usd must be positive and no greater than the approved $100 operating limit."
  }
}

variable "kill_budget_usd" {
  type    = number
  default = 120

  validation {
    condition     = var.kill_budget_usd > 0 && var.kill_budget_usd <= 120
    error_message = "kill_budget_usd must be positive and no greater than the approved $120 kill limit."
  }
}

variable "absolute_budget_usd" {
  type    = number
  default = 200

  validation {
    condition     = var.absolute_budget_usd > 0 && var.absolute_budget_usd <= 200
    error_message = "absolute_budget_usd must be positive and no greater than the $200 credit ceiling."
  }
}
