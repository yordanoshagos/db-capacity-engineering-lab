resource "aws_security_group" "c5_open" {
  name        = "c5-open"
  description = "deliberate trivy fail — C5"
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
