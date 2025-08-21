# Security Policy

## Reporting Security Issues

If you find a security vulnerability in this demo repository, please report it by:

1. Opening a [GitHub Security Advisory](https://github.com/Smana/cloud-native-ref/security/advisories/new)
2. Or emailing the maintainer directly

Please do not create public issues for security vulnerabilities.

## Security Considerations

This is a **demonstration repository** for learning cloud-native technologies. Before using in production:

### Infrastructure Security

- Change all default passwords and secrets
- Review IAM permissions and apply least privilege
- Enable AWS CloudTrail and monitoring
- Configure proper backup and disaster recovery

### Kubernetes Security

- Review network policies and RBAC configurations
- Enable Pod Security Standards
- Scan container images for vulnerabilities
- Keep all components updated

### OpenBao/Secrets Management

- Generate new certificates and keys
- Implement proper secret rotation
- Review access policies
- Enable audit logging

## Known Demo Limitations

- Uses development-grade certificates
- Contains example configurations with placeholder values
- May use elevated permissions for demonstration purposes
- Not hardened for production workloads

## Security Tools Included

- Trivy vulnerability scanning
- Checkov infrastructure analysis
- Pre-commit hooks for secret detection
- Kubernetes manifest validation

## Supported Versions

Only the latest version of this demo is maintained. For production use, implement proper versioning and security update processes.
