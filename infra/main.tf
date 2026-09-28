data "aws_vpc" "default" {
  default = true
}

resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_security_group" "db" {
  name_prefix = "concertpass-db-"
  description = "Public PostgreSQL access for local development"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Smallest RDS setup: db.t4g.micro, 20 GB gp2 (PostgreSQL minimum), single AZ, no backups.
resource "aws_db_instance" "main" {
  identifier             = "concertpass-db"
  engine                 = "postgres"
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  storage_type           = "gp2"
  db_name                = var.db_name
  username               = var.db_username
  password               = random_password.db.result
  publicly_accessible    = true
  vpc_security_group_ids = [aws_security_group.db.id]
  multi_az               = false

  backup_retention_period    = 0
  skip_final_snapshot        = true
  deletion_protection        = false
  apply_immediately          = true
  auto_minor_version_upgrade = false
}
