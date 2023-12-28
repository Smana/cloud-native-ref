resource "aws_iam_instance_profile" "this" {
  name = local.name
  role = aws_iam_role.this.name
  tags = var.tags
}

resource "aws_iam_role" "this" {
  name = local.name
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Effect = "Allow",
        Sid    = ""
      }
    ]
  })
}

# enable AWS Systems Manager service core functionality
resource "aws_iam_role_policy_attachment" "ssm" {
  count      = var.enable_ssm ? 1 : 0
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
