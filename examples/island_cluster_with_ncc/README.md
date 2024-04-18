# GKE island cluster using NCC

This example provisions a cluster in an island VPC allowing reuse of the IP address space for multiple clusters within the organization.

## Deploy

1. Update `project_id`, `cluster_name` values in `terraform.tfvars`, and update other variables as needed.
1. Run `terraform apply`.
