#####
# AWS Prodvider
#####

# Retrieve AWS credentials from env variables AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
provider "aws" {
  version = "~> 2.33.0"
  region  = var.aws_region

  access_key          = ""
  secret_key          = ""
  profile             = var.aws_profile
  allowed_account_ids = var.allowed_account_ids
}


#####
# Generate kubeadm token
#####

module "kubeadm-token" {
  source = "scholzj/kubeadm-token/random"
}

#####
# IAM roles
#####

# Master

data "template_file" "master_policy_json" {
  template = file("${path.module}/template/master-policy.json.tpl")

  vars = {}
}

resource "aws_iam_policy" "master_policy" {
  name        = "${var.cluster_name}-master"
  path        = "/"
  description = "Policy for role ${var.cluster_name}-master"
  policy      = data.template_file.master_policy_json.rendered
}

resource "aws_iam_role" "master_role" {
  name = "${var.cluster_name}-master"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF

}

resource "aws_iam_policy_attachment" "master-attach" {
  name       = "master-attachment"
  roles      = [aws_iam_role.master_role.name]
  policy_arn = aws_iam_policy.master_policy.arn
}

resource "aws_iam_instance_profile" "master_profile" {
  name = "${var.cluster_name}-master"
  role = aws_iam_role.master_role.name
}

resource "aws_iam_role_policy_attachment" "ec2_master_role_policy_attachment" {
  role       = aws_iam_role.master_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}


# Node

data "template_file" "node_policy_json" {
  template = file("${path.module}/template/node-policy.json.tpl")

  vars = {}
}

resource "aws_iam_policy" "node_policy" {
  name        = "${var.cluster_name}-node"
  path        = "/"
  description = "Policy for role ${var.cluster_name}-node"
  policy      = data.template_file.node_policy_json.rendered
}

resource "aws_iam_role" "node_role" {
  name = "${var.cluster_name}-node"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF

}

resource "aws_iam_policy_attachment" "node-attach" {
  name       = "node-attachment"
  roles      = [aws_iam_role.node_role.name]
  policy_arn = aws_iam_policy.node_policy.arn
}

resource "aws_iam_instance_profile" "node_profile" {
  name = "${var.cluster_name}-node"
  role = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "ec2_node_role_policy_attachment" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

#####
# Security Group
#####

# Find VPC details based on Master subnet
data "aws_subnet" "cluster_subnet" {
  id = var.master_subnet_id
}

resource "aws_security_group" "kubernetes" {
  vpc_id = data.aws_subnet.cluster_subnet.vpc_id
  name   = var.cluster_name

  tags = {
    "Name"                                               = var.cluster_name
    format("kubernetes.io/cluster/%v", var.cluster_name) = "owned"
  }
  # var.tags,
}

# Allow outgoing connectivity
resource "aws_security_group_rule" "allow_all_outbound_from_kubernetes" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.kubernetes.id
}

# Allow SSH connections only from specific CIDR (TODO)
resource "aws_security_group_rule" "allow_ssh_from_cidr" {
  count     = length(var.ssh_access_cidr)
  type      = "ingress"
  from_port = 22
  to_port   = 22
  protocol  = "tcp"
  # TF-UPGRADE-TODO: In Terraform v0.10 and earlier, it was sometimes necessary to
  # force an interpolation expression to be interpreted as a list by wrapping it
  # in an extra set of list brackets. That form was supported for compatibilty in
  # v0.11, but is no longer supported in Terraform v0.12.
  #
  # If the expression in the following list itself returns a list, remove the
  # brackets to avoid interpretation as a list of lists. If the expression
  # returns a single list item then leave it as-is and remove this TODO comment.
  cidr_blocks       = [var.ssh_access_cidr[count.index]]
  security_group_id = aws_security_group.kubernetes.id
}

# Allow the security group members to talk with each other without restrictions
resource "aws_security_group_rule" "allow_cluster_crosstalk" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.kubernetes.id
  security_group_id        = aws_security_group.kubernetes.id
}

# Allow API connections only from specific CIDR (TODO)
resource "aws_security_group_rule" "allow_api_from_cidr" {
  count     = length(var.api_access_cidr)
  type      = "ingress"
  from_port = 6443
  to_port   = 6443
  protocol  = "tcp"
  # TF-UPGRADE-TODO: In Terraform v0.10 and earlier, it was sometimes necessary to
  # force an interpolation expression to be interpreted as a list by wrapping it
  # in an extra set of list brackets. That form was supported for compatibilty in
  # v0.11, but is no longer supported in Terraform v0.12.
  #
  # If the expression in the following list itself returns a list, remove the
  # brackets to avoid interpretation as a list of lists. If the expression
  # returns a single list item then leave it as-is and remove this TODO comment.
  cidr_blocks       = [var.api_access_cidr[count.index]]
  security_group_id = aws_security_group.kubernetes.id
}

##########
# Bootstraping scripts
##########

data "template_file" "init_master" {
  template = file("${path.module}/scripts/init-aws-kubernetes-master.sh")

  vars = {
    kubeadm_token = module.kubeadm-token.token
    dns_name      = "${var.cluster_name}.${var.hosted_zone}"
    ip_address    = aws_eip.master.public_ip
    cluster_name  = var.cluster_name
    addons        = join(" ", var.addons)
    aws_region    = var.aws_region
    asg_name      = "${var.cluster_name}-nodes"
    asg_min_nodes = var.min_worker_count
    asg_max_nodes = var.max_worker_count
    aws_subnets   = join(" ", concat(var.worker_subnet_ids, [var.master_subnet_id]))
  }
}

