output "master_public_ip" {
  value = aws_instance.chaos-master.public_ip
}

output "worker_public_ips" {
  value = aws_instance.chaos-worker[*].public_ip
}