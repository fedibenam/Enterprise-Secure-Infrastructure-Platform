package platform.security

deny[msg] {
  input.resource.type == "aws_db_instance"
  input.resource.publicly_accessible == true
  msg := "Public database exposure is forbidden"
}