data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}



locals {
  expires_at = var.expires_at
  common_tags = {
    Project   = var.project
    Owner     = var.owner
    ExpiresAt = local.expires_at
  }
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
  budget_thresholds = {
    operating = var.operating_budget_usd
    kill      = var.kill_budget_usd
    absolute  = var.absolute_budget_usd
  }
  prometheus_image              = "prom/prometheus@sha256:69961df6ffa67598048a31aa2822d61f3c93b91d7db24e44d9bb03f99d520da9"
  grafana_image                 = "grafana/grafana@sha256:83c197f05ad57b51f5186ca902f0c95fcce45810e7fe738a84cc38f481a2227a"
  artifact_object_arn           = "${var.artifact_bucket_arn}/${var.artifact_key_prefix}/*"
  generator_evidence_object_arn = "${var.artifact_bucket_arn}/${var.generator_evidence_key_prefix}/*"
  generator_evidence_s3_uri     = "s3://${replace(var.artifact_bucket_arn, "arn:aws:s3:::", "")}/${var.generator_evidence_key_prefix}/*"

  api_user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    dnf install -y java-21-amazon-corretto-headless jq
    command -v aws >/dev/null
    install -d -m 0755 /opt/coupon /etc/coupon
    cat >/etc/coupon/runtime.env <<'EOF'
    AWS_REGION=${var.aws_region}
    RDS_ENDPOINT=${aws_db_instance.mysql.address}
    RDS_SECRET_ARN=${aws_db_instance.mysql.master_user_secret[0].secret_arn}
    REDIS_ENDPOINT=${aws_elasticache_replication_group.valkey.primary_endpoint_address}
    DB_NAME=${var.db_name}
    NOTIFY_URL=http://${aws_instance.mock_notify.private_ip}:8090/notify
    EOF
    cat >/opt/coupon/run-coupon-api <<'EOF'
    #!/bin/bash
    set -euo pipefail
    source /etc/coupon/runtime.env
    secret_json=$(aws secretsmanager get-secret-value --region "$AWS_REGION" --secret-id "$RDS_SECRET_ARN" --query SecretString --output text)
    export SPRING_DATASOURCE_USERNAME=$(jq -r '.username' <<<"$secret_json")
    export SPRING_DATASOURCE_PASSWORD=$(jq -r '.password' <<<"$secret_json")
    export SPRING_R2DBC_USERNAME="$SPRING_DATASOURCE_USERNAME"
    export SPRING_R2DBC_PASSWORD="$SPRING_DATASOURCE_PASSWORD"
    export SPRING_DATASOURCE_URL="jdbc:mysql://$RDS_ENDPOINT:3306/$DB_NAME?connectionTimeZone=UTC&rewriteBatchedStatements=true&sslMode=VERIFY_IDENTITY"
    export SPRING_R2DBC_URL="r2dbc:mysql://$RDS_ENDPOINT:3306/$DB_NAME?sslMode=VERIFY_IDENTITY"
    export SPRING_DATA_REDIS_HOST="$REDIS_ENDPOINT"
    export SPRING_DATA_REDIS_PORT=6379
    export SPRING_DATA_REDIS_SSL_ENABLED=true
    export COUPON_NOTIFY_ENABLED=true
    export COUPON_NOTIFY_URL="$NOTIFY_URL"
    exec java -jar /opt/coupon/coupon.jar --spring.profiles.active=reactive
    EOF
    chmod 0755 /opt/coupon/run-coupon-api
    cat >/etc/systemd/system/coupon-api-reactive.service <<'EOF'
    [Unit]
    Description=Coupon reactive API
    After=network-online.target
    Wants=network-online.target
    [Service]
    User=root
    ExecStart=/opt/coupon/run-coupon-api
    Restart=on-failure
    RestartSec=5
    [Install]
    WantedBy=multi-user.target
    EOF
    systemctl daemon-reload
  EOT

  worker_user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    dnf install -y java-21-amazon-corretto-headless jq
    command -v aws >/dev/null
    install -d -m 0755 /opt/coupon /etc/coupon
    cat >/etc/coupon/runtime.env <<'EOF'
    AWS_REGION=${var.aws_region}
    RDS_ENDPOINT=${aws_db_instance.mysql.address}
    RDS_SECRET_ARN=${aws_db_instance.mysql.master_user_secret[0].secret_arn}
    REDIS_ENDPOINT=${aws_elasticache_replication_group.valkey.primary_endpoint_address}
    DB_NAME=${var.db_name}
    NOTIFY_URL=http://${aws_instance.mock_notify.private_ip}:8090/notify
    EOF
    cat >/opt/coupon/run-coupon-worker <<'EOF'
    #!/bin/bash
    set -euo pipefail
    source /etc/coupon/runtime.env
    secret_json=$(aws secretsmanager get-secret-value --region "$AWS_REGION" --secret-id "$RDS_SECRET_ARN" --query SecretString --output text)
    export SPRING_DATASOURCE_USERNAME=$(jq -r '.username' <<<"$secret_json")
    export SPRING_DATASOURCE_PASSWORD=$(jq -r '.password' <<<"$secret_json")
    export SPRING_R2DBC_USERNAME="$SPRING_DATASOURCE_USERNAME"
    export SPRING_R2DBC_PASSWORD="$SPRING_DATASOURCE_PASSWORD"
    export SPRING_DATASOURCE_URL="jdbc:mysql://$RDS_ENDPOINT:3306/$DB_NAME?connectionTimeZone=UTC&rewriteBatchedStatements=true&sslMode=VERIFY_IDENTITY"
    export SPRING_R2DBC_URL="r2dbc:mysql://$RDS_ENDPOINT:3306/$DB_NAME?sslMode=VERIFY_IDENTITY"
    export SPRING_DATA_REDIS_HOST="$REDIS_ENDPOINT"
    export SPRING_DATA_REDIS_PORT=6379
    export SPRING_DATA_REDIS_SSL_ENABLED=true
    export COUPON_NOTIFY_ENABLED=true
    export COUPON_NOTIFY_URL="$NOTIFY_URL"
    exec java -jar /opt/coupon/coupon.jar --spring.profiles.active=worker
    EOF
    chmod 0755 /opt/coupon/run-coupon-worker
    cat >/etc/systemd/system/coupon-worker-stream.service <<'EOF'
    [Unit]
    Description=Coupon Redis Stream worker
    After=network-online.target
    Wants=network-online.target
    [Service]
    User=root
    ExecStart=/opt/coupon/run-coupon-worker
    Restart=on-failure
    RestartSec=5
    [Install]
    WantedBy=multi-user.target
    EOF
    systemctl daemon-reload
  EOT
}


