# Demo deployment template

## No remote backend

This directory is published as a Coder deployment template. It must not use a
shared remote backend.

The managing Coder instance stores the authoritative Terraform state in each
deployment record and carries that state between builds. A second backend would
create competing owners for the same demo host, target group, and listener rule,
with a risk of orphaning or double-deleting resources.

Do not apply it against an existing managed demo.

All resources in this template are Tier 3 deployment-owned resources. The
ownership contract in DemoBuilder (`docs/ownership-contract.md`) has the
complete boundary and teardown rules.

## What a demo host runs

One docker compose project on the host, started by `user-data.sh.tftpl`:

| Service | Image | Reached at |
|---|---|---|
| `database` | `postgres:16` | compose network only |
| `gitea` | `gitea/gitea:1.27.3-rootless`, SQLite in a named volume | `https://gitea--<ns>.demos.cdrsandboxes.com` (target group `dbz-<ns>-git`, port 3000) |
| `coder` | `ghcr.io/coder/coder:<coder_version>` | `https://coder--<ns>.demos.cdrsandboxes.com` and `*--apps--<ns>` (target group `dbz-<ns>`, port 7080) |

The rootless Gitea image is used because the standard image always starts
OpenSSH under s6. Gitea has SSH, registration, Actions and the update checker
disabled, and migrations limited to GitHub hosts.

Boot order is Postgres and Gitea, then the Gitea bootstrap, then Coder:

1. Create the Gitea administrator `gitea-admin` (`gitea-admin@cdrsandboxes.com`)
   with the Gitea CLI. Its password is the `gitea_admin_password` parameter,
   which DemoBuilder derives per demo and uses to seed Gitea. It is a service
   credential, not a presenter credential. When the parameter is empty, as for
   a deployment created by hand in the manager, the host generates a random
   password that nobody holds.
2. Create a confidential Gitea OAuth2 application `coder` owned by
   `gitea-admin`, with the redirect URI
   `https://coder--<ns>.demos.cdrsandboxes.com/external-auth/gitea/callback`.
3. Write Coder's external auth provider `gitea` (`CODER_EXTERNAL_AUTH_0_*`) to
   `/opt/coder/coder.env` (mode 0600) and start Coder. Browsers authorize on the
   public Gitea host; Coder exchanges and validates tokens at
   `http://gitea:3000` over the compose network. The provider regex matches the
   Gitea host, so Coder's Git credential helper answers for
   `git clone https://gitea--<ns>...` inside workspaces after the user links
   their account once.

Secrets are never traced into `/var/log/demobuilder-bootstrap.log`. The Gitea
administrator password is still visible to anyone who can read the
deployment's build parameters in the manager, its Terraform state, or the
instance user data.

The access URL and the Gitea URL share the namespace token. DemoBuilder derives
the Gitea URL by replacing `coder--` with `gitea--` in the access URL; the
`gitea_url` metadata item and output carry the same value.
