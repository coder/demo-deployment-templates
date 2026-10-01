# =============================================================================
# DemoBuilder demo: the deployment template
# =============================================================================
# This is the artifact the manager builds as the sole Terraform executor under
# R5.2. Pushing this ordinary Terraform with `coder deployment-templates push`
# and declaring the coder_metadata contract at the bottom makes it a deployment
# template and tells the managing instance where the demo lives.
#
# OWNERSHIP: everything created here is Tier 3 in docs/ownership-contract.md,
# and the delete build destroys exactly this set. Nothing here creates a DNS
# record, a certificate, a load balancer, a VPC, a subnet, or a security group.
# This enforces the R10.3 shared-infrastructure boundary by construction.
#
# The same template body can be driven directly during development or by a
# managing Coder instance.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    coder  = { source = "coder/coder" }
  }
}

provider "aws" {
  region = var.region
  # Empty when a Coder provisioner runs this: the provisioner authenticates
  # with the deployer host's instance role via the default credential chain.
  # A named profile only applies when driving this template by hand.
  profile = var.profile != "" ? var.profile : null
}

variable "region" {
  type        = string
  default     = "us-west-2"
  description = "Must match the sandbox plane's region."
}

variable "profile" {
  type        = string
  default     = ""
  description = "Local override only. Empty means use the instance role, which is how a Coder provisioner runs this."
}

# ---------------------------------------------------------------------------
# Demo-meaningful inputs
# ---------------------------------------------------------------------------
# Deliberately NOT subnet IDs, listener ARNs, or security group IDs. Those are
# discovered below. Per docs/ownership-contract.md, keeping infrastructure out
# of the parameter list lets the presenter agent supply only values a presenter
# would actually say out loud.

# These are coder_parameter data sources, not Terraform variables. A variable
# in a Coder template is fixed when the template version is pushed, so every
# demo built from a version shared one value: every earlier demo host carried
# DemoName=skeleton regardless of its deployment name. Rich parameters are
# supplied per build by the caller (DemoBuilder sends demo_name and
# coder_version) and recorded on the build.

data "coder_parameter" "demo_name" {
  name         = "demo_name"
  display_name = "Demo name"
  description  = "Human label for the demo. DemoBuilder passes the managed deployment name."
  type         = "string"
  default      = "skeleton"
  mutable      = false
  order        = 1

  validation {
    regex = "^[a-z0-9][a-z0-9-]{0,30}$"
    error = "Lowercase letters, digits and hyphens; must start alphanumeric."
  }
}

data "coder_parameter" "coder_version" {
  name         = "coder_version"
  display_name = "Child Coder version"
  description  = "Tag of the ghcr.io/coder/coder image the demo host runs. Pinned per WS-9.1."
  type         = "string"
  default      = "v2.37.1"
  mutable      = true
  order        = 2
}

# DemoBuilder derives this per demo and logs in to the sandbox Gitea with it to
# create users and import repositories. It is a service credential, never shown
# to a presenter. Empty (a deployment created by hand) makes the host generate a
# random password that nobody holds, so the host still boots.
data "coder_parameter" "gitea_admin_password" {
  name         = "gitea_admin_password"
  display_name = "Gitea bootstrap administrator password"
  description  = "Set by DemoBuilder for its own seeding. Not a presenter credential; leave empty when creating a deployment by hand."
  type         = "string"
  default      = ""
  mutable      = false
  order        = 3
}

# A Coder template variable keeps the value of the previous template version
# unless the push sets it, so a changed default here does not take effect on
# its own. DemoBuilder's push-deployment-template.sh sets it explicitly.
variable "instance_type" {
  type        = string
  default     = "t3.xlarge"
  description = "Demo host size. t3.xlarge (4 vCPU, 16 GB) runs Coder, Postgres, Gitea, the pre-running workspace and template builds; t3.large had 2 vCPUs, which template imports and workspace image builds saturate."
}

# ---------------------------------------------------------------------------
# Tier 1 discovery (read only, by stable name)
# ---------------------------------------------------------------------------

data "aws_vpc" "sandbox" {
  filter {
    name   = "tag:Name"
    values = ["demobuilder-sandbox"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.sandbox.id]
  }
  filter {
    name   = "tag:Name"
    values = ["demobuilder-sandbox-public-*"]
  }
}

data "aws_security_group" "demo_host" {
  name   = "demobuilder-sandbox-demo-host"
  vpc_id = data.aws_vpc.sandbox.id
}

data "aws_lb" "sandbox" {
  name = "demobuilder-sandbox"
}

data "aws_lb_listener" "https" {
  load_balancer_arn = data.aws_lb.sandbox.arn
  port              = 443
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

# ---------------------------------------------------------------------------
# Namespace token
# ---------------------------------------------------------------------------
# Short, opaque, and stable across builds because Terraform state is carried
# forward by the managing deployment. Generating it here rather than accepting
# it as a parameter prevents collisions because no caller can pick a token that
# is already live. The presenter reads the resulting URL from the deployment
# page rather than predicting it.

resource "random_string" "ns" {
  length  = 4
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  sandbox_domain = "demos.cdrsandboxes.com"
  ns             = random_string.ns.result

  # Every hostname stays one label deep, so the single wildcard certificate
  # covers them. The "--" separator is what makes that true. DemoBuilder
  # derives the Gitea URL from the access URL by replacing "coder--" with
  # "gitea--", so keep the two prefixes in step.
  access_host = "coder--${local.ns}.${local.sandbox_domain}"
  apps_host   = "*--apps--${local.ns}.${local.sandbox_domain}"
  gitea_host  = "gitea--${local.ns}.${local.sandbox_domain}"

  access_url = "https://${local.access_host}"
  gitea_url  = "https://${local.gitea_host}"
}

# ---------------------------------------------------------------------------
# Host identity
# ---------------------------------------------------------------------------
# SSM only, deliberately. Per docs/ownership-contract.md the demo host has no
# reason to hold cloud credentials: AI runs on the managing instance, and the
# demo contains only Coder, git and zot. Because nothing in a container needs
# IMDS, the metadata hop limit stays at the default of 1, which closes GovCloud
# spike finding 9 (any workspace container could assume the host role) rather
# than mitigating it.

resource "aws_iam_role" "demo_host" {
  name = "demobuilder-demo-${local.ns}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Project = "demobuilder", Demo = local.ns }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.demo_host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "demo_host" {
  name = "demobuilder-demo-${local.ns}"
  role = aws_iam_role.demo_host.name
}

# ---------------------------------------------------------------------------
# The demo host
# ---------------------------------------------------------------------------

resource "aws_instance" "demo" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.public.ids[0]
  vpc_security_group_ids = [data.aws_security_group.demo_host.id]
  iam_instance_profile   = aws_iam_instance_profile.demo_host.name

  # Public IP for egress only. Inbound is impossible: the shared demo host
  # security group admits ports 7080 (Coder) and 3000 (Gitea) from the ALB
  # group and nothing else.
  associate_public_ip_address = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 60
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # EC2 caps user data at 16 KB; scripts/check-user-data.py enforces it.
  # The Gitea password is base64 encoded so no character in it can break the
  # script, and it is never traced.
  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    coder_version            = data.coder_parameter.coder_version.value
    access_url               = local.access_url
    apps_host                = local.apps_host
    vpc_cidr                 = data.aws_vpc.sandbox.cidr_block
    gitea_host               = local.gitea_host
    gitea_url                = local.gitea_url
    gitea_regex              = "^(https?://)?${replace(local.gitea_host, ".", "\\.")}(/.*)?$"
    gitea_admin_password_b64 = base64encode(data.coder_parameter.gitea_admin_password.value)
  })

  # Changing user_data must rebuild the host, not silently diverge from it.
  user_data_replace_on_change = true

  tags = {
    Name     = "demobuilder-demo-${local.ns}"
    Project  = "demobuilder"
    Demo     = local.ns
    DemoName = data.coder_parameter.demo_name.value
  }
}

