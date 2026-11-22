#!/usr/bin/env python3
"""Fail the build if any CloudFormation template defines an inline IAM policy.

Onward's standard: permissions are only AWS managed policies or customer managed
AWS::IAM::ManagedPolicy resources attached through ManagedPolicyArns.

Flags:
  * AWS::IAM::Policy / RolePolicy / UserPolicy / GroupPolicy resources (all inline)
  * a `Policies` property on AWS::IAM::Role, AWS::IAM::User or AWS::IAM::Group

Usage: python scripts/check_no_inline_policies.py templates/*.yaml bootstrap/*.yaml
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

INLINE_TYPES = {
    "AWS::IAM::Policy",
    "AWS::IAM::RolePolicy",
    "AWS::IAM::UserPolicy",
    "AWS::IAM::GroupPolicy",
}
PRINCIPAL_TYPES = {"AWS::IAM::Role", "AWS::IAM::User", "AWS::IAM::Group"}


class CfnLoader(yaml.SafeLoader):
    """SafeLoader that understands CloudFormation short-form tags such as !Sub and !Ref."""


def _construct_cfn_tag(loader: CfnLoader, _suffix: str, node: yaml.Node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node, deep=True)
    return loader.construct_mapping(node, deep=True)


CfnLoader.add_multi_constructor("!", _construct_cfn_tag)


def find_violations(path: Path) -> list[str]:
    template = yaml.load(path.read_text(encoding="utf-8"), Loader=CfnLoader) or {}
    violations = []
    for logical_id, resource in (template.get("Resources") or {}).items():
        rtype = resource.get("Type", "")
        props = resource.get("Properties") or {}
        if rtype in INLINE_TYPES:
            violations.append(f"{path}: {logical_id} uses inline policy type {rtype}")
        if rtype in PRINCIPAL_TYPES and "Policies" in props:
            violations.append(f"{path}: {logical_id} ({rtype}) has an inline 'Policies' property")
    return violations


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: check_no_inline_policies.py TEMPLATE [TEMPLATE ...]", file=sys.stderr)
        return 2
    violations = [v for arg in argv for v in find_violations(Path(arg))]
    for v in violations:
        print(f"ERROR {v}")
    if violations:
        print(f"\n{len(violations)} inline policy violation(s). Use AWS::IAM::ManagedPolicy instead.")
        return 1
    print(f"OK: no inline IAM policies in {len(argv)} template(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
