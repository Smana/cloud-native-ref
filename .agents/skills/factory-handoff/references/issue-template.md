# Factory issue template

**Title:** `<area>: <what is wrong>`, for example `docs(agents): user guide links a removed runbook`.

**Body:**

```text
## What is wrong
<file>:<line>: <what it says or does now>

## What it should be
<the expected text or behaviour>

## Acceptance check
<one command or observation that proves it is fixed>

Fix it; change nothing else.
```

One defect per issue. Never paste secrets, tokens or customer data: the factory treats the
issue as untrusted input, and its agents read it in full.
