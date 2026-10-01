# demo-deployment-templates

Coder deployment templates that [DemoBuilder](https://github.com/coder/demobuilder) publishes to its fleet manager. Each managed demo is built from one of these.

| Template | What it creates |
|---|---|
| [`demo-host`](demo-host/) | one EC2 demo host running Coder and Gitea, with its target groups and listener rules on the shared load balancer |

## Changing a template

1. Open a pull request. CI renders and lints user data and runs `terraform validate`.
2. After merge, a DemoBuilder template admin publishes the merged commit. A version is always published from an exact commit SHA, never a branch, and the manager template version records that SHA in its message.
3. Existing demos keep the version they were built with until they are rebuilt.

There is no in-app editor; this repository is the source of truth.

## Rules

- This repository is public. Never commit credentials. Passwords and tokens are template parameters or AWS Secrets Manager values.
- Never add a Terraform backend. The manager stores each demo's state in its deployment record.
- User data must stay under EC2's 16 KB limit. `scripts/check-user-data.py` enforces it.
