# Vector VRL Tests

Automated testing framework for Vector VRL (Vector Remap Language) transformations. This ensures VRL code is validated locally before deployment to the cluster via GitOps.

## Overview

The VRL tests validate the Vector transformations used to parse CloudNativePG auto_explain logs and extract query execution plans for correlation with pg_stat_statements metrics.

## Files

- **`cnpg-auto-explain.vrl`**: VRL transformation for parsing CNPG auto_explain logs
- **`test-samples.json`**: Test cases with input/expected output
- **`../validate-vector-vrl.sh`**: Validation script (run locally or in CI)

## Quick Start

### Prerequisites

- Docker (for running Vector VRL CLI)
- jq (for JSON processing)

### Run Validation

```bash
# From repository root
./scripts/validate-vector-vrl.sh
```

Expected output:
```
╔════════════════════════════════════════════════════════════════╗
║  Vector VRL Configuration Validation                          ║
╚════════════════════════════════════════════════════════════════╝

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Testing: CNPG auto_explain VRL transformation
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[1/3] Validating VRL syntax...
   ✅ VRL syntax is valid

[2/3] Running test cases...
   Testing: seq_scan_with_duration - Sequential scan query with all fields
   ✅ seq_scan_with_duration passed
   Testing: index_scan_no_duration - Index scan without duration field
   ✅ index_scan_no_duration passed
   Testing: aggregate_query - Aggregate query with GROUP BY
   ✅ aggregate_query passed
   Testing: join_query - Complex join query
   ✅ join_query passed

[3/3] Validating output schema...
   ✓ Field 'query_id' present
   ✓ Field 'cluster_name' present
   ✓ Field 'namespace' present
   ✓ Field 'pod_name' present
   ✓ Field 'plan' present
   ✓ Field 'query_text' present
   ✅ Output schema is valid

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Test Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Total tests: 4
  Passed: 4

✅ All VRL validations passed!
```

## Development Workflow

### 1. Modify VRL Code

Edit `cnpg-auto-explain.vrl` with your changes.

### 2. Add Test Cases

Add test cases to `test-samples.json`:

```json
{
  "test_cases": [
    {
      "name": "my_test_case",
      "description": "Description of what this tests",
      "input": {
        "message": "2024-01-09 10:30:45.123 UTC [12345] app@app LOG: duration: 123.45 ms  plan: {...}",
        "kubernetes": {
          "pod_labels": {
            "cnpg.io/cluster": "test-cluster"
          },
          "namespace_name": "apps",
          "pod_name": "test-cluster-1",
          "container_name": "postgres"
        }
      },
      "expected": {
        "query_id": "123456789",
        "cluster_name": "test-cluster",
        "namespace": "apps",
        "database": "app",
        "user": "app"
      }
    }
  ]
}
```

### 3. Run Validation

```bash
./scripts/validate-vector-vrl.sh
```

### 4. Debug Failures

If tests fail, manually test with Docker:

```bash
# Test with specific input
echo '{"message": "...", "kubernetes": {...}}' | \
  docker run --rm -i -v /path/to/vrl:/vrl timberio/vector:latest-alpine \
  vrl --program /vrl/cnpg-auto-explain.vrl --print-object
```

### 5. Update HelmRelease

Once validation passes, update `observability/base/victoria-logs/helmrelease-vlsingle.yaml` with the validated VRL code.

### 6. Commit

```bash
git add scripts/vector-vrl-tests/ observability/base/victoria-logs/
git commit -m "feat(vector): improve CNPG log parsing"
git push
```

## Test Cases

### seq_scan_with_duration
Tests parsing of sequential scan queries with full timing information.

**Input**: Auto explain log with duration, planning time, execution time
**Validates**:
- Query ID extraction
- Duration parsing
- Planning/execution time extraction
- Plan JSON parsing
- Database/user extraction from log prefix

### index_scan_no_duration
Tests parsing when duration field is missing from log message.

**Input**: Auto explain log without explicit duration field
**Validates**:
- Graceful handling of missing duration
- Query ID still extracted
- Planning/execution times still captured

### aggregate_query
Tests complex aggregate queries with GROUP BY.

**Input**: HashAggregate plan with nested operations
**Validates**:
- Complex plan structure parsing
- Nested plan nodes
- Aggregate operation metadata

### join_query
Tests multi-table join queries.

**Input**: Hash Join plan with multiple tables
**Validates**:
- Join operation parsing
- Complex query text
- Multiple table references

## VRL Syntax Rules

### Critical Rules (Common Errors)

1. **String matching**: Use `contains()` not `includes()`
   ```vrl
   # ✅ Correct
   if contains(string!(.message), "plan:") { ... }

   # ❌ Wrong
   if includes(string!(.message), "plan:") { ... }
   ```

2. **Fallible operations**: Must use `!` suffix or tuple assignment
   ```vrl
   # ✅ Correct
   json_string = strip_whitespace!(string!(parts[1]))

   # ✅ Also correct (with error handling)
   val, err = get(parsed_plan, ["Query Identifier"])
   if err == null { ... }

   # ❌ Wrong
   json_string = strip_whitespace(string!(parts[1]))
   ```

3. **Null vs Error coalescing**:
   ```vrl
   # ✅ Null coalescing (for paths)
   .cluster_name = .kubernetes.pod_labels."cnpg.io/cluster" || "unknown"

   # ✅ Error coalescing (for fallible functions)
   .query_text = get!(parsed_plan, ["Query Text"]) || ""

   # ❌ Wrong (get!() aborts on error, ?? never resolves)
   .query_text = get!(parsed_plan, ["Query Text"]) ?? ""
   ```

4. **Field names with spaces**: Always use `get()` or `get!()`
   ```vrl
   # ✅ Correct
   .query_text = get!(parsed_plan, ["Query Text"])

   # ❌ Wrong
   .query_text = parsed_plan["Query Text"]
   ```

## Integration with GitOps

### Pre-Commit Hook

Add to `.pre-commit-config.yaml`:

```yaml
- repo: local
  hooks:
    - id: validate-vector-vrl
      name: Validate Vector VRL
      entry: ./scripts/validate-vector-vrl.sh
      language: script
      files: '^(scripts/vector-vrl-tests/.*|observability/base/victoria-logs/helmrelease-vlsingle\.yaml)$'
      pass_filenames: false
```

### CI/CD Pipeline

Add to GitHub Actions or GitLab CI:

```yaml
validate-vrl:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - name: Validate Vector VRL
      run: ./scripts/validate-vector-vrl.sh
```

## Troubleshooting

### Docker permission denied
```bash
# Add user to docker group
sudo usermod -aG docker $USER
newgrp docker
```

### jq not found
```bash
# Arch Linux
sudo pacman -S jq

# Debian/Ubuntu
sudo apt-get install jq

# macOS
brew install jq
```

### VRL syntax error
Check the error output carefully. Common issues:
- Missing `!` on fallible operations
- Wrong coalescing operator (`??` vs `||`)
- Field access syntax for names with spaces

## References

- [Vector VRL Documentation](https://vector.dev/docs/reference/vrl/)
- [VRL Functions Reference](https://vector.dev/docs/reference/vrl/functions/)
- [VRL Type System](https://vector.dev/docs/reference/vrl/type_system/)
- [CloudNativePG Auto Explain](https://cloudnative-pg.io/documentation/current/monitoring/#auto_explain)
