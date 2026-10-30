locals {
  runtime_hash = sha256(join("", concat(
    [for service in ["ticket-api", "ticket-worker", "ticket-checkout"] : join("", [
      for name in ["Dockerfile", "requirements.txt", "main.py"] : filesha256("${path.module}/../apps/${service}/${name}")
    ])],
    [for f in fileset("${path.module}/../k8s", "*.yaml") : filesha256("${path.module}/../k8s/${f}")],
    [filesha256("${path.module}/../apps/scripts/infrastructure.py"), filesha256("${path.module}/../apps/scripts/runtime_apply.py")]
  )))
}
resource "terraform_data" "applications" {
  triggers_replace = [local.runtime_hash, terraform_data.eksctl.id, aws_secretsmanager_secret_version.db.version_id, aws_sqs_queue.reservations.url]
  input = {
    config = jsonencode({
      region        = var.region, cluster_name = var.cluster_name,
      account_id    = data.aws_caller_identity.current.account_id,
      db_secret_arn = aws_secretsmanager_secret.db.arn,
      events_table  = aws_dynamodb_table.events.name,
      queue_url     = aws_sqs_queue.reservations.url,
      ecr_urls      = { for name, repo in aws_ecr_repository.service : name => repo.repository_url }
    })
  }
  depends_on = [aws_secretsmanager_secret_version.db, aws_vpc_security_group_ingress_rule.api_nodeport]
  provisioner "local-exec" {
    interpreter = ["python", "-c"]
    command     = "import runpy; runpy.run_path('../apps/scripts/runtime_apply.py', run_name='__main__')"
    environment = {
      CONCERTPASS_RUNTIME_CONFIG = self.input.config
      CONCERTPASS_IMAGE_TAG      = "src-${substr(local.runtime_hash, 0, 16)}"
    }
  }
}
