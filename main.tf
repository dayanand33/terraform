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


data "aws_vpc" "imported_vpc" {
  id = "vpc-someid"

  provider = aws
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
  #database_subnets = var.subnet_db_cidrs

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
  /* For high availability, each AEZ should have its own NAT gateway.
Why? If an AEZ goes down, the NAT Gateway goes down with it.
Since there are 3 AEZs, we require 3 NAT gateways.
 */
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
  reuse_nat_ips = true
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

#EC2-SecurityGroup
/*
 What is a security group?
  A security group acts as a virtual firewall for your EC2 instances to control incoming and outgoing traffic.
  Inbound rules control the incoming traffic to your instance, and outbound rules control the outgoing traffic from your instance.
  If you don't specify a security group, Amazon EC2 uses the default security group, which allows inbound/oubound access open for all ports,
  ips, and protocols.

  In this module, inbound rule allows source traffic only through the load balancer security group, on port 80 using the tcp protocol.
  As for outbound rules, destination traffic can flow through any port, to any IP, and for all protocols.
*/
module "security_group_ec2" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name                 = "my-ec2-sg-${random_pet.this.id}"
  description          = "EC2 Security Group"
  vpc_id               = module.vpc.vpc_id

  ingress_with_source_security_group_id = [
   {
      from_port         = 80
      to_port           = 80
      protocol          = "tcp"
	  description       = "HTTP TCP"
	  source_security_group_id = "${module.security_group_alb.security_group_id}"
   }
  ]

  egress_cidr_blocks = ["0.0.0.0/0"]
  egress_rules        = ["all-all"]
}

/*ALB-SecurityGroup
 What is a security group?
  A security group acts as a virtual firewall for your EC2 instances to control incoming and outgoing traffic.
  Inbound rules control the incoming traffic to your instance, and outbound rules control the outgoing traffic from your instance.
  If you don't specify a security group, Amazon EC2 uses the default security group, which allows inbound/oubound access open for all ports,
  ips, and protocols.

  In this module, inbound traffic rule allows access for all ips, but only on port 80 and 443 using the tcp protocol.
  Outbound traffic will follow initial ingress cidr block rule setup for all IPs.
  Outbound rules will allow traffics for all protocols and ports too.
*/
module "security_group_alb" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "my-alb-sg-${random_pet.this.id}"
  description = "Security group for example usage with ALB"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["http-80-tcp", "https-443-tcp"]
  egress_rules        = ["all-all"]
}


/*
   What is a load balancer?
   A load balancer is a device that acts as a reverse proxy and distributes network/application traffic across a number of servers/applications.
   A load balancers is used to increase capacity, via redirecting concurrent requests, and reliability of applications.
   They improve the overall performance of applications by decreasing the burden on servers associated with managing and maintaining application
   and network sessions, as well as by performing application-specific tasks.

   In this module, the security group is referenced.
   A 'target group' resource is defined where three EC2 instance targets will receive 'forward'ed traffic  on port 80.
   A 'HTTP listener' resource is defined to listen on port 80 for an request traffic.
   By default, it 'forwards' whatever traffic it receives to defined target(s).
*/
module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 6.0"

  name = "my-alb"

  load_balancer_type = "application"

  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  security_groups    = [module.security_group_alb.security_group_id]


  target_groups = [
    {
      name      = "my-alb-tg"
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

	  tags = {
        InstanceTargetGroupTag = "my-http-alb-target-group"
      }
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
      Terraform = "true"
      Environment = "stage"
    }
}

/*
What is a EC2 instance?
   An Amazon EC2 instance is a virtual server in Amazon's Elastic Compute Cloud (EC2) for
   running applications on the Amazon Web Services (AWS) infrastructure.

In this EC2 module, the following have been configured:
 -Instance is created from a free tier linux based amazon machine image(AMI) where the instane type is 't2.micro'.
 -The EC2 security group is referenced.
 -Three instances are created, per subnet, for demo purposes to show an application load balancer's [http request] traffic forwarding capability.
 -Setting 'associate instance to a public ip' is set to 'true', so instance can install software(i.e. webserver, etc), from public domain(internet), via NAT gateway and elastic IPs.
 -Instance upon creation, installs a web server and serves(response back to ALB) an index.html page with a greeting message with instance hostname embedded.
 -There was a race condition observed in the creation and startup of the instances before the vpc was fully deployed and setup.
   As a result, the 'depends_on' meta argument is set so the instances will be created/started after the vpc's installation/startup is complete.
*/
module "ec2_instance" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 3.0"
  count = 3
  name = "ec2-${module.vpc.private_subnets[count.index]}"

  ami                    = "ami-someamid"
  instance_type          = "t2.micro"
  monitoring             = true
  vpc_security_group_ids = [module.security_group_ec2.security_group_id]
  subnet_id              = "${module.vpc.private_subnets[count.index]}"
  associate_public_ip_address = true

  user_data = <<-EOF
    #!/bin/bash
    sudo yum install httpd -y
    sudo systemctl enable httpd
    sudo echo "<h1>This is my app on $(hostname -f)</h1>" > /var/www/html/index.html
    sudo systemctl start httpd
  EOF

  tags = {
    Terraform   = "true"
    Environment = "stage"
  }

  depends_on = [module.vpc]
}
