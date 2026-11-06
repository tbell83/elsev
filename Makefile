SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.ONESHELL:

export AWS_REGION := us-east-1

BASTION_NAME := elsev-bastion
ALB_NAME := elsev
REPOSITORY := webapp
STATE_BUCKET := tbell-elsev-terraform-state
TASK_FAMILY := web
SSH_KEY ?= $(HOME)/.ssh/elsev-bastion-key
LOCAL_PORT ?= 8080

.DEFAULT_GOAL := help

.PHONY: help bastion ssh tunnel bootstrap destroy destroy-bootstrap

help:
	@echo "make bastion    Connect to the bastion with SSM Session Manager"
	@echo "make ssh        Connect to the bastion with SSH, using SSH_KEY"
	@echo "make tunnel     Forward localhost:LOCAL_PORT (default 8080) to the ALB through the bastion"
	@echo "make bootstrap  Create the bootstrap resources and push the initial image"
	@echo "make destroy    Destroy everything except the bootstrap resources"
	@echo "make destroy-bootstrap  Destroy the bootstrap resources, after make destroy"

bastion:
	@instance_id=$$(aws ec2 describe-instances \
		--filters Name=tag:Name,Values=$(BASTION_NAME) Name=instance-state-name,Values=running \
		--query 'Reservations[0].Instances[0].InstanceId' --output text)
	if [ "$$instance_id" = "None" ]; then
		echo "No running instance named $(BASTION_NAME)" >&2
		exit 1
	fi
	aws ssm start-session --target "$$instance_id"

ssh:
	@public_ip=$$(aws ec2 describe-instances \
		--filters Name=tag:Name,Values=$(BASTION_NAME) Name=instance-state-name,Values=running \
		--query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
	if [ "$$public_ip" = "None" ]; then
		echo "No running instance named $(BASTION_NAME)" >&2
		exit 1
	fi
	ssh -i "$(SSH_KEY)" "ec2-user@$$public_ip"

tunnel:
	@instance_id=$$(aws ec2 describe-instances \
		--filters Name=tag:Name,Values=$(BASTION_NAME) Name=instance-state-name,Values=running \
		--query 'Reservations[0].Instances[0].InstanceId' --output text)
	if [ "$$instance_id" = "None" ]; then
		echo "No running instance named $(BASTION_NAME)" >&2
		exit 1
	fi
	alb_dns_name=$$(aws elbv2 describe-load-balancers --names $(ALB_NAME) \
		--query 'LoadBalancers[0].DNSName' --output text)
	aws ssm start-session --target "$$instance_id" \
		--document-name AWS-StartPortForwardingSessionToRemoteHost \
		--parameters "host=$$alb_dns_name,portNumber=80,localPortNumber=$(LOCAL_PORT)"

bootstrap:
	@terraform -chdir=bootstrap init
	terraform -chdir=bootstrap apply
	repository_url=$$(aws ecr describe-repositories --repository-names $(REPOSITORY) \
		--query 'repositories[0].repositoryUri' --output text)
	aws ecr get-login-password | docker login --username AWS --password-stdin "$${repository_url%%/*}"
	docker build -t "$$repository_url:latest" .
	docker push "$$repository_url:latest"

# The primary configuration imports the ECR repository, so it has to leave that
# state or the destroy would delete it. The next apply imports it again.
#
# Terraform leaves task definition revisions behind, because of skip_destroy and
# because the Container Deploy workflow registers its own.
destroy:
	@terraform init
	if [ -n "$$(terraform state list aws_ecr_repository.webapp)" ]; then
		terraform state rm aws_ecr_repository.webapp
	fi
	terraform destroy
	aws ecs list-task-definitions --family-prefix $(TASK_FAMILY) --status ACTIVE \
		--query 'taskDefinitionArns[]' --output text \
		| xargs -r -n 1 aws ecs deregister-task-definition --query 'taskDefinition.taskDefinitionArn' --output text --task-definition
	aws ecs list-task-definitions --family-prefix $(TASK_FAMILY) --status INACTIVE \
		--query 'taskDefinitionArns[]' --output text \
		| xargs -r -n 10 aws ecs delete-task-definitions --query 'tasks[].taskDefinitionArn' --output text --task-definitions

# The bucket holds the primary state, so deleting it while that state still tracks
# resources would leave them running with nothing managing them.
destroy-bootstrap:
	@if aws s3api head-bucket --bucket $(STATE_BUCKET) > /dev/null 2>&1; then
		terraform init
		if [ -n "$$(terraform state list)" ]; then
			echo "The primary state still tracks resources. Run make destroy first." >&2
			exit 1
		fi
	fi
	terraform -chdir=bootstrap init
	terraform -chdir=bootstrap destroy