resource "aws_vpc" "benchmark" {
  cidr_block           = "10.60.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_internet_gateway" "benchmark" {
  vpc_id = aws_vpc.benchmark.id
}

resource "aws_subnet" "public_app" {
  for_each = { for index, az in local.azs : index => az }

  vpc_id                  = aws_vpc.benchmark.id
  availability_zone       = each.value
  cidr_block              = cidrsubnet(aws_vpc.benchmark.cidr_block, 8, each.key)
  map_public_ip_on_launch = true

  tags = { Name = "${var.project}-public-app-${each.key + 1}" }
}

resource "aws_subnet" "private_data" {
  for_each = { for index, az in local.azs : index => az }

  vpc_id            = aws_vpc.benchmark.id
  availability_zone = each.value
  cidr_block        = cidrsubnet(aws_vpc.benchmark.cidr_block, 8, each.key + 10)

  tags = { Name = "${var.project}-private-data-${each.key + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.benchmark.id
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.benchmark.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public_app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "alb" {
  name        = "${var.project}-alb"
  description = "Only benchmark clients may reach the ALB"
  vpc_id      = aws_vpc.benchmark.id

  ingress {
    description = "HTTPS from approved load generators"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = tolist(setunion(
      toset([for eip in aws_eip.control_load_generator : "${eip.public_ip}/32"]),
      toset([for eip in aws_eip.external_load_generator : "${eip.public_ip}/32"]),
      toset([var.owner_cidr]),
      var.additional_load_generator_cidrs,
    ))
  }

  egress {
    description = "API targets in the benchmark VPC"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.benchmark.cidr_block]
  }
}

resource "aws_security_group" "api" {
  name        = "${var.project}-api"
  description = "API instances accept application traffic exclusively from the ALB"
  vpc_id      = aws_vpc.benchmark.id

  ingress {
    description     = "Application traffic from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  ingress {
    description     = "Prometheus scrape from monitoring"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }


  egress {
    description = "MySQL to private data services"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.benchmark.cidr_block]
  }

  egress {
    description = "Valkey to private data services"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.benchmark.cidr_block]
  }

  egress {
    description = "Mock notification service"
    from_port   = 8090
    to_port     = 8090
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.benchmark.cidr_block]
  }

  egress {
    description = "SSM and package HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "DNS resolution"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["${cidrhost(aws_vpc.benchmark.cidr_block, 2)}/32"]
  }
  egress {
    description = "DNS fallback resolution"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["${cidrhost(aws_vpc.benchmark.cidr_block, 2)}/32"]
  }
}

