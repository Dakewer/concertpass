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

# Terraform owns this lifecycle; eksctl creates the cluster and its two nodes.
# Existing LabRole and the default VPC are reused without changing IAM.
data "aws_subnet" "selected" {
  for_each = toset(local.subnet_ids)
  id       = each.value
}

resource "aws_security_group" "nodes" {
  name_prefix = "concertpass-nodes-"
  description = "Shared EKS node group managed by Terraform"
  vpc_id      = data.aws_vpc.default.id
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

locals {
  eksctl_config = {
    apiVersion = "eksctl.io/v1alpha5"
    kind       = "ClusterConfig"
    metadata = {
      name = var.cluster_name, region = var.region, version = var.kubernetes_version
      tags = { Project = "concertpass", ManagedBy = "Terraform-eksctl" }
    }
    iam = { serviceRoleARN = data.aws_iam_role.cluster.arn, withOIDC = false }
    accessConfig = {
      authenticationMode                      = "API_AND_CONFIG_MAP"
      bootstrapClusterCreatorAdminPermissions = true
    }
    autoModeConfig = { enabled = false }
    vpc = {
      id                                 = data.aws_vpc.default.id
      subnets                            = { public = { for subnet in data.aws_subnet.selected : subnet.availability_zone => { id = subnet.id } } }
      clusterEndpoints                   = { privateAccess = true, publicAccess = true }
      sharedNodeSecurityGroup            = aws_security_group.nodes.id
      manageSharedNodeSecurityGroupRules = false
    }
    managedNodeGroups = [{
      name              = "concertpass-workers"
      instanceType      = var.node_instance_type
      amiFamily         = "AmazonLinux2023"
      minSize           = 2, maxSize = 2, desiredCapacity = 2
      privateNetworking = false
      disableIMDSv1     = true
      disablePodIMDS    = false
      iam               = { instanceRoleARN = data.aws_iam_role.nodes.arn }
      securityGroups    = { attachIDs = [aws_security_group.nodes.id] }
    }]
    addons = [for name in ["vpc-cni", "coredns", "kube-proxy"] : { name = name }]
  }
}

resource "terraform_data" "eksctl" {
  input            = { config = jsonencode(local.eksctl_config) }
  triggers_replace = [sha256(jsonencode(local.eksctl_config))]

  provisioner "local-exec" {
    interpreter = ["python", "-c"]
    command     = "import runpy; runpy.run_path('../apps/scripts/eks_cluster.py', run_name='__main__')"
    environment = {
      CONCERTPASS_CLUSTER_CONFIG = self.input.config
      CONCERTPASS_CLUSTER_ACTION = "create"
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["python", "-c"]
    command     = "import runpy; runpy.run_path('../apps/scripts/eks_cluster.py', run_name='__main__')"
    environment = {
      CONCERTPASS_CLUSTER_CONFIG = self.input.config
      CONCERTPASS_CLUSTER_ACTION = "delete"
    }
  }
}

data "aws_eks_cluster" "runtime" {
  name       = var.cluster_name
  depends_on = [terraform_data.eksctl]
}

resource "aws_vpc_security_group_ingress_rule" "api_nodeport" {
  security_group_id = data.aws_eks_cluster.runtime.vpc_config[0].cluster_security_group_id
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
    security_groups = [aws_security_group.nodes.id]
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
