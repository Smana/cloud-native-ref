# Demo of a secured EKS cluster

⚠️ Work in progress in order to write new blog posts [here](https://blog.ogenki.io)

Based on [this repository](https://github.com/Smana/cilium-gateway-api)

## 🏗️ Crossplane configuration

## 🔑 Federated authentication using Pinniped

## 🗒️ Audit logs with Loki and Vector

## 🔗 VPN connection using Tailscale

## 👮 Runtime security with Falco

## ✔️ Policies with Kyverno

## :closed_lock_with_key: Secrets management with Vault and external-secrets operator

## 🌐 Network policies with Cilium

## 🕵️ CI

2 things are checked

* The terraform code quality, conformance and security using [pre-commit-terraform](https://github.com/antonbabenko/pre-commit-terraform).
* The kustomize and Kubernetes conformance using kubeconform and building the kustomize configuration.

In order to run the CI checks locally just run the following command

ℹ️ It requires [task](https://taskfile.dev/installation/) to be installed

```console
 task check
```

The same tasks are run in `Github Actions`.