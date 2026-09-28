variable "region" {
  type    = string
  default = "us-east-1"
}

variable "db_name" {
  type    = string
  default = "concertpass"
}

variable "db_username" {
  type    = string
  default = "concertpass"
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach the database. Restrict to your IP (x.x.x.x/32) if possible."
  type        = string
  default     = "0.0.0.0/0"
}
