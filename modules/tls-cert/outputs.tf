output "cert_arn" {
  description = "ARN of the ACM certificate"
  value       = aws_acm_certificate_validation.this.certificate_arn
}
