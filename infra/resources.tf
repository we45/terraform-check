terraform {
    required_version = ">= 0.12.0"
}

provider "aws" {
    region = "us-west-2"
}

resource "tls_private_key" "this" {
    algorithm = "RSA"
    rsa_bits = 4096
}

resource "aws_key_pair" "server-key" {
    key_name = "server-deployer-key"
    public_key = tls_private_key.this.public_key_openssh
}

variable "vpc_name" {
    description = "name of the vpc"
    default = "tf-new-example"
}

resource "aws_vpc" "new_vpc" {
    cidr_block = "172.16.0.0/16"
    enable_dns_hostnames = true

    tags = {
        Name = var.vpc_name
    }
}


locals {
    golang_user_data = <<EOF
#!/bin/bash
wget -O card-gen https://github.com/we45/Redis-Go-Service/releases/download/1.1/card-gen && chmod +x card-gen && mv card-gen /usr/bin
card-gen 172.16.10.101 6379 &
EOF

}

locals {
    redis_user_data = <<EOF
#!/bin/bash
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo apt install apt-transport-https ca-certificates curl software-properties-common
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y
sudo apt-get update -y
sudo apt-get install -y docker-ce
docker pull redis
docker run -d -p 6379:6379 redis
EOF
}

resource "aws_internet_gateway" "my_igw" {
    vpc_id = aws_vpc.new_vpc.id

    tags = {
        Name = "IGW-Test-VPC"
    }
}

resource "aws_route_table" "igw_router" {
    vpc_id = aws_vpc.new_vpc.id

    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.my_igw.id
    }

    tags = {
        Name = "public-ingress-routed-gateway"
    }
}

resource "aws_subnet" "new_sub" {
    vpc_id = aws_vpc.new_vpc.id
    cidr_block = "172.16.10.0/24"
    availability_zone = "us-west-2a"
    map_public_ip_on_launch = true

    tags = {
        Name = "tf-subnet-example"
    }
}

resource "aws_route_table_association" "subnet_igw" {
    subnet_id = aws_subnet.new_sub.id
    route_table_id = aws_route_table.igw_router.id
}

resource "aws_security_group" "allow-ssh" {
    name = "allow_ssh"
    description = "Allow SSH inbound traffic from the internet"
    vpc_id = aws_vpc.new_vpc.id

    ingress {
        description = "Allow SSH"
        from_port = 22
        to_port = 22
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    ingress {
        description = "Redis in VPC"
        from_port = 6379
        to_port = 6379
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}


resource "aws_network_interface" "goo" {
    subnet_id = aws_subnet.new_sub.id
    private_ips = ["172.16.10.100"]
    security_groups = [aws_security_group.allow-ssh.id]
    tags = {
        Name = "golang-network-interface"
    }
}

resource "aws_network_interface" "redis" {
    subnet_id = aws_subnet.new_sub.id
    private_ips = ["172.16.10.101"]
    security_groups = [aws_security_group.allow-ssh.id]
    tags = {
        Name = "redis-network-interface"
    }
}

resource "aws_instance" "golang-app" {
    ami = "ami-053bc2e89490c5ab7"
    instance_type = "t2.micro"
    key_name = aws_key_pair.server-key.key_name
    user_data_base64 = base64encode(local.golang_user_data)

    tags = {
        Name = "tf-example-ec2-instance"
    }

    network_interface {
        network_interface_id = aws_network_interface.goo.id
        device_index = 0
    }

    depends_on = ["aws_instance.redis-db"]
}

resource "aws_instance" "redis-db" {
    ami = "ami-053bc2e89490c5ab7"
    instance_type = "t2.micro"
    key_name = aws_key_pair.server-key.key_name
    user_data_base64 = base64encode(local.redis_user_data)

    tags = {
        Name = "tf-example-ec2-instance"
    }

    network_interface {
        network_interface_id = aws_network_interface.redis.id
        device_index = 0
    }
}

resource "local_file" "aws_key" {
    content = tls_private_key.this.private_key_pem
    filename = "test-key.pem"
}

output "private_dns" {
    value = aws_instance.redis-db.private_ip
    description = "This is the Private IP of the newly created redis instance"
}

output "public_redis_ip" {
    value = aws_instance.redis-db.public_ip
    description = "Public IP for the Redis Server"
}

output "private_golang_ip" {
    value = aws_instance.golang-app.private_ip
    description = "This is the Private IP of the newly created golang app server"
}

output "public_golang_ip" {
    value = aws_instance.golang-app.public_ip
    description = "Public IP for the golang app server"
}

resource "random_string" "bucket_name" {
    length = 10
    special = false
    upper = false
}

resource "aws_s3_bucket" "flow_log_bucket" {
    bucket = "${random_string.bucket_name.result}-flow-logs"
    force_destroy = true
}

data "aws_caller_identity" "current" {}

output "s3_bucket_url" {
    value = "s3://${aws_s3_bucket.flow_log_bucket.id}/AWSLogs/${data.aws_caller_identity.current.account_id}/vpcflowlogs/us-west-2/"
    description = "s3 bucket url with the URL notation"
}

resource "aws_flow_log" "example" {
    log_destination = aws_s3_bucket.flow_log_bucket.arn
    log_destination_type = "s3"
    traffic_type = "ALL"
    vpc_id = aws_vpc.new_vpc.id
}