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

/*
Why do we need NAT gateways?
NAT gateway manages outbound internet traffic.
Let us say you have an RDS instance within a private subnet.
The instance needs to install the latest security patch available
on the vendor website. In order to download the patch, the instance
needs to make an outbound connection to a resource on the Internet.
NAT does not allow any inbound traffic from internet. Therefore it is
not possible for any resource outside of VPC to make an inbound
connection to NAT
Route table of the given private subnet directs outbound internet traffic to nat gateway.
*/
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

/******** Application load balancer*******************************************/
resource "random_pet" "this" {
  length = 2
}

module "security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "alb-sg-${random_pet.this.id}"
  description = "Security group for example usage with ALB"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["http-80-tcp", "all-icmp"]
  egress_rules        = ["all-all"]
}



module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 6.0"

  name = "my-alb"

  load_balancer_type = "application"

  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.private_subnets
  security_groups    = [module.security_group.security_group_id]



  target_groups = [
    {
      name_prefix      = "pref-"
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "instance"
      targets = [
        {
          target_id = module.ec2_instance[0].id
          port = 80
        },
        {
          target_id = module.ec2_instance[1].id
          port = 80
        },
        {
          target_id = module.ec2_instance[2].id
          port = 80
        }
      ]
    }
  ]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    }
  ]

  tags = {
    Environment = "Test"
  }
}



module "ec2_instance" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 3.0"

  count = length(module.vpc.private_subnets)
  name = "ec2-${module.vpc.private_subnets[count.index]}"

  ami                    = "ami-02e136e904f3da870"
  instance_type          = "t2.micro"
  monitoring             = true
  vpc_security_group_ids = [module.security_group.security_group_id]
  subnet_id              = "${module.vpc.private_subnets[count.index]}"

  tags = {
    Terraform   = "true"
    Environment = "stage"
  }
}
