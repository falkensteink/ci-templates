#!/usr/bin/env python3
"""Lint docker-compose files against FRAMEWORKS.md §3.

Rules (see c:\\falkensteink\\FRAMEWORKS.md §3 + the 2026-04-24 ModMaestro
compose-compliance audit for grounding):

  R001 HIGH  restart policy must not be `always` or `unless-stopped`
             (post-2026-04-23 Toshi boot-loop incident — FRAMEWORKS.md §3
             line 273). Allowed: `on-failure[:N]`, `no`, or unset.
  R002 HIGH  a service that is depended-on with `condition: service_healthy`
             must have a healthcheck. Without it, the `depends_on` is a
             silent no-op that will never gate startup correctly.
  R002 MED   a service with its own image/build but no healthcheck and no
             exemption reason. Might be intentional (sidecars, one-shot
             migrate containers) — warning, not block.
  R003 HIGH  a cloudflared service must use `depends_on: { <app>:
             { condition: service_healthy } }`, not a plain list. Otherwise
             the tunnel starts forwarding traffic before the app is ready.
  R004 LOW   healthcheck is present but has no `start_period`. Containers
             that take more than a few seconds to boot can flap unhealthy
             before they're actually up.
  R005 INFO  service looks like a heavy runner (name/image/command hints
             at embedding, reindex, ML inference, TTS, transcription,
             video/audio, indexer work) but has no `cpus:` + `memory:`
             caps. These caused the 2026-04-23 Toshi crash — FRAMEWORKS.md
             §3 line 271 mandates caps on heavy runners.

Exit codes:
  0  no HIGH findings
  1  one or more HIGH findings
  2  failed to parse a file

Usage:
  compose-lint.py docker-compose.prod.yml [docker-compose.yml ...]
  compose-lint.py                           # lints ./docker-compose*.yml

Override files (no `image`/`build` on a service) have relaxed rules: a
service block that only supplies deltas isn't required to re-declare
restart/healthcheck/etc — those inherit from the base at merge time.
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    print("::error::PyYAML not installed. Run: pip install pyyaml", file=sys.stderr)
    sys.exit(2)


class _ComposeLoader(yaml.SafeLoader):
    """SafeLoader that silently unwraps compose-specific custom tags.

    Compose v2.24+ supports `!override`, `!reset` on list/scalar fields
    (used in Kyle-Rag's docker-compose.work.yml override file, for
    example). SafeLoader treats these as errors. Here we register a
    catch-all constructor that returns the underlying node value so
    parsing succeeds — the lint doesn't care about override vs replace
    semantics, only about the resulting content.
    """


def _pass_through(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node, deep=True)
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node, deep=True)
    return None


_ComposeLoader.add_multi_constructor("!", _pass_through)
_ComposeLoader.add_multi_constructor("tag:yaml.org,2002:", _pass_through)


HEAVY_RUNNER_HINTS = (
    "worker", "embed", "reindex", "piper", "tts",
    "pgvector", "indexer", "generator", "ollama",
    "transcrib", "synthes", "audiobook",
)


def is_cloudflared(svc: dict) -> bool:
    image = str(svc.get("image", "")).lower()
    return "cloudflare/cloudflared" in image


def is_override_block(svc: dict) -> bool:
    """Service declared without image+build is probably an override."""
    return "image" not in svc and "build" not in svc


def is_one_shot(svc: dict) -> bool:
    """Restart: `no` — classic one-shot (migrate, init)."""
    restart = str(svc.get("restart", "")).strip('"')
    return restart == "no"


def heavy_runner_score(sname: str, svc: dict) -> list[str]:
    """Return list of hint strings that matched (empty if not heavy)."""
    blob = " ".join([
        sname,
        str(svc.get("image", "")),
        str(svc.get("command", "")),
        str(svc.get("entrypoint", "")),
    ]).lower()
    return [h for h in HEAVY_RUNNER_HINTS if h in blob]


def has_resource_caps(svc: dict) -> tuple[bool, bool]:
    """Return (has_cpu_cap, has_mem_cap) across compose v2/v3 syntaxes."""
    deploy_limits = svc.get("deploy", {}).get("resources", {}).get("limits", {}) or {}
    has_cpu = "cpus" in deploy_limits or "cpus" in svc
    has_mem = "memory" in deploy_limits or "mem_limit" in svc
    return has_cpu, has_mem


def annotate(level: str, file: str, rule: str, severity: str, service: str, msg: str) -> None:
    """Emit a GitHub Actions annotation."""
    print(f"::{level} file={file}::[{rule} / {severity}] {service}: {msg}")


def lint_file(path: Path) -> tuple[list[dict], list[dict]]:
    """Return (findings, errors). HIGH findings cause non-zero exit."""
    findings: list[dict] = []
    errors: list[dict] = []

    try:
        data = yaml.load(path.read_text(encoding="utf-8"), Loader=_ComposeLoader)
    except Exception as e:
        errors.append({"file": str(path), "msg": f"YAML parse error: {e}"})
        return findings, errors

    if not isinstance(data, dict) or "services" not in data:
        # Might be a top-level override with no services; legal but unlikely.
        return findings, errors

    services: dict[str, dict] = data.get("services") or {}

    # Pre-compute reverse-dependency map for R002 HIGH escalation.
    depended_on_healthy: dict[str, list[str]] = {}
    depended_on_plain: dict[str, list[str]] = {}
    for sname, svc in services.items():
        if not isinstance(svc, dict):
            continue
        deps = svc.get("depends_on")
        if isinstance(deps, list):
            for target in deps:
                depended_on_plain.setdefault(str(target), []).append(sname)
        elif isinstance(deps, dict):
            for target, cfg in deps.items():
                cfg = cfg or {}
                if isinstance(cfg, dict) and cfg.get("condition") == "service_healthy":
                    depended_on_healthy.setdefault(str(target), []).append(sname)
                else:
                    depended_on_plain.setdefault(str(target), []).append(sname)

    for sname, svc in services.items():
        if not isinstance(svc, dict):
            continue

        override = is_override_block(svc)

        # R001: restart policy — applies whether override or not, if declared.
        restart = str(svc.get("restart", "")).strip('"')
        if restart in ("always", "unless-stopped"):
            findings.append({
                "file": str(path), "service": sname, "rule": "R001", "severity": "HIGH",
                "msg": f"restart: {restart} — FRAMEWORKS.md §3 mandates on-failure:3 "
                       f"(post-2026-04-23 Toshi boot-loop rule)",
            })

        # R003: cloudflared depends_on — always applies if cloudflared service.
        if is_cloudflared(svc):
            deps = svc.get("depends_on")
            if isinstance(deps, list) and deps:
                findings.append({
                    "file": str(path), "service": sname, "rule": "R003", "severity": "HIGH",
                    "msg": f"cloudflared depends_on is a plain list {deps} — must be map "
                           f"form with condition: service_healthy. Otherwise tunnel "
                           f"forwards traffic before app is ready.",
                })

        # Rules below are skipped for override blocks (they inherit).
        if override:
            continue

        # R002: healthcheck presence.
        has_healthcheck = bool(svc.get("healthcheck", {}).get("test"))
        exempt = is_cloudflared(svc) or is_one_shot(svc)

        if not has_healthcheck and not exempt:
            if sname in depended_on_healthy:
                # HIGH — service_healthy depends_on is silently broken
                findings.append({
                    "file": str(path), "service": sname, "rule": "R002", "severity": "HIGH",
                    "msg": f"no healthcheck, but {depended_on_healthy[sname]} depend on this "
                           f"with condition: service_healthy (silently broken).",
                })
            else:
                findings.append({
                    "file": str(path), "service": sname, "rule": "R002", "severity": "MED",
                    "msg": "no healthcheck. Consider adding one per FRAMEWORKS.md §3 "
                           "(urllib HTTP, socket TCP, or Node http.get pattern).",
                })

        # R004: healthcheck start_period.
        hc = svc.get("healthcheck") or {}
        if hc.get("test") and "start_period" not in hc:
            findings.append({
                "file": str(path), "service": sname, "rule": "R004", "severity": "LOW",
                "msg": "healthcheck has no start_period; container may flap unhealthy "
                       "during cold start.",
            })

        # R005: heavy runner without caps.
        hints = heavy_runner_score(sname, svc)
        if hints:
            has_cpu, has_mem = has_resource_caps(svc)
            if not (has_cpu and has_mem):
                missing = []
                if not has_cpu:
                    missing.append("cpus")
                if not has_mem:
                    missing.append("memory")
                findings.append({
                    "file": str(path), "service": sname, "rule": "R005", "severity": "INFO",
                    "msg": f"looks like a heavy runner (hint(s): {', '.join(hints)}) but "
                           f"missing {', '.join(missing)} cap(s). FRAMEWORKS.md §3 line 271 "
                           f"+ 2026-04-23 Toshi crash — heavy runners must throttle.",
                })

    return findings, errors


SEVERITY_LEVEL = {
    "HIGH": "error",
    "MED": "warning",
    "LOW": "notice",
    "INFO": "notice",
}


def main(argv: list[str]) -> int:
    args = argv[1:]
    if args:
        files = [Path(a) for a in args]
    else:
        files = sorted(Path(".").glob("docker-compose*.yml"))
        if not files:
            print("::warning::no docker-compose*.yml files in cwd")
            return 0

    all_findings: list[dict] = []
    all_errors: list[dict] = []
    for f in files:
        if not f.exists():
            print(f"::error::{f}: not found", file=sys.stderr)
            return 2
        findings, errors = lint_file(f)
        all_findings.extend(findings)
        all_errors.extend(errors)

    for err in all_errors:
        print(f"::error file={err['file']}::{err['msg']}")

    # Stable ordering: by file, then by severity (HIGH first), then by rule
    sev_order = {"HIGH": 0, "MED": 1, "LOW": 2, "INFO": 3}
    all_findings.sort(key=lambda f: (f["file"], sev_order.get(f["severity"], 9), f["rule"]))

    for f in all_findings:
        level = SEVERITY_LEVEL.get(f["severity"], "notice")
        annotate(level, f["file"], f["rule"], f["severity"], f["service"], f["msg"])

    counts = {s: sum(1 for f in all_findings if f["severity"] == s) for s in ("HIGH", "MED", "LOW", "INFO")}
    summary = f"compose-lint: {counts['HIGH']} HIGH, {counts['MED']} MED, {counts['LOW']} LOW, {counts['INFO']} INFO"
    if all_errors:
        summary += f", {len(all_errors)} parse errors"
    print(f"\n{summary}")

    if all_errors:
        return 2
    if counts["HIGH"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