data "template_file" "init_node" {
  template = file("${path.module}/scripts/init-aws-kubernetes-node.sh")

  vars = {
    kubeadm_token     = module.kubeadm-token.token
    master_private_ip = aws_instance.master.private_ip
    dns_name          = "${var.cluster_name}.${var.hosted_zone}"
  }
}

data "template_file" "cloud_init_config" {
  template = file("${path.module}/scripts/cloud-init-config.yaml")

  vars = {
    calico_yaml = base64gzip(file("${path.module}/scripts/calico.yaml"))
  }
}

data "template_cloudinit_config" "master_cloud_init" {
  gzip          = true
  base64_encode = true

  part {
    filename     = "cloud-init-config.yaml"
    content_type = "text/cloud-config"
    content      = data.template_file.cloud_init_config.rendered
  }

  part {
    filename     = "init-aws-kubernete-master.sh"
    content_type = "text/x-shellscript"
    content      = data.template_file.init_master.rendered
  }
}

data "template_cloudinit_config" "node_cloud_init" {
  gzip          = true
  base64_encode = true

  part {
    filename     = "init-aws-kubernetes-node.sh"
    content_type = "text/x-shellscript"
    content      = data.template_file.init_node.rendered
  }
}

#####
# Master - EC2 instance
#####

resource "aws_eip" "master" {
  vpc = true
}

# resource "aws_launch_configuration" "masters" {
#   name_prefix          = "${var.cluster_name}-masters-"
#   image_id             = var.ami_id
#   instance_type        = var.master_instance_type
#   iam_instance_profile = aws_iam_instance_profile.master_profile.name

#   security_groups = [
#     aws_security_group.kubernetes.id,
#   ]

#   associate_public_ip_address = var.public_master

#   user_data = data.template_cloudinit_config.master_cloud_init.rendered

#   root_block_device {
#     volume_type           = "gp2"
#     volume_size           = "50"
#     delete_on_termination = true
#   }

#   lifecycle {
#     create_before_destroy = true
#     ignore_changes        = [user_data]
#   }
# }

# resource "aws_autoscaling_group" "masters" {
#   vpc_zone_identifier = var.master_subnet_ids

#   name                 = "${var.cluster_name}-masters"
#   max_size             = var.max_master_count
#   min_size             = var.min_master_count
#   desired_capacity     = var.min_master_count
#   launch_configuration = aws_launch_configuration.masters.name

#   tags = concat(
#     [{
#       key                 = "kubernetes.io/cluster/${var.cluster_name}"
#       value               = "owned"
#       propagate_at_launch = true
#       },
#       {
#         key                 = "Name"
#         value               = "${var.cluster_name}-master"
#         propagate_at_launch = true
#     }],
#     var.tags2,
#   )
#   lifecycle {
#     ignore_changes = [desired_capacity]
#   }
# }

#####
# Nodes
#####

resource "aws_launch_configuration" "nodes" {
  # depends_on           = [aws_autoscaling_group.masters]
  name_prefix          = "${var.cluster_name}-nodes-"
  image_id             = var.ami_id
  instance_type        = var.worker_instance_type
  iam_instance_profile = aws_iam_instance_profile.node_profile.name

  security_groups = [
    aws_security_group.kubernetes.id,
  ]

  associate_public_ip_address = var.public_worker

  user_data = data.template_cloudinit_config.node_cloud_init.rendered

  root_block_device {
    volume_type           = "gp2"
    volume_size           = "50"
    delete_on_termination = true
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [user_data]
  }
}

resource "aws_autoscaling_group" "nodes" {
  # depends_on           = [aws_autoscaling_group.masters]
  name                 = "${var.cluster_name}-nodes"
  max_size             = var.max_worker_count
  min_size             = var.min_worker_count
  desired_capacity     = var.min_worker_count
  launch_configuration = aws_launch_configuration.nodes.name
  vpc_zone_identifier  = var.worker_subnet_ids
  tags = concat(
    [{
      key                 = "kubernetes.io/cluster/${var.cluster_name}"
      value               = "owned"
      propagate_at_launch = true
      },
      {
        key                 = "Name"
        value               = "${var.cluster_name}-node"
        propagate_at_launch = true
    }],
    var.tags2,
  )

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

#####
# DNS record
#####

# data "aws_route53_zone" "dns_zone" {
#   name         = "${var.hosted_zone}."
#   private_zone = var.hosted_zone_private
# }

resource "aws_route53_record" "master" {
  zone_id = var.hosted_zone
  name    = "${var.cluster_name}.master."
  type    = "A"
  records = [aws_eip.master.public_ip]
  ttl     = 300
}

resource "aws_instance" "master" {
  instance_type = var.master_instance_type

  ami       = var.ami_id
  subnet_id = var.master_subnet_id

  associate_public_ip_address = false

  vpc_security_group_ids = [
    aws_security_group.kubernetes.id,
  ]

  iam_instance_profile = aws_iam_instance_profile.master_profile.name

  user_data = data.template_cloudinit_config.master_cloud_init.rendered

  tags = {
    Name                                                 = join("-", [var.cluster_name, "master"])
    format("kubernetes.io/cluster/%v", var.cluster_name) = "owned"
  }

  root_block_device {
    volume_type           = "gp2"
    volume_size           = "50"
    delete_on_termination = true
  }

  lifecycle {
    ignore_changes = [
      ami,
      user_data,
      associate_public_ip_address,
    ]
  }
}

resource "aws_eip_association" "master_assoc" {
  instance_id   = "${aws_instance.master.id}"
  allocation_id = "${aws_eip.master.id}"
}
