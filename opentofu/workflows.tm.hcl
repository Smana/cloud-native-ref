# Global variables that are used in all scripts
# Use your own values for these variables
globals {
  provisioner                      = "tofu"
  region                           = "eu-west-3"
  profile                          = ""
  eks_cluster_name                 = "mycluster-0"
  openbao_url                      = "https://bao.priv.cloud.ogenki.io:8200"
  root_token_secret_name           = "openbao/cloud-native-ref/tokens/root"
  root_ca_secret_name              = "certificates/priv.cloud.ogenki.io/root-ca"
  cert_manager_approle_secret_name = "openbao/cloud-native-ref/approles/cert-manager"
  cert_manager_approle             = "cert-manager"
}

script "init" {
  name        = "OpenTofu Init"
  description = "Download the required provider plugins and modules and set up the backend"

  job {
    commands = [
      [global.provisioner, "init", "-lock-timeout=5m"],
    ]
  }
}

script "preview" {
  name        = "OpenTofu Deployment Preview"
  description = "Create a preview of OpenTofu changes and synchronize it to Terramate Cloud"

  job {
    commands = [
      [global.provisioner, "validate"],
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "plan", "-out=out.tfplan", "-detailed-exitcode", "-lock=false", "-var-file=variables.tfvars", {
        sync_preview   = true
        tofu_plan_file = "out.tfplan"
      }],
    ]
  }
}

script "deploy" {
  name        = "Opentofu Deployment"
  description = "Run a full Opentofu deployment cycle and synchronize the result to Terramate Cloud"

  job {
    commands = [
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      [global.provisioner, "plan", "-out=out.tfplan", "-lock=false", "-var-file=variables.tfvars"],
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "apply", "-auto-approve", "-var-file=variables.tfvars",
        {
          sync_deployment = true
          tofu_plan_file  = "out.tfplan"
        }
      ],
    ]
  }
}

script "drift" "detect" {
  name        = "Opentofu Drift Check"
  description = "Detect drifts in Opentofu configuration and synchronize it to Terramate Cloud"

  job {
    commands = [
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "plan", "-out=out.tfplan", "-detailed-exitcode", "-lock=false", "-var-file=variables.tfvars", {
        sync_drift_status = true
        tofu_plan_file    = "out.tfplan"
      }],
    ]
  }
}

script "drift" "reconcile" {
  name        = "Opentofu Drift Reconciliation"
  description = "Reconcile drifts in all changed stacks"

  job {
    commands = [
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "apply", "-input=false", "-auto-approve", "-lock-timeout=5m", "-var-file=variables.tfvars", "drift.tfplan", {
        sync_deployment = true
        tofu_plan_file  = "drift.tfplan"
      }],

    ]
  }
}

script "opentofu" "render" {
  name        = "Opentofu Show Plan"
  description = "Render a Opentofu plan"

  job {
    commands = [
      ["echo", "Stack: `${terramate.stack.path.absolute}`"],
      ["echo", "```opentofu"],
      [global.provisioner, "show", "-no-color", "out.tfplan"],
      ["echo", "```"],
    ]
  }
}

script "openbao" "configure" {
  description = "Init OpenBao cluster and configure PKI"
  job {
    name        = "openbao-configure"
    description = "OpenBao configuration"
    commands = [
      # Initialize OpenBao cluster
      [
        "bash",
        "../../../scripts/openbao-config.sh",
        "init",
        "--url",
        global.openbao_url,
        "--root-token-secret-name",
        global.root_token_secret_name,
        "--region",
        global.region,
        "--profile",
        global.profile,
        "--skip-verify",
      ],
      # Module management: Configure OpenBao (SecretsEngine, Approles, PKI, etc.)
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      [global.provisioner, "plan", "-out=out.tfplan", "-lock=false", "-var-file=variables.tfvars"],
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "apply", "-auto-approve", "-var-file=variables.tfvars",
        {
          sync_deployment = true
          tofu_plan_file  = "out.tfplan"
        }
      ],
    ]
  }
}

script "eks" "destroy" {
  description = "Destroy the EKS cluster"
  job {
    name        = "eks-destroy"
    description = "Destroy the EKS cluster"
    commands = [
      [
        "bash",
        "../../scripts/eks-prepare-destroy.sh",
        "--cluster-name",
        global.eks_cluster_name,
        "--region",
        global.region,
        "--profile",
        global.profile,
      ],
      [
        global.provisioner, "destroy"
      ]
    ]
  }
}

script "destroy" {
  description = "Opentofu destroy"
  job {
    name        = "destroy"
    description = "Opentofu destroy"
    commands = [
      [
        global.provisioner, "destroy", "-var-file=variables.tfvars"
      ]
    ]
  }
}
