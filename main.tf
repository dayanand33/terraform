/*
Once executed, the script will set up a VPC in a specified region.
A VPC is restricted to a region and cannot span across multiple regions.
By default the script reads the input values from terraform.tfvars
To setup VPCs across multiple regions, you have to run the script with a different tfvars file.
terraform -var-file <tfvarfile_name1>
For troubleshooting and debugging set this environment variable TF_LOG=trace
*/
provider "aws" {
  region = "${var.region}"
}

resource "aws_eip" "nat" {
  count = 3
  vpc = true
}


#invoke the VPC module to setup a VPC
module "vpc" {
#terraform-aws-modules Collection of Terraform AWS modules supported by the community
#Terraform module which creates VPC resources on AWS
  source = "terraform-aws-modules/vpc/aws"
  name = var.vpc_name
  cidr = var.vpc_cidr
  azs  = var.azs
  /* Subnet for RDS instances. It is a good practice to have database running within its own
  subnet.
  */
  database_subnets = var.subnet_db_cidrs

  #place holder subnet for any additional services
  private_subnets = var.subnet_private_cidrs


/*
Any ingress from public internet should be allowed only through a public subnet.
*/
  public_subnets   = var.subnet_public_cidrs


  enable_nat_gateway = true
  single_nat_gateway = false
  /* For high availability, each AEZ should have its own NAT gateway.
Why? If an AEZ goes down, the NAT Gateway goes down with it.
Since there are 3 AEZs, we require 3 NAT gateways.
 */
  one_nat_gateway_per_az = true

/*
If you want to provide Internet access to the ec2 instances in the private
subnet, the NAT gateway should have an elastic ip (static public ip)
*/
  external_nat_ip_ids =  "${aws_eip.nat.*.id}"


  enable_vpn_gateway = false


  tags = {
    Terraform = "true"
    Environment = "stage"
  }

}
