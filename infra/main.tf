data "aws_caller_identity" "current" {}
data "aws_iam_role" "cluster" {
  name = var.cluster_role_name
}
data "aws_iam_role" "nodes" {
  name = var.node_role_name
}
data "aws_vpc" "default" {
  default = true
}
data "aws_availability_zones" "supported" {
  state            = "available"
  exclude_zone_ids = var.region == "us-east-1" ? ["use1-az3"] : []
}
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
  filter {
    name   = "availability-zone"
    values = data.aws_availability_zones.supported.names
  }
}
locals {
  subnet_ids = slice(sort(data.aws_subnets.default.ids), 0, 2)
  events = {
    bad-bunny-gdl = {
      name     = "Bad Bunny Debi tirar mas fotos", date = "2026-11-15", recinto = "Estadio Akron, GDL"
      capacity = { floor = 100, vip = 50, general = 500 }
    }
    artista-nicho-cdmx = {
      name     = "Artista de nicho", date = "2026-12-05", recinto = "Foro Indie, CDMX"
      capacity = { floor = 4, vip = 3, general = 8 }
    }
  }
}

# LabRole already trusts EKS/EC2 and has the lab policies. Terraform never edits it.
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = data.aws_iam_role.cluster.arn
  vpc_config {
    subnet_ids              = local.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  }
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }
}
resource "aws_launch_template" "nodes" {
  name_prefix = "concertpass-nodes-"
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
}
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "concertpass-workers"
  node_role_arn   = data.aws_iam_role.nodes.arn
  subnet_ids      = local.subnet_ids
  instance_types  = [var.node_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"
  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }
  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 2
  }
  update_config {
    max_unavailable = 1
  }
}
resource "aws_eks_addon" "system" {
  for_each                    = toset(["vpc-cni", "kube-proxy", "coredns"])
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.main]
}
resource "aws_vpc_security_group_ingress_rule" "api_nodeport" {
  security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  cidr_ipv4         = var.api_allowed_cidr
  from_port         = 30080
  to_port           = 30080
  ip_protocol       = "tcp"
  description       = "Concertpass API NodePort"
}

resource "random_password" "db" {
  length  = 32
  special = false
}
resource "aws_security_group" "db" {
  name_prefix = "concertpass-db-"
  description = "PostgreSQL only from EKS nodes"
  vpc_id      = data.aws_vpc.default.id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
  }
}
resource "aws_db_subnet_group" "main" {
  name       = "concertpass-db-subnets"
  subnet_ids = local.subnet_ids
}
resource "aws_db_instance" "main" {
  identifier                 = "concertpass-db"
  engine                     = "postgres"
  instance_class             = var.db_instance_class
  allocated_storage          = 20
  storage_type               = "gp3"
  storage_encrypted          = true
  db_name                    = var.db_name
  username                   = var.db_username
  password                   = random_password.db.result
  db_subnet_group_name       = aws_db_subnet_group.main.name
  vpc_security_group_ids     = [aws_security_group.db.id]
  publicly_accessible        = false
  multi_az                   = false
  backup_retention_period    = 0
  skip_final_snapshot        = true
  deletion_protection        = false
  apply_immediately          = true
  auto_minor_version_upgrade = true
}
resource "aws_secretsmanager_secret" "db" {
  name                    = "concertpass/database"
  recovery_window_in_days = 0
}
resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({ host = aws_db_instance.main.address, port = aws_db_instance.main.port,
  dbname = var.db_name, username = var.db_username, password = random_password.db.result })
}
resource "aws_sqs_queue" "dlq" {
  name                      = "concertpass-reservations-dlq.fifo"
  fifo_queue                = true
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}
resource "aws_sqs_queue" "reservations" {
  name                        = "concertpass-reservations.fifo"
  fifo_queue                  = true
  content_based_deduplication = false
  visibility_timeout_seconds  = 60
  receive_wait_time_seconds   = 20
  sqs_managed_sse_enabled     = true
  redrive_policy              = jsonencode({ deadLetterTargetArn = aws_sqs_queue.dlq.arn, maxReceiveCount = 5 })
}
resource "aws_dynamodb_table" "events" {
  name         = "concert-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "concert_id"
  attribute {
    name = "concert_id"
    type = "S"
  }
}
resource "aws_dynamodb_table_item" "event" {
  for_each   = local.events
  table_name = aws_dynamodb_table.events.name
  hash_key   = aws_dynamodb_table.events.hash_key
  item = jsonencode({
    concert_id = { S = each.key }, name = { S = each.value.name }, date = { S = each.value.date },
    recinto    = { S = each.value.recinto },
    capacity   = { M = { for section, capacity in each.value.capacity : section => { N = tostring(capacity) } } }
  })
}
resource "aws_ecr_repository" "service" {
  for_each             = toset(["ticket-api", "ticket-worker", "ticket-checkout"])
  name                 = "concertpass/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
}