resource "aws_security_group" "worker" {
  name        = "${var.project}-worker"
  description = "Workers have no application ingress"
  vpc_id      = aws_vpc.benchmark.id

  ingress {
    description     = "Prometheus scrape from monitoring"
    from_port       = 8081
    to_port         = 8081
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  egress {
    description = "MySQL to private data services"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.benchmark.cidr_block]
  }

  egress {
    description = "Valkey to private data services"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.benchmark.cidr_block]
  }

  egress {
    description = "Mock notification service"
    from_port   = 8090
    to_port     = 8090
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.benchmark.cidr_block]
  }

  egress {
    description = "SSM and package HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "DNS resolution"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["${cidrhost(aws_vpc.benchmark.cidr_block, 2)}/32"]
  }
  egress {
    description = "DNS fallback resolution"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["${cidrhost(aws_vpc.benchmark.cidr_block, 2)}/32"]
  }
}

resource "aws_security_group" "mock_notify" {
  name        = "${var.project}-mock-notify"
  description = "Mock notification ingress is restricted to application roles"
  vpc_id      = aws_vpc.benchmark.id

  ingress {
    description     = "API notification requests"
    from_port       = 8090
    to_port         = 8090
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id]
  }

  ingress {
    description     = "Worker notification requests"
    from_port       = 8090
    to_port         = 8090
    protocol        = "tcp"
    security_groups = [aws_security_group.worker.id]
  }


  egress {
    description = "SSM and package HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "VPC DNS resolution"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["${cidrhost(aws_vpc.benchmark.cidr_block, 2)}/32"]
  }

  egress {
    description = "VPC DNS fallback resolution"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["${cidrhost(aws_vpc.benchmark.cidr_block, 2)}/32"]
  }
}

resource "aws_security_group" "monitoring" {
  name        = "${var.project}-monitoring"
  description = "Monitoring is administered only through SSM port forwarding"
  vpc_id      = aws_vpc.benchmark.id

  egress {
    description = "HTTPS for SSM and package retrieval"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "Prometheus scrape API"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.benchmark.cidr_block]
  }

  egress {
    description = "Prometheus scrape worker"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.benchmark.cidr_block]
  }
  egress {
    description = "VPC DNS resolution"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["${cidrhost(aws_vpc.benchmark.cidr_block, 2)}/32"]
  }

  egress {
    description = "VPC DNS fallback resolution"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["${cidrhost(aws_vpc.benchmark.cidr_block, 2)}/32"]
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project}-rds"
  description = "RDS accepts MySQL only from API and worker instances"
  vpc_id      = aws_vpc.benchmark.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id, aws_security_group.worker.id]
  }
}

resource "aws_security_group" "redis" {
  name        = "${var.project}-redis"
  description = "Valkey accepts traffic only from API and worker instances"
  vpc_id      = aws_vpc.benchmark.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id, aws_security_group.worker.id]
  }
}

resource "aws_iam_role" "ec2_ssm" {
  name = "${var.project}-ec2-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy" "ec2_artifact_and_rds_secret" {
  name = "${var.project}-artifact-and-rds-secret"
  role = aws_iam_role.ec2_ssm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = local.artifact_object_arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = aws_db_instance.mysql.master_user_secret[0].secret_arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "${var.project}-ec2-ssm"
  role = aws_iam_role.ec2_ssm.name
}
resource "aws_iam_role" "ec2_support_ssm" {
  name = "${var.project}-ec2-support-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_support_ssm" {
  role       = aws_iam_role.ec2_support_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_support_ssm" {
  name = "${var.project}-ec2-support-ssm"
  role = aws_iam_role.ec2_support_ssm.name
}

resource "aws_instance" "api" {
  for_each = toset(["1", "2"])

  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.api_instance_type
  subnet_id                   = aws_subnet.public_app[tonumber(each.key) - 1].id
  vpc_security_group_ids      = [aws_security_group.api.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_ssm.name
  associate_public_ip_address = true
  user_data_replace_on_change = true
  user_data                   = local.api_user_data

  metadata_options { http_tokens = "required" }
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 20
  }

  tags = { Name = "${var.project}-api-${each.key}", Role = "api" }
}

resource "aws_instance" "worker" {
  for_each = toset([for index in range(var.worker_count) : tostring(index + 1)])

  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.worker_instance_type
  subnet_id                   = aws_subnet.public_app[(tonumber(each.key) - 1) % length(local.azs)].id
  vpc_security_group_ids      = [aws_security_group.worker.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_ssm.name
  associate_public_ip_address = true
  user_data_replace_on_change = true
  user_data                   = local.worker_user_data

  metadata_options { http_tokens = "required" }
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 20
  }

  tags = { Name = "${var.project}-worker-${each.key}", Role = "worker" }
}

resource "aws_instance" "mock_notify" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.mock_notify_instance_type
  subnet_id                   = aws_subnet.public_app[0].id
  vpc_security_group_ids      = [aws_security_group.mock_notify.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_support_ssm.name
  associate_public_ip_address = true
  user_data_replace_on_change = true
  user_data                   = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    dnf install -y python3
    install -d -m 0755 /opt/mock-notify
    cat >/opt/mock-notify/server.py <<'PY'
    import os
    import random
    import time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    LATENCY_MS = int(os.environ["MOCK_NOTIFY_LATENCY_MS"])
    ERROR_RATE = float(os.environ["MOCK_NOTIFY_ERROR_RATE"])

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            if self.path.split("?", 1)[0] != "/notify":
                self.send_error(404)
                return
            time.sleep(LATENCY_MS / 1000)
            self.send_response(503 if random.random() < ERROR_RATE else 204)
            self.end_headers()


    ThreadingHTTPServer(("0.0.0.0", 8090), Handler).serve_forever()
    PY
    cat >/etc/systemd/system/mock-notify.service <<'UNIT'
    [Unit]
    Description=Coupon mock notification service
    After=network-online.target
    [Service]
    Environment=MOCK_NOTIFY_LATENCY_MS=${var.mock_notify_latency_ms}
    Environment=MOCK_NOTIFY_ERROR_RATE=${var.mock_notify_error_rate}
    ExecStart=/usr/bin/python3 /opt/mock-notify/server.py
    Restart=on-failure
    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now mock-notify
  EOT

  metadata_options { http_tokens = "required" }
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 20
  }

  tags = { Name = "${var.project}-mock-notify", Role = "mock-notify" }
}

resource "aws_instance" "monitoring" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.monitoring_instance_type
  subnet_id                   = aws_subnet.public_app[1].id
  vpc_security_group_ids      = [aws_security_group.monitoring.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_support_ssm.name
  associate_public_ip_address = true
  user_data_replace_on_change = true
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    dnf install -y docker
    systemctl enable --now docker
    install -d -m 0755 /opt/monitoring/grafana/provisioning/datasources
    cat >/opt/monitoring/prometheus.yml <<'EOF'
    global:
      scrape_interval: 5s
    scrape_configs:
      - job_name: coupon
        metrics_path: /actuator/prometheus
        static_configs:
          - targets: ${jsonencode(concat(
  [for instance in aws_instance.api : "${instance.private_ip}:8080"],
  [for instance in aws_instance.worker : "${instance.private_ip}:8081"]
))}
    EOF
    cat >/opt/monitoring/grafana/provisioning/datasources/prometheus.yml <<'EOF'
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus:9090
        isDefault: true
    EOF
    docker network create coupon-monitoring
    docker run -d --restart unless-stopped --name prometheus --network coupon-monitoring \
      -p 9090:9090 \
      -v /opt/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
      ${local.prometheus_image} --config.file=/etc/prometheus/prometheus.yml
    GRAFANA_PASSWORD=$(head -c 32 /dev/urandom | base64)
    install -m 0600 /dev/null /etc/grafana-admin-password
    printf '%s\n' "$GRAFANA_PASSWORD" >/etc/grafana-admin-password
    docker run -d --restart unless-stopped --name grafana --network coupon-monitoring \
      -p 3000:3000 \
      -e GF_SECURITY_ADMIN_PASSWORD="$GRAFANA_PASSWORD" \
      -v /opt/monitoring/grafana/provisioning:/etc/grafana/provisioning:ro \
      ${local.grafana_image}
    unset GRAFANA_PASSWORD
  EOT

metadata_options { http_tokens = "required" }
root_block_device {
  encrypted   = true
  volume_type = "gp3"
  volume_size = 20
}

tags = { Name = "${var.project}-monitoring", Role = "monitoring" }
}

resource "aws_lb" "public" {
  name               = substr("${var.project}-alb", 0, 32)
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for subnet in aws_subnet.public_app : subnet.id]

  enable_deletion_protection = false
}

resource "aws_lb_target_group" "api" {
  name     = substr("${var.project}-api", 0, 32)
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.benchmark.id

  health_check {
    path    = "/actuator/health"
    matcher = "200"
  }
}

