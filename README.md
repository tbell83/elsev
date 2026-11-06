# elsev

Terraform for a small AWS environment that runs an nginx container serving a "Hello, World!" page.

## Architecture

- **Load balancer:** an internal ALB that is only reachable from the bastion host.
- **Docker hosts:** an auto scaling group of t3.micro instances in a private subnet. It scales from 1 to 3 instances to keep the ECS service's average CPU near 30%, and a CloudWatch alarm notifies the `alerting` SNS topic if average host CPU goes above 70%.
- **ECS service:** runs one copy of the nginx container on each Docker host.
- **Bastion host:** an instance in a public subnet, accessed with AWS Systems Manager (SSM) Session Manager. It needs no SSH and has no ports open to the internet.
- **NAT instance:** a t3.micro in a public subnet that gives the Docker hosts outbound access, so they can pull the container image from ECR.

| Path | Contents |
| --- | --- |
| `*.tf` | The primary Terraform configuration |
| `bootstrap/` | Terraform for the resources that must exist before the primary configuration can run |
| `Dockerfile`, `webapp/` | The container image and the page it serves |
| `.github/workflows/` | Pull request checks and the deployment to AWS |

## Setting up a new environment

You need Terraform 1.17.1 or later, Docker, the AWS CLI, and AWS credentials for the target account. Everything deploys to `us-east-1`.

1. Create the remote state bucket and the ECR repository. The bucket name is also set in the backend configuration in `versions.tf`.

   ```sh
   terraform -chdir=bootstrap init
   terraform -chdir=bootstrap apply
   ```

2. Push an image, so the ECS service has one to run when it's created.

   ```sh
   repository_url=$(aws ecr describe-repositories --region us-east-1 --repository-names webapp --query 'repositories[0].repositoryUri' --output text)
   aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "${repository_url%%/*}"
   docker build -t "$repository_url:latest" .
   docker push "$repository_url:latest"
   ```

3. Apply the primary configuration. Its import blocks take over the resources created in step 1. This first apply has to run from your machine, because it creates the roles that GitHub Actions uses.

   ```sh
   terraform init
   terraform apply
   ```

4. Delete `bootstrap/terraform.tfstate`. The primary state now owns the bucket and repository, so don't apply `bootstrap` again.

5. In the GitHub repository, set these Actions variables to the ARNs of the roles created in step 3:

   | Variable | Role |
   | --- | --- |
   | `AWS_ROLE_ARN` | `elsev-github-actions` |
   | `AWS_PLAN_ROLE_ARN` | `elsev-github-actions-plan` |
   | `AWS_SITE_CHECK_ROLE_ARN` | `elsev-github-actions-site-check` |

The bucket and repository are defined in both `bootstrap/` and the primary configuration, so make any change to them in both places.

## Deployment

| Trigger | What runs |
| --- | --- |
| Pull request | `terraform fmt`, `validate`, and `plan` using a read-only role |
| Push to `main` | Runs `terraform apply`, then checks from the bastion that the site returns HTTP 200 |
| Push to `main` that changes `Dockerfile` or `webapp/` | Builds an image tagged with the git hash, pushes it to ECR, rolls out a new task definition revision, then runs the same HTTP 200 check |

If the rollout or the check fails, the workflow returns the service to the task definition revision it was running before the deploy. The run still shows as failed.

Terraform creates the ECS service and the first task definition revision, but doesn't deploy new revisions. A change to the task definition in Terraform registers a new revision, which only takes effect on the next container deploy. To roll it out without changing the image, re-run the most recent successful Container Deploy run.

The `latest` image tag is only used for the first revision. It's the image pushed during setup and the workflow doesn't update it, so don't deploy a Terraform-registered revision directly with `aws ecs update-service`, because it would run that original image.

## Accessing the environment

Connecting to the bastion requires the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for the AWS CLI.

```sh
aws ssm start-session --region us-east-1 --target "$(aws ec2 describe-instances --region us-east-1 \
  --filters Name=tag:Name,Values=elsev-bastion Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
```

To reach the site, get the load balancer's DNS name:

```sh
aws elbv2 describe-load-balancers --region us-east-1 --names elsev --query 'LoadBalancers[0].DNSName' --output text
```

Then request it from the bastion session:

```sh
curl -i http://<alb-dns-name>/
```

## Cost considerations

### NAT instance instead of a NAT gateway

The Docker hosts reach the internet through a NAT instance rather than a managed NAT gateway, because this small environment doesn't justify the cost of a gateway.

Approximate monthly cost in `us-east-1`, excluding the public IPv4 address that both options need:

| | NAT gateway | NAT instance |
| --- | --- | --- |
| Running cost | $32.85 | $7.59 (t3.micro) |
| Root volume | None | $0.64 (8 GB gp3) |
| Data processing | $0.045/GB | None |
| **Total before data** | **$32.85** | **$8.23** |

Standard AWS data transfer charges apply to both.

The lower cost comes with these trade-offs:

- **Availability:** the instance is a single point of failure and nothing replaces it automatically. If it fails, running tasks should keep serving through the ALB, but new tasks and hosts can't start because they can't reach ECS or ECR.
- **Throughput:** a t3.micro has modest sustained network capacity, so large image pulls can be slow, and sustained CPU use above its baseline adds charges.
- **Maintenance:** we are responsible for patching the instance and for its forwarding configuration. New AMI releases aren't applied automatically, because replacing the instance would interrupt outbound access.

Consider moving to a NAT gateway if the environment starts to need high availability or sustained outbound traffic.
