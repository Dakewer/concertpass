variable "region" {
  type    = string
  default = "us-east-1"
}
variable "cluster_name" {
  type    = string
  default = "concertpass"
}
variable "kubernetes_version" {
  type    = string
  default = "1.35"
}
variable "cluster_role_name" {
  description = "Existing role trusted by eks.amazonaws.com; LabRole in AWS Academy."
  type        = string
  default     = "LabRole"
}
variable "node_role_name" {
  description = "Existing EC2 role with EKS, CNI, ECR, SQS and DynamoDB permissions."
  type        = string
  default     = "LabRole"
}
variable "node_instance_type" {
  type    = string
  default = "t3.small"
}
variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}
variable "db_name" {
  type    = string
  default = "concertpass"
}
variable "db_username" {
  type    = string
  default = "concertpass"
}
variable "api_allowed_cidr" {
  description = "IPv4 CIDR allowed to reach the API NodePort."
  type        = string
  default     = "0.0.0.0/0"
}
