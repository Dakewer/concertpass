output "endpoint" {
  value = aws_db_instance.main.address
}

output "db_port" {
  value = aws_db_instance.main.port
}

output "db_username" {
  value = aws_db_instance.main.username
}

output "db_name" {
  value = aws_db_instance.main.db_name
}

output "db_password" {
  description = "Use with: terraform output -raw db_password"
  value       = random_password.db.result
  sensitive   = true
}

output "connection_url" {
  description = "Use with: terraform output -raw connection_url"
  value       = "postgresql://${aws_db_instance.main.username}:${random_password.db.result}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${aws_db_instance.main.db_name}"
  sensitive   = true
}
