---
title: Get Started
weight: 10
description: Deploy the platform into your own cloud account in about thirty minutes.
lastVerified: 2026-08-20
---

The platform deploys in three sequential stages: the network, then the secrets
and PKI layer, then Kubernetes. Each is a separate OpenTofu stack orchestrated
by Terramate, and each must complete before the next begins.

Pick your cloud to begin. AWS is implemented and maintained; GCP is designed but
not yet built.
