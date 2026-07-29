data "aws_availability_zones" "control" {
  state = "available"
}

data "aws_availability_zones" "external" {
  provider = aws.tokyo
  state    = "available"
}

data "aws_ssm_parameter" "control_al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_ssm_parameter" "external_al2023_ami" {
  provider = aws.tokyo
  name     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  load_generator_user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    K6_VERSION=${var.k6_version}
    K6_SHA256=${var.k6_linux_amd64_sha256}
    BOOTSTRAP_MARKER=/var/lib/coupon-loadtest/k6-bootstrap-complete
    MAX_ATTEMPTS=12
    RETRY_SECONDS=10

    rm -f "$BOOTSTRAP_MARKER"

    retry() {
      local attempt=1
      until "$@"; do
        if (( attempt >= MAX_ATTEMPTS )); then
          echo "Command failed after $MAX_ATTEMPTS attempts: $*" >&2
          return 1
        fi
        sleep "$RETRY_SECONDS"
        ((attempt++))
      done
    }

    metadata_token() {
      curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
        -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
        http://169.254.169.254/latest/api/token
    }

    wait_for_eip_internet() {
      local attempt=1 token public_ip
      while (( attempt <= MAX_ATTEMPTS )); do
        token="$(metadata_token)" || true
        if [[ -n "$token" ]]; then
          public_ip="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
            -H "X-aws-ec2-metadata-token: $token" \
            http://169.254.169.254/latest/meta-data/public-ipv4)" || true
          if [[ -n "$public_ip" ]] && curl --fail --silent --show-error --connect-timeout 10 --max-time 20 \
            https://github.com/ >/dev/null; then
            return 0
          fi
        fi
        echo "Waiting for EIP-backed Internet readiness (attempt $attempt/$MAX_ATTEMPTS)" >&2
        sleep "$RETRY_SECONDS"
        ((attempt++))
      done
      echo "EIP-backed Internet readiness did not complete after $MAX_ATTEMPTS attempts" >&2
      return 1
    }

    wait_for_eip_internet
    retry dnf install -y coreutils curl tar
    retry curl --fail --location --silent --show-error --connect-timeout 10 --max-time 120 \
      "https://github.com/grafana/k6/releases/download/v$K6_VERSION/k6-v$K6_VERSION-linux-amd64.tar.gz" \
      -o /tmp/k6.tar.gz
    printf '%s  %s\n' "$K6_SHA256" /tmp/k6.tar.gz | sha256sum --check --
    tar -xzf /tmp/k6.tar.gz -C /tmp
    install -m 0755 "/tmp/k6-v$K6_VERSION-linux-amd64/k6" /usr/local/bin/k6
    rm -rf /tmp/k6.tar.gz "/tmp/k6-v$K6_VERSION-linux-amd64"
    install -d -m 0755 /opt/coupon-loadtest "$(dirname "$BOOTSTRAP_MARKER")"
    k6 version | grep --fixed-strings "v$K6_VERSION"
    touch "$BOOTSTRAP_MARKER"
  EOT
}

resource "aws_vpc" "control_load_generator" {
  cidr_block           = "10.61.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project}-control-load-generator" }
}

resource "aws_internet_gateway" "control_load_generator" {
  vpc_id = aws_vpc.control_load_generator.id

  tags = { Name = "${var.project}-control-load-generator" }
}

resource "aws_subnet" "control_load_generator" {
  vpc_id                  = aws_vpc.control_load_generator.id
  availability_zone       = data.aws_availability_zones.control.names[0]
  cidr_block              = "10.61.0.0/24"
  map_public_ip_on_launch = false

  tags = { Name = "${var.project}-control-load-generator" }
}

resource "aws_route_table" "control_load_generator" {
  vpc_id = aws_vpc.control_load_generator.id

  tags = { Name = "${var.project}-control-load-generator" }
}

resource "aws_route" "control_load_generator_internet" {
  route_table_id         = aws_route_table.control_load_generator.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.control_load_generator.id
}

resource "aws_route_table_association" "control_load_generator" {
  subnet_id      = aws_subnet.control_load_generator.id
  route_table_id = aws_route_table.control_load_generator.id
}

resource "aws_security_group" "control_load_generator" {
  name        = "${var.project}-control-load-generator"
  description = "SSM-only control k6 generators with constrained outbound traffic"
  vpc_id      = aws_vpc.control_load_generator.id

  egress {
    description = "DNS to the VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["10.61.0.2/32"]
  }

  egress {
    description = "DNS TCP fallback to the VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["10.61.0.2/32"]
  }

  egress {
    description = "HTTPS for SSM, AL2023 packages, the pinned k6 release, and private S3 artifacts; AWS and release endpoints have dynamic public addresses"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

resource "aws_eip" "control_load_generator" {
  for_each = toset([for index in range(var.control_load_generator_count) : tostring(index + 1)])
  domain   = "vpc"

  tags = { Name = "${var.project}-control-load-generator-${each.key}" }
}

resource "aws_instance" "control_load_generator" {
  for_each = aws_eip.control_load_generator

  ami                         = data.aws_ssm_parameter.control_al2023_ami.value
  instance_type               = var.control_load_generator_instance_type
  subnet_id                   = aws_subnet.control_load_generator.id
  vpc_security_group_ids      = [aws_security_group.control_load_generator.id]
  iam_instance_profile        = aws_iam_instance_profile.load_generator.name
  associate_public_ip_address = false
  user_data_replace_on_change = true
  user_data                   = local.load_generator_user_data

  metadata_options { http_tokens = "required" }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 20
  }

  tags = { Name = "${var.project}-control-load-generator-${each.key}", Role = "control-load-generator" }
}

resource "aws_eip_association" "control_load_generator" {
  for_each      = aws_eip.control_load_generator
  allocation_id = each.value.id
  instance_id   = aws_instance.control_load_generator[each.key].id
}

resource "aws_vpc" "external_load_generator" {
  provider             = aws.tokyo
  cidr_block           = "10.62.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project}-external-load-generator" }
}

resource "aws_internet_gateway" "external_load_generator" {
  provider = aws.tokyo
  vpc_id   = aws_vpc.external_load_generator.id

  tags = { Name = "${var.project}-external-load-generator" }
}

resource "aws_subnet" "external_load_generator" {
  provider                = aws.tokyo
  vpc_id                  = aws_vpc.external_load_generator.id
  availability_zone       = data.aws_availability_zones.external.names[0]
  cidr_block              = "10.62.0.0/24"
  map_public_ip_on_launch = false

  tags = { Name = "${var.project}-external-load-generator" }
}

resource "aws_route_table" "external_load_generator" {
  provider = aws.tokyo
  vpc_id   = aws_vpc.external_load_generator.id

  tags = { Name = "${var.project}-external-load-generator" }
}

resource "aws_route" "external_load_generator_internet" {
  provider               = aws.tokyo
  route_table_id         = aws_route_table.external_load_generator.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.external_load_generator.id
}

resource "aws_route_table_association" "external_load_generator" {
  provider       = aws.tokyo
  subnet_id      = aws_subnet.external_load_generator.id
  route_table_id = aws_route_table.external_load_generator.id
}

resource "aws_security_group" "external_load_generator" {
  provider    = aws.tokyo
  name        = "${var.project}-external-load-generator"
  description = "SSM-only Tokyo k6 generators with constrained outbound traffic"
  vpc_id      = aws_vpc.external_load_generator.id

  egress {
    description = "DNS to the VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["10.62.0.2/32"]
  }

  egress {
    description = "DNS TCP fallback to the VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["10.62.0.2/32"]
  }

  egress {
    description = "HTTPS for SSM, AL2023 packages, the pinned k6 release, and private S3 artifacts; AWS and release endpoints have dynamic public addresses"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

resource "aws_eip" "external_load_generator" {
  provider = aws.tokyo
  for_each = toset([for index in range(var.external_load_generator_count) : tostring(index + 1)])
  domain   = "vpc"

  tags = { Name = "${var.project}-external-load-generator-${each.key}" }
}

resource "aws_instance" "external_load_generator" {
  provider = aws.tokyo
  for_each = aws_eip.external_load_generator

  ami                         = data.aws_ssm_parameter.external_al2023_ami.value
  instance_type               = var.external_load_generator_instance_type
  subnet_id                   = aws_subnet.external_load_generator.id
  vpc_security_group_ids      = [aws_security_group.external_load_generator.id]
  iam_instance_profile        = aws_iam_instance_profile.load_generator.name
  associate_public_ip_address = false
  user_data_replace_on_change = true
  user_data                   = local.load_generator_user_data

  metadata_options { http_tokens = "required" }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 20
  }

  tags = { Name = "${var.project}-external-load-generator-${each.key}", Role = "external-load-generator" }
}

resource "aws_eip_association" "external_load_generator" {
  provider      = aws.tokyo
  for_each      = aws_eip.external_load_generator
  allocation_id = each.value.id
  instance_id   = aws_instance.external_load_generator[each.key].id
}

resource "aws_iam_role" "load_generator" {
  name = "${var.project}-load-generator"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "load_generator_ssm" {
  role       = aws_iam_role.load_generator.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "load_generator_artifact" {
  name = "${var.project}-load-generator-artifact-access"
  role = aws_iam_role.load_generator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = local.artifact_object_arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = local.generator_evidence_object_arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = var.artifact_bucket_arn
        Condition = {
          StringLike = {
            "s3:prefix" = ["${trim(var.artifact_key_prefix, "/")}/*"]
          }
        }
      }
    ]
  })
  lifecycle {
    precondition {
      condition     = trim(var.generator_evidence_key_prefix, "/") != trim(var.artifact_key_prefix, "/") && startswith("${trim(var.generator_evidence_key_prefix, "/")}/", "${trim(var.artifact_key_prefix, "/")}/")
      error_message = "generator_evidence_key_prefix must be a non-empty child prefix of the non-empty artifact_key_prefix."
    }
  }
}

resource "aws_iam_instance_profile" "load_generator" {
  name = "${var.project}-load-generator"
  role = aws_iam_role.load_generator.name
}

resource "aws_cloudwatch_log_group" "ttl_load_generator_tokyo" {
  provider          = aws.tokyo
  name              = "/aws/lambda/${var.project}-ttl-cleanup-tokyo"
  retention_in_days = 3
}

resource "aws_iam_role" "ttl_lambda_tokyo" {
  name = "${var.project}-ttl-cleanup-tokyo"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ttl_lambda_tokyo" {
  name = "${var.project}-ttl-cleanup-tokyo"
  role = aws_iam_role.ttl_lambda_tokyo.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:StopInstances"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Project"   = var.project
            "aws:ResourceTag/Owner"     = var.owner
            "aws:ResourceTag/ExpiresAt" = local.expires_at
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.ttl_load_generator_tokyo.arn}:*"
      }
    ]
  })
}

resource "aws_lambda_function" "ttl_cleanup_tokyo" {
  provider         = aws.tokyo
  function_name    = "${var.project}-ttl-cleanup-tokyo"
  role             = aws_iam_role.ttl_lambda_tokyo.arn
  handler          = "ttl_cleanup.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.ttl_lambda.output_path
  source_code_hash = data.archive_file.ttl_lambda.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      ENABLE_RDS = "false"
      EXPIRES_AT = local.expires_at
      PROJECT    = var.project
      OWNER      = var.owner
    }
  }

  depends_on = [aws_iam_role_policy.ttl_lambda_tokyo]
}

resource "aws_cloudwatch_event_rule" "ttl_cleanup_tokyo" {
  provider            = aws.tokyo
  name                = "${var.project}-ttl-cleanup-tokyo-five-minute"
  description         = "Stops tagged Tokyo generator EC2 resources after benchmark expiration"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "ttl_cleanup_tokyo" {
  provider = aws.tokyo
  rule     = aws_cloudwatch_event_rule.ttl_cleanup_tokyo.name
  arn      = aws_lambda_function.ttl_cleanup_tokyo.arn
}

resource "aws_lambda_permission" "eventbridge_ttl_cleanup_tokyo" {
  provider      = aws.tokyo
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ttl_cleanup_tokyo.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ttl_cleanup_tokyo.arn
}
