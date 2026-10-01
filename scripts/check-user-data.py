#!/usr/bin/env python3
"""Lint every user-data template before Terraform ever renders one.

Written after a comment containing "$100" inside an unquoted heredoc aborted a
demo host's entire bootstrap. The shell read it as the positional parameter $1
followed by "00", `set -u` turned that into "unbound variable", and the only
visible symptom was a 502 from the load balancer roughly six minutes later. A
user-data bug costs a full instance rebuild to discover, so it is worth
catching here.

Four checks:

  1. The file renders. Every ${...} is either a known template variable or an
     escaped $${...} literal, so a typo cannot reach an instance.
  2. The rendered script parses (`bash -n`).
  3. No `$` followed by a digit, `@` or `*` survives into the rendered script
     unless it is inside a single-quoted heredoc. Those expand to positional
     parameters that a boot script never has.
  4. The rendered script fits EC2's 16 KB user-data limit, with headroom for
     real values being longer than the placeholders below. RunInstances
     rejects anything larger, so the build fails only after other resources
     exist.

    ./scripts/check-user-data.py
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Placeholder values, one per variable each template is given by its
# templatefile() call. A variable missing here is itself a finding: it means
# the template references something the caller may not pass.
KNOWN = {
    "demo-host/user-data.sh.tftpl": {
        "coder_version": "v2.37.1",
        "access_url": "https://coder--test.demos.cdrsandboxes.com",
        "apps_host": "*--apps--test.demos.cdrsandboxes.com",
        "vpc_cidr": "10.20.0.0/16",
        "gitea_host": "gitea--test.demos.cdrsandboxes.com",
        "gitea_url": "https://gitea--test.demos.cdrsandboxes.com",
        "gitea_regex": r"^(https?://)?gitea--test\.demos\.cdrsandboxes\.com(/.*)?$",
        # base64 of a DemoBuilder-shaped derived password (24 + "-Db1").
        "gitea_admin_password_b64": "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4LURiMQ==",
    },
}

VAR = re.compile(r"(?<!\$)\$\{([^}]*)\}")
POSITIONAL = re.compile(r"\$[0-9@*]")

# EC2 limits raw user data to 16 KB before base64. The margin covers real
# values (a longer version tag or CIDR) exceeding the placeholders.
USER_DATA_LIMIT = 16 * 1024
USER_DATA_MARGIN = 512


def render(text: str, values: dict) -> tuple[str, list[str]]:
    unknown: list[str] = []

    def sub(m: re.Match) -> str:
        name = m.group(1).strip()
        if name in values:
            return values[name]
        unknown.append(name)
        return m.group(0)

    out = VAR.sub(sub, text)
    # templatefile turns the $${...} escape into a literal ${...}.
    return out.replace("$${", "${"), unknown


def quoted_heredoc_ranges(lines: list[str]) -> list[tuple[int, int]]:
    """Line ranges inside <<'EOF' heredocs, where the shell expands nothing."""
    ranges, start, tag = [], None, None
    for i, line in enumerate(lines):
        if tag is None:
            m = re.search(r"<<-?'([A-Za-z_][A-Za-z0-9_]*)'", line)
            if m:
                tag, start = m.group(1), i
        elif line.strip() == tag:
            ranges.append((start, i))
            tag = None
    return ranges


def main() -> int:
    failures = 0
    for rel, values in KNOWN.items():
        path = ROOT / rel
        if not path.exists():
            print(f"MISSING  {rel}")
            failures += 1
            continue

        rendered, unknown = render(path.read_text(), values)
        if unknown:
            print(f"FAIL     {rel}: unknown template variables {sorted(set(unknown))}")
            failures += 1

        size = len(rendered.encode())
        if size > USER_DATA_LIMIT - USER_DATA_MARGIN:
            print(f"FAIL     {rel}: renders to {size} bytes; EC2 user data is "
                  f"limited to {USER_DATA_LIMIT} and this check keeps "
                  f"{USER_DATA_MARGIN} spare")
            failures += 1

        tmp = ROOT / ".rendered.sh"
        tmp.write_text(rendered)
        try:
            p = subprocess.run(["bash", "-n", str(tmp)], capture_output=True, text=True)
            if p.returncode != 0:
                print(f"FAIL     {rel}: bash syntax\n{p.stderr.strip()}")
                failures += 1
        finally:
            tmp.unlink(missing_ok=True)

        lines = rendered.splitlines()
        safe = quoted_heredoc_ranges(lines)
        for n, line in enumerate(lines):
            if any(a <= n <= b for a, b in safe):
                continue
            m = POSITIONAL.search(line)
            if m:
                print(f"FAIL     {rel}:{n + 1}: {m.group(0)!r} expands to a "
                      f"positional parameter a boot script does not have\n"
                      f"         {line.strip()[:100]}")
                failures += 1

        if not failures:
            print(f"ok       {rel}")

    print("FAILURES" if failures else "all user-data templates pass")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
