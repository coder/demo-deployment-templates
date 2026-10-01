#!/usr/bin/env python3
"""Check every template's seed/ai-gateway.yaml before DemoBuilder reads it.

    ./scripts/check-seed.py
"""

import glob
import sys

import yaml

TYPES = {"bedrock", "openai"}
PROTOCOLS = {"invoke-model", "mantle"}
CREDENTIALS = {"bedrock": "bedrock_sigv4", "openai": "bedrock_bearer"}
EFFORTS = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]


def check(path: str) -> list[str]:
    doc = yaml.safe_load(open(path, encoding="utf-8"))
    errors = []
    if doc.get("version") != 1:
        errors.append("version must be 1")
    providers = {}
    for p in doc.get("providers", []):
        name = p.get("name", "?")
        if name in providers:
            errors.append(f"provider {name} is listed twice")
        providers[name] = p
        if p.get("type") not in TYPES:
            errors.append(f"provider {name}: type must be one of {sorted(TYPES)}")
        if not str(p.get("base_url", "")).startswith("https://"):
            errors.append(f"provider {name}: base_url must be https")
        if not p.get("region"):
            errors.append(f"provider {name}: region is required")
        if p.get("credential") != CREDENTIALS.get(p.get("type")):
            errors.append(f"provider {name}: credential must be {CREDENTIALS.get(p.get('type'))}")
        if p.get("type") == "bedrock":
            protocol = p.get("protocol")
            if protocol not in PROTOCOLS:
                errors.append(f"provider {name}: protocol must be one of {sorted(PROTOCOLS)}")
            if protocol == "invoke-model" and not (p.get("model") and p.get("small_fast_model")):
                errors.append(f"provider {name}: invoke-model needs model and small_fast_model")
            if protocol == "mantle" and (p.get("model") or p.get("small_fast_model")):
                errors.append(f"provider {name}: mantle forwards the requested model; drop model fields")
    ids, defaults = set(), 0
    for m in doc.get("models", []):
        mid = m.get("id", "?")
        if mid in ids:
            errors.append(f"model {mid} is listed twice")
        ids.add(mid)
        if m.get("provider") not in providers:
            errors.append(f"model {mid}: unknown provider {m.get('provider')}")
        if not m.get("display_name"):
            errors.append(f"model {mid}: display_name is required")
        agents = m.get("agents")
        if agents is not None:
            defaults += 1 if agents.get("default") else 0
            if not isinstance(agents.get("context_limit"), int) or agents["context_limit"] <= 0:
                errors.append(f"model {mid}: agents.context_limit must be a positive integer")
            effort = agents.get("reasoning_effort")
            if effort is not None:
                d, x = effort.get("default"), effort.get("max")
                if d not in EFFORTS or x not in EFFORTS or EFFORTS.index(d) > EFFORTS.index(x):
                    errors.append(f"model {mid}: reasoning_effort needs default <= max from {EFFORTS}")
            provider_type = providers.get(m.get("provider"), {}).get("type")
            if (agents.get("web_search") or agents.get("responses_api")) and provider_type != "openai":
                errors.append(f"model {mid}: web_search and responses_api need an openai provider")
            if agents.get("default") and not m.get("required"):
                errors.append(f"model {mid}: the default model must be required")
        for key, value in (m.get("price") or {}).items():
            if key not in {"input", "output", "cache_read", "cache_write"} or not isinstance(value, (int, float)) or value < 0:
                errors.append(f"model {mid}: bad price {key}={value}")
    if defaults != 1:
        errors.append(f"exactly one agents model must be the default, found {defaults}")
    return errors


def main() -> int:
    failed = False
    for path in sorted(glob.glob("*/seed/ai-gateway.yaml")):
        errors = check(path)
        for error in errors:
            print(f"{path}: {error}")
        failed |= bool(errors)
        if not errors:
            print(f"ok       {path}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
