/*
Once executed, the script will set up a VPC in a specified region.
A VPC is restricted to a region and cannot span across multiple regions.
By default the script reads the input values from terraform.tfvars
To setup VPCs across multiple regions, you have to run the script with a different tfvars file.
terraform -var-file <tfvarfile_name1>
For troubleshooting and debugging set this environment variable TF_LOG=trace
*/
data "aws_caller_identity" "current" {
  provider = aws.east
}

# VPC data sources
data "aws_vpc" "selected" {
  id = "vpc-id"

  provider = aws.east
}

resource "aws_subnet" "private" {
  count = length(local.vpc_east_private_cidrs)

  vpc_id            = local.vpc_id
  cidr_block        = local.vpc_east_private_cidrs[count.index]
  availability_zone = local.vpc_east_azs[count.index]

  tags = local.tags

  provider = aws.east
}




# ECR repositories
module "ecr_repository" {

  source  = "lgallard/ecr/aws"
  version = "0.3.2"

  name            = "service name"
  scan_on_push    = true

  tags = {
    Project     = "demo project"
    Environment = "us-east"
  }

  providers = {
    aws = aws.east
  }
}
##################################
  locals{
  vpc_east_private_cidrs =   [ "range1", "range2",  "range3", "range4",    "range5", "range6" ]
  vpc_east_azs           = ["us-east-1c", "us-east-1b", "us-east-1a", "us-east-1c", "us-east-1b", "us-east-1a"]
  vpc_id                 = "vpc-id"

  tags = {
    Project     = local.name
    Environment = "dev"
  }
  name = "demoproj"
}
