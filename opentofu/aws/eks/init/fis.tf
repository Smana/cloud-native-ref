# Runbook 10 Step 7 (agent-factory): one Spot interruption under a live agent run tells
# whether the kubelet's graceful shutdown completes on aws-0. The role and the template can
# only reach an instance the tester has tagged, so neither can interrupt a node by accident.
locals {
  fis_target_tag = "agents.ogenki.io/fis-target"
}

resource "aws_iam_role" "fis_agent_run_disruption" {
  name = "fis-agent-run-disruption"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "fis.amazonaws.com" }
        Action    = "sts:AssumeRole"
        # Confused-deputy guard: only this account's FIS experiments may assume the role.
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.this.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:aws:fis:${var.region}:${data.aws_caller_identity.this.account_id}:experiment/*" }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "fis_agent_run_disruption" {
  name = "spot-interruptions"
  role = aws_iam_role.fis_agent_run_disruption.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ec2:SendSpotInstanceInterruptions"
        Resource = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.this.account_id}:instance/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/${local.fis_target_tag}" = "true" }
        }
      },
      {
        # FIS resolves the target's tag selector with DescribeInstances, which has no resource-level scope.
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      }
    ]
  })
}

resource "aws_fis_experiment_template" "agent_run_disruption" {
  description = "agent-run disruption: Spot-interrupt the instance tagged ${local.fis_target_tag}=true"
  role_arn    = aws_iam_role.fis_agent_run_disruption.arn

  target {
    name           = "node"
    resource_type  = "aws:ec2:spot-instance"
    selection_mode = "ALL"

    resource_tag {
      key   = local.fis_target_tag
      value = "true"
    }

    filter {
      path   = "State.Name"
      values = ["running"]
    }
  }

  action {
    name      = "interrupt"
    action_id = "aws:ec2:send-spot-instance-interruptions"

    # EC2's real Spot notice, and the shortest FIS accepts.
    parameter {
      key   = "durationBeforeInterruption"
      value = "PT2M"
    }

    target {
      key   = "SpotInstances"
      value = "node"
    }
  }

  # A single hand-started interruption: there is no alarm worth aborting it on.
  stop_condition {
    source = "none"
  }

  tags = merge(var.tags, { Name = "agent-run-disruption" })
}

output "fis_agent_run_disruption_template_id" {
  description = "FIS experiment template for runbook 10 Step 7 (aws-0 Spot interruption)"
  value       = aws_fis_experiment_template.agent_run_disruption.id
}
