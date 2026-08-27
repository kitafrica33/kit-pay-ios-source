"""Interpret Apple's provisioning-profile iCloud authorization allowlists."""

from __future__ import annotations


def authorizes_cloudkit(value: object) -> bool:
    """Return whether a profile value authorizes the CloudKit service."""
    if value == "*":
        return True
    return (
        isinstance(value, list)
        and bool(value)
        and all(isinstance(candidate, str) for candidate in value)
        and "CloudKit" in value
    )


def authorizes_production_icloud(value: object) -> bool:
    """Return whether a profile value authorizes the Production environment."""
    if value == "Production":
        return True
    if not isinstance(value, list) or not value:
        return False
    if not all(isinstance(candidate, str) for candidate in value):
        return False
    allowed_environments = {"Development", "Production"}
    return (
        "Production" in value
        and len(value) == len(set(value))
        and set(value).issubset(allowed_environments)
    )