resource "aws_lb_target_group_attachment" "api" {
  for_each = aws_instance.api

  target_group_arn = aws_lb_target_group.api.arn
  target_id        = each.value.id
  port             = 8080
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.public.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.acm_certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
resource "aws_lb_listener_rule" "block_actuator" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }

  condition {
    path_pattern {
      values = ["/actuator", "/actuator/*"]
    }
  }
}
resource "aws_lb_listener_rule" "loadgen_calibration" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      status_code  = "204"
    }
  }

  condition {
    path_pattern {
      values = ["/loadgen-calibration"]
    }
  }
}

resource "aws_db_subnet_group" "data" {
  name       = "${var.project}-data"
  subnet_ids = [for subnet in aws_subnet.private_data : subnet.id]
}

resource "aws_db_instance" "mysql" {
  identifier                      = "${var.project}-mysql"
  allocated_storage               = 50
  storage_type                    = "gp3"
  engine                          = "mysql"
  engine_version                  = "8.0"
  instance_class                  = var.db_instance_class
  db_name                         = var.db_name
  username                        = var.db_master_username
  manage_master_user_password     = true
  db_subnet_group_name            = aws_db_subnet_group.data.name
  vpc_security_group_ids          = [aws_security_group.rds.id]
  publicly_accessible             = false
  multi_az                        = false
  storage_encrypted               = true
  backup_retention_period         = 1
  enabled_cloudwatch_logs_exports = ["error", "slowquery"]
  skip_final_snapshot             = true
  deletion_protection             = false
  auto_minor_version_upgrade      = false
}

resource "aws_elasticache_subnet_group" "data" {
  name       = "${var.project}-data"
  subnet_ids = [for subnet in aws_subnet.private_data : subnet.id]
}

resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id       = "${var.project}-valkey"
  description                = "Single-node benchmark Valkey cache"
  engine                     = "valkey"
  engine_version             = "7.2"
  node_type                  = var.cache_node_type
  port                       = 6379
  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false
  subnet_group_name          = aws_elasticache_subnet_group.data.name
  security_group_ids         = [aws_security_group.redis.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  snapshot_retention_limit   = 1
}

resource "aws_cloudwatch_log_group" "lambda_ttl" {
  name              = "/aws/lambda/${var.project}-ttl-cleanup"
  retention_in_days = 3
}

resource "aws_iam_role" "ttl_lambda" {
  name = "${var.project}-ttl-cleanup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ttl_lambda" {
  name = "${var.project}-ttl-cleanup"
  role = aws_iam_role.ttl_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "rds:DescribeDBInstances", "rds:ListTagsForResource"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:StopInstances", "rds:StopDBInstance"]
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
        Resource = "${aws_cloudwatch_log_group.lambda_ttl.arn}:*"
      }
    ]
  })
}

data "archive_file" "ttl_lambda" {
  type        = "zip"
  source_file = "${path.module}/ttl_cleanup.py"
  output_path = "${path.module}/ttl_cleanup.zip"
}

resource "aws_lambda_function" "ttl_cleanup" {
  function_name    = "${var.project}-ttl-cleanup"
  role             = aws_iam_role.ttl_lambda.arn
  handler          = "ttl_cleanup.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.ttl_lambda.output_path
  source_code_hash = data.archive_file.ttl_lambda.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      ENABLE_RDS = "true"
      EXPIRES_AT = local.expires_at
      PROJECT    = var.project
      OWNER      = var.owner
    }
  }
}

resource "aws_cloudwatch_event_rule" "ttl_cleanup" {
  name                = "${var.project}-ttl-cleanup-five-minute"
  description         = "Stops tagged EC2 and RDS resources after benchmark expiration"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "ttl_cleanup" {
  rule = aws_cloudwatch_event_rule.ttl_cleanup.name
  arn  = aws_lambda_function.ttl_cleanup.arn
}

resource "aws_lambda_permission" "eventbridge_ttl_cleanup" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ttl_cleanup.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ttl_cleanup.arn
}

resource "aws_budgets_budget" "delayed_alert" {
  for_each = local.budget_thresholds

  name         = "${var.project}-${each.key}-delayed-alert"
  budget_type  = "COST"
  limit_amount = tostring(each.value)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = toset(["ACTUAL", "FORECASTED"])
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 100
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value
      subscriber_email_addresses = tolist(var.budget_notification_emails)
    }
  }
  lifecycle {
    precondition {
      condition     = var.operating_budget_usd <= var.kill_budget_usd && var.kill_budget_usd <= var.absolute_budget_usd
      error_message = "Budget limits must satisfy operating <= kill <= absolute."
    }
  }
}
