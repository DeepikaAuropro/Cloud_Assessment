output "db_instance_endpoint" {
  value       = aws_db_instance.myrds.endpoint
}

output "example_output" {
  value = aws_db_instance.myrds.id
}