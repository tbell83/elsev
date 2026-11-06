Bootstrap the terraform remote state:

`aws s3api create-bucket --bucket tbell-elsev-terraform-state`

The name of this bucket is used to configure the remote state in `versions.tf`

