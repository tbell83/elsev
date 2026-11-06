# elsev

Terraform for a small AWS environment that runs an nginx container serving a "Hello, World!" page.

*** This repo assumes you are using an s3 bucket called `tbell-elsev-terraform-state` for remote state management, this value is set in `bootstrap/remote_state.tf` as well as `versions.tf` and should be updated accordingly ***

## Architecture

- **Load balancer:** an internal ALB that is only reachable from the bastion host.
- **Docker hosts:** an auto scaling group of t3.micro instances in a private subnet. It scales from 1 to 3 instances to keep the ECS service's average CPU near 30%, and a CloudWatch alarm notifies the `alerting` SNS topic if average host CPU goes above 70%.
- **ECS service:** runs one copy of the nginx container on each Docker host.
- **Bastion host:** an instance in a public subnet, accessed with AWS Systems Manager (SSM) Session Manager. By default it has no SSH access and no ports open to the internet.
- **NAT instance:** a t3.micro in a public subnet that gives the Docker hosts outbound access, so they can pull the container image from ECR.

| Path | Contents |
| --- | --- |
| `*.tf` | The primary Terraform configuration |
| `bootstrap/` | Terraform for the resources that must exist before the primary configuration can run |
| `Dockerfile`, `webapp/` | The container image and the page it serves |
| `.github/workflows/` | Pull request checks and the deployment to AWS |

## Setting up a new environment

You need Terraform 1.17.1 or later, Docker, the AWS CLI, and AWS credentials for the target account. Everything deploys to `us-east-1`.

1. Create the remote state bucket and the ECR repository, then push an image so the ECS service has one to run when it's created. The bucket name is also set in the backend configuration in `versions.tf`.

   ```sh
   make bootstrap
   ```

2. Apply the primary configuration. Its import blocks take over the relevant resources created in step 1. This first apply has to run from your machine, because it creates the roles that GitHub Actions uses.

   ```sh
   terraform init
   AWS_REGION=us-east-1 terraform apply
   ```

3. In the GitHub repository, set these Actions variables to the ARNs of the roles created in step 2:

   | Variable | Role |
   | --- | --- |
   | `AWS_ROLE_ARN` | `elsev-github-actions` |
   | `AWS_PLAN_ROLE_ARN` | `elsev-github-actions-plan` |
   | `AWS_SITE_CHECK_ROLE_ARN` | `elsev-github-actions-site-check` |

The statefile in `bootstrap/` contains the S3 bucket configuration and the repository configuration, neither of which is sensitive and can be committed to git.  Any changes to the bucket can be made in that state, the repo is imported into the primary state and can be managed there going forward.

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
make bastion
```

To reach the site, get the load balancer's DNS name:

```sh
aws elbv2 describe-load-balancers --region us-east-1 --names elsev --query 'LoadBalancers[0].DNSName' --output text
```

Then request it from the bastion session:

```sh
curl -i http://<alb-dns-name>/
```

To reach the site from your own machine, forward a local port to the load balancer through the bastion. This uses Session Manager, so SSH doesn't need to be turned on.

```sh
make tunnel
```

While that runs, request the site from another terminal. Press Ctrl+C to close the tunnel.

```sh
curl -i http://localhost:8080/
```

To use a different local port, run `make tunnel LOCAL_PORT=9090`.

### SSH to the bastion

SSH is off by default. To turn it on, first generate a key on your machine. Keep the private key safe, because Terraform and AWS only ever get the public key.

```sh
ssh-keygen -t ed25519 -f ~/.ssh/elsev-bastion-key
```

Then change the defaults of these variables in `variables.tf`. GitHub Actions applies with those defaults, so values set only on your machine are reverted by the next push to `main`.

| Variable | Set it to |
| --- | --- |
| `bastion_ssh_enabled` | `true` |
| `bastion_ssh_public_key` | The contents of `~/.ssh/elsev-bastion-key.pub` |
| `bastion_ssh_allowed_cidrs` | The IPv4 CIDRs allowed to connect, such as `["203.0.113.10/32"]` |

Turning SSH on or changing `bastion_ssh_public_key` replaces the bastion, which changes its public IP.

Turning SSH off closes port 22 without replacing the bastion, so the public key stays in `ec2-user`'s `authorized_keys` until the next replacement. If the key may be compromised, replace the bastion or remove the key from that file.

To connect:

```sh
make ssh
```

This uses `~/.ssh/elsev-bastion-key`. To use a different key, run `make ssh SSH_KEY=/path/to/key`.

## Tearing down the environment

```sh
make destroy
```

This destroys everything in the primary configuration and deletes the `web` task definition revisions. It keeps the bootstrap resources, which are the remote state bucket and the ECR repository with its images, so `terraform apply` can rebuild the environment without running `make bootstrap` again.

To also delete the bootstrap resources, run this afterwards:

```sh
make destroy-bootstrap
```

This permanently deletes the state bucket, including every version of the state file, and the ECR repository with its images. It refuses to run while the primary state still tracks resources.

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

### t3.micro instead of t2.micro

All instances use t3.micro, because t2.micro isn't free tier eligible on AWS accounts created on or after July 15, 2025. Free tier eligibility only allows the instance type on those accounts. Its hours still use up the account's free tier credits.

Approximate cost and capacity per instance in `us-east-1`:

| | t2.micro | t3.micro |
| --- | --- | --- |
| Monthly running cost | $8.47 | $7.59 |
| vCPUs | 1 | 2 |
| Default CPU credit mode | Standard | Unlimited |
| When CPU credits run out | Throttled to the baseline | Keeps running, with charges for sustained use above the baseline |

The move has these consequences:

- **Scaling reliability:** unlimited mode means a host isn't throttled when its credits run out. On a throttled host, reported CPU stays low, which can stall scaling and keep the CPU alarm from triggering.
- **CPU charges:** a t3.micro's earned credits cover an average of 10% CPU per vCPU, and extra usage costs $0.05 per vCPU-hour. Holding the 30% scaling target around the clock adds about $14.60 per host per month.
- **Task CPU reservation:** the task reserves 2048 CPU units, all of a t3.micro, so the service's CPU metric roughly matches host CPU. Update it in `ecs.tf` if `instance_type` changes to a size with a different vCPU count. A reservation larger than the instance can't be placed, and a smaller one makes the metric read high and the ASG scale out early.

Setting the CPU credit mode to `standard` would cap the extra charges, but it would bring back the throttling problem.