# ---------------------------------------------------------------------------
# Ingress: two target groups (Coder, Gitea), one rule each on the shared
# listener
# ---------------------------------------------------------------------------
# Neither rule sets a priority. The AWS provider then takes the highest
# existing priority plus one and retries on PriorityInUse, so this demo's two
# rules, and rules from demos built at the same time, never collide. Host
# headers never overlap between rules, so their relative order is irrelevant.

resource "aws_lb_target_group" "demo" {
  name        = "dbz-${local.ns}"
  port        = 7080
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.sandbox.id
  target_type = "instance"

  health_check {
    path                = "/healthz"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 5
    matcher             = "200"
  }

  tags = { Project = "demobuilder", Demo = local.ns }
}

resource "aws_lb_target_group_attachment" "demo" {
  target_group_arn = aws_lb_target_group.demo.arn
  target_id        = aws_instance.demo.id
  port             = 7080
}

# Both hostnames route to the same demo: the Coder access URL and every
# generated subdomain app under it. Apps started dynamically resolve without a
# routing change because the app pattern is already matched.
resource "aws_lb_listener_rule" "demo" {
  listener_arn = data.aws_lb_listener.https.arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.demo.arn
  }

  condition {
    host_header {
      values = [local.access_host, local.apps_host]
    }
  }

  tags = { Project = "demobuilder", Demo = local.ns }
}

# The sandbox Gitea. /api/healthz answers 200 only once Gitea can reach its
# database, which is also when the bootstrap starts creating its administrator.
resource "aws_lb_target_group" "gitea" {
  name        = "dbz-${local.ns}-git"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.sandbox.id
  target_type = "instance"

  health_check {
    path                = "/api/healthz"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 5
    matcher             = "200"
  }

  tags = { Project = "demobuilder", Demo = local.ns }
}

resource "aws_lb_target_group_attachment" "gitea" {
  target_group_arn = aws_lb_target_group.gitea.arn
  target_id        = aws_instance.demo.id
  port             = 3000
}

resource "aws_lb_listener_rule" "gitea" {
  listener_arn = data.aws_lb_listener.https.arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gitea.arn
  }

  condition {
    host_header {
      values = [local.gitea_host]
    }
  }

  tags = { Project = "demobuilder", Demo = local.ns }
}

# ---------------------------------------------------------------------------
# Managed deployment metadata contract
# ---------------------------------------------------------------------------
# The managing instance reads access_url from here after a start build and
# begins health monitoring. It is also inert when the template is driven
# directly, so the same template body works in both cases.
#
# monitor_token is deliberately not exported yet. Automatic bootstrap mints its
# own tokens when the child has no first user, which is the path this template
# leaves open by not seeding one.

# The managing instance scans a completed start build's resources for well-known
# coder_metadata item keys. Terraform outputs are NOT read: without this resource
# the deployment builds fine but its access_url stays empty and health monitoring
# never starts.
resource "coder_metadata" "deployment" {
  resource_id = aws_instance.demo.id

  item {
    key   = "access_url"
    value = local.access_url
  }

  item {
    key   = "namespace"
    value = local.ns
  }

  # Informational: DemoBuilder derives the same URL from access_url by
  # replacing "coder--" with "gitea--" rather than reading this item.
  item {
    key   = "gitea_url"
    value = local.gitea_url
  }
}

output "access_url" {
  value       = local.access_url
  description = "Convenience for local runs; the manager reads coder_metadata."
}

output "gitea_url" {
  value       = local.gitea_url
  description = "Sandbox Gitea. The access URL with coder-- replaced by gitea--."
}

output "apps_host_pattern" {
  value       = local.apps_host
  description = "Wildcard pattern for generated Coder app hostnames."
}

output "namespace_token" {
  value       = local.ns
  description = "Short opaque token identifying this demo."
}

output "instance_id" {
  value       = aws_instance.demo.id
  description = "For SSM access during development."
}
