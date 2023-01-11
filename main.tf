# We're using ubuntu images - this lets us grab the latest image for our region from Canonical
data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-*-20.04-arm64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["099720109477"] # Canonical
}

# turn the sg into a sorted list of string
locals {
  sg_wireguard_external = sort([aws_security_group.sg_wireguard_external.id])
}

# clean up and concat the above wireguard default sg with the additional_security_group_ids
locals {
  security_groups_ids = compact(concat(var.additional_security_group_ids, local.sg_wireguard_external))
}

resource "aws_launch_template" "wireguard_launch_config" {
  name_prefix   = "wireguard-${var.env}-"
  image_id      = var.ami_id == null ? data.aws_ami.ubuntu.id : var.ami_id
  instance_type = var.instance_type
  key_name      = var.ssh_key_id
  iam_instance_profile {
    arn = (var.use_eip ? aws_iam_instance_profile.wireguard_profile[0].arn : null)
  }

  user_data = templatefile("${path.module}/templates/user-data.txt", {
    wg_server_private_key   = data.aws_ssm_parameter.wg_server_private_key.value
    wg_server_port          = var.wg_server_port
    peer_keys               = var.wg_client_public_keys
    use_eip                 = var.use_eip ? "enabled" : "disabled"
    eip_id                  = var.eip_id
    wg_server_interface     = var.wg_server_interface
    wg_persistent_keepalive = var.wg_persistent_keepalive
  })

  vpc_security_group_ids = local.security_groups_ids

  network_interfaces {
    associate_public_ip_address = true
  }
}

resource "aws_autoscaling_group" "wireguard_asg" {
  name                 = aws_launch_template.wireguard_launch_config.name
  min_size             = var.asg_min_size
  desired_capacity     = var.asg_desired_capacity
  max_size             = var.asg_max_size
  vpc_zone_identifier  = var.subnet_ids
  health_check_type    = "EC2"
  termination_policies = ["OldestLaunchConfiguration", "OldestInstance"]
  target_group_arns    = var.target_group_arns

  launch_template {
    id      = aws_launch_template.wireguard_launch_config.id
    version = "$Latest"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = [
    {
      key                 = "Name"
      value               = aws_launch_template.wireguard_launch_config.name
      propagate_at_launch = true
    },
    {
      key                 = "Project"
      value               = "wireguard"
      propagate_at_launch = true
    },
    {
      key                 = "env"
      value               = var.env
      propagate_at_launch = true
    },
    {
      key                 = "tf-managed"
      value               = "True"
      propagate_at_launch = true
    },
  ]
}
