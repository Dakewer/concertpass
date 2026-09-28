output "endpoint" {
  value = aws_db_instance.main.address
}

output "connection_url" {
  description = "Use with: terraform output -raw connection_url"
  value       = "postgresql://${aws_db_instance.main.username}:${random_password.db.result}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${aws_db_instance.main.db_name}"
  sensitive   = true
}
