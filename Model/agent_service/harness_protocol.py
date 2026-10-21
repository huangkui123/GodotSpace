from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Literal


HARNESS_TRACE_VERSION = 1

HarnessOutcome = Literal[
    "executed",
    "answered",
    "clarified",
    "abstained",
    "rejected",
]

HARNESS_OUTCOMES = frozenset(
    {
        "executed",
        "answered",
        "clarified",
        "abstained",
        "rejected",
    }
)


@dataclass(frozen=True, slots=True)
class HarnessStageTrace:
    """Common audit envelope for one bounded harness decision stage."""

    stage_type: str
    outcome: HarnessOutcome
    reason: str
    model_attempts: int = 0
    fallback_used: bool = False
    latency_ms: float | None = None
    details: dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not self.stage_type.strip():
            raise ValueError("stage_type must be a non-empty string")
        if self.outcome not in HARNESS_OUTCOMES:
            raise ValueError(f"unsupported harness outcome: {self.outcome!r}")
        if not self.reason.strip():
            raise ValueError("reason must be a non-empty string")
        if (
            not isinstance(self.model_attempts, int)
            or isinstance(self.model_attempts, bool)
            or self.model_attempts < 0
        ):
            raise ValueError("model_attempts must be a non-negative integer")
        if not isinstance(self.fallback_used, bool):
            raise ValueError("fallback_used must be a boolean")
        if self.latency_ms is not None and (
            isinstance(self.latency_ms, bool)
            or not isinstance(self.latency_ms, (int, float))
            or not math.isfinite(float(self.latency_ms))
            or self.latency_ms < 0
        ):
            raise ValueError("latency_ms must be a finite non-negative number or null")
        if not isinstance(self.details, dict):
            raise ValueError("details must be an object")
        object.__setattr__(self, "stage_type", self.stage_type.strip())
        object.__setattr__(self, "reason", self.reason.strip())
        object.__setattr__(self, "details", dict(self.details))

    def to_dict(self) -> dict[str, Any]:
        return {
            "type": self.stage_type,
            "outcome": self.outcome,
            "reason": self.reason,
            "model_attempts": self.model_attempts,
            "fallback_used": self.fallback_used,
            "latency_ms": (
                round(float(self.latency_ms), 1)
                if self.latency_ms is not None
                else None
            ),
            "details": dict(self.details),
        }


@dataclass(frozen=True, slots=True)
class HarnessTrace:
    """Versioned, ordered trace spanning every harness used by one request."""

    stages: tuple[HarnessStageTrace, ...] = ()
    version: int = HARNESS_TRACE_VERSION

    def __post_init__(self) -> None:
        if self.version != HARNESS_TRACE_VERSION:
            raise ValueError(f"unsupported harness trace version: {self.version}")
        if not isinstance(self.stages, tuple) or any(
            not isinstance(stage, HarnessStageTrace) for stage in self.stages
        ):
            raise ValueError("stages must be a tuple of HarnessStageTrace values")

    def append(self, stage: HarnessStageTrace) -> HarnessTrace:
        if not isinstance(stage, HarnessStageTrace):
            raise ValueError("stage must be a HarnessStageTrace")
        return HarnessTrace(stages=(*self.stages, stage), version=self.version)

    def to_dict(self) -> dict[str, Any]:
        return {
            "version": self.version,
            "stages": [stage.to_dict() for stage in self.stages],
        }
