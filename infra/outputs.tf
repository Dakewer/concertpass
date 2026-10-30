output "region" {
  value = var.region
}
output "cluster_name" {
  value = var.cluster_name
}
output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
output "queue_url" {
  value = aws_sqs_queue.reservations.url
}
output "events_table" {
  value = aws_dynamodb_table.events.name
}
output "db_secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}
output "ecr_urls" {
  value = { for name, repo in aws_ecr_repository.service : name => repo.repository_url }
}
output "node_role_arn" {
  value = data.aws_iam_role.nodes.arn
}

output "eksctl_stack_names" {
  value = ["eksctl-${var.cluster_name}-cluster", "eksctl-${var.cluster_name}-nodegroup-concertpass-workers"]
}
