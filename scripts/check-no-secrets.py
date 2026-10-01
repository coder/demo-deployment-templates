#!/usr/bin/env python3
"""Fail if any tracked file looks like it holds a credential.

This repository is public. Credentials belong in DemoBuilder's secret store;
seed files name a credential slot instead (see demo-host/seed/ai-gateway.yaml).

    ./scripts/check-no-secrets.py
"""

import re
import subprocess
import sys

PATTERNS = {
    "AWS access key ID": re.compile(r"\b(AKIA|ASIA)[0-9A-Z]{16}\b"),
    "Bedrock API key": re.compile(r"\bABSK[A-Za-z0-9+/=]{20,}"),
    "private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "AWS account ID in an ARN": re.compile(r"arn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:\d{12}:"),
    "Coder session token": re.compile(r"\b[A-Za-z0-9]{10}-[A-Za-z0-9]{22}\b"),
    "literal secret value": re.compile(
        r"""(?ix)\b(password|secret|api_?key|access_?key|token)\b\s*[:=]\s*["']?[A-Za-z0-9+/=_.-]{8,}"""
    ),
}

# Provider lock files are hashes, not secrets.
SKIP = (".terraform.lock.hcl",)


def main() -> int:
    files = subprocess.run(["git", "ls-files"], check=True, capture_output=True, text=True).stdout.split()
    findings = []
    for path in files:
        if path.endswith(SKIP):
            continue
        try:
            text = open(path, encoding="utf-8").read()
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            for name, pattern in PATTERNS.items():
                if pattern.search(line):
                    findings.append(f"{path}:{number}: looks like a {name}")
    for finding in findings:
        print(finding)
    if findings:
        print("\nThis repository is public. Move the value to DemoBuilder's secret store.")
        return 1
    print("no credentials found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
