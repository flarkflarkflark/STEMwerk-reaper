"""Module descriptors for the Core installation contract.

A descriptor names a module and lists the components that must be present
and verified before the module counts as installed: runtime, FFmpeg, asset
and activation components (design section 3.1). Descriptors are plain data;
they do not locate, verify or change anything.

Asset pins are not repeated here: SHA-256 values come from ``model_assets``
and byte sizes from ``asset_acquisition``, the modules that already own them.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Mapping

from . import asset_acquisition, model_assets


DESCRIPTOR_VERSION = "1.0.0"

KIND_RUNTIME = "runtime"
KIND_FFMPEG = "ffmpeg"
KIND_ASSET = "asset"
KIND_ACTIVATION = "activation"
COMPONENT_KINDS = (KIND_RUNTIME, KIND_FFMPEG, KIND_ASSET, KIND_ACTIVATION)


@dataclass(frozen=True)
class AssetPin:
    """One pinned asset file: exact filename, byte size and SHA-256."""

    name: str
    size: int
    sha256: str

    def __post_init__(self) -> None:
        if (
            not isinstance(self.name, str)
            or not self.name
            or Path(self.name).name != self.name
            or self.name in {".", ".."}
            or "\\" in self.name
        ):
            raise ValueError("asset pin name must be a single safe filename")
        if not isinstance(self.size, int) or isinstance(self.size, bool) or self.size <= 0:
            raise ValueError(f"asset pin {self.name} needs a positive size")
        if (
            not isinstance(self.sha256, str)
            or len(self.sha256) != 64
            or any(char not in "0123456789abcdef" for char in self.sha256)
        ):
            raise ValueError(f"asset pin {self.name} needs a lowercase SHA-256")


@dataclass(frozen=True)
class ComponentDescriptor:
    """One required component of a module."""

    component_id: str
    kind: str
    description: str
    assets: tuple[AssetPin, ...] = ()

    def __post_init__(self) -> None:
        if not isinstance(self.component_id, str) or not self.component_id:
            raise ValueError("component id must be a non-empty string")
        if self.kind not in COMPONENT_KINDS:
            raise ValueError(f"component {self.component_id} has unknown kind {self.kind!r}")
        if not isinstance(self.assets, tuple):
            raise ValueError(f"component {self.component_id} assets must be a tuple")
        if self.kind == KIND_ASSET:
            if not self.assets:
                raise ValueError(f"asset component {self.component_id} has no pins")
            names = [pin.name for pin in self.assets]
            if len(names) != len(set(names)):
                raise ValueError(f"asset component {self.component_id} repeats a pin name")
        elif self.assets:
            raise ValueError(f"{self.kind} component {self.component_id} cannot carry asset pins")


@dataclass(frozen=True)
class ModuleDescriptor:
    """A module, its catalog names and its required components, in order."""

    module_id: str
    workflow_id: str
    engine_id: str
    display_name: str
    components: tuple[ComponentDescriptor, ...]

    def __post_init__(self) -> None:
        for field in ("module_id", "workflow_id", "engine_id", "display_name"):
            value = getattr(self, field)
            if not isinstance(value, str) or not value:
                raise ValueError(f"module descriptor {field} must be a non-empty string")
        if not isinstance(self.components, tuple) or not self.components:
            raise ValueError(f"module {self.module_id} has no components")
        ids = [component.component_id for component in self.components]
        if len(ids) != len(set(ids)):
            raise ValueError(f"module {self.module_id} repeats a component id")


def _drumsep_asset_pins() -> tuple[AssetPin, ...]:
    sizes = {
        model_assets.DIRECT_DKS_MODEL_FILENAME: asset_acquisition.CHECKPOINT_SIZE,
        model_assets.DIRECT_DKS_MODEL_YAML: asset_acquisition.CONFIG_SIZE,
    }
    return tuple(
        AssetPin(name=name, size=sizes[name], sha256=sha256)
        for name, sha256 in sorted(model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256.items())
    )


DIRECT_KIT = ModuleDescriptor(
    module_id="drum_kit",
    workflow_id="drum_kit_direct",
    engine_id="drumsep_mdx23c",
    display_name="STEMwerk DKS",
    components=(
        ComponentDescriptor(
            component_id="managed_python",
            kind=KIND_RUNTIME,
            description="Managed CPython interpreter published by the outer layer",
        ),
        ComponentDescriptor(
            component_id="module_venv",
            kind=KIND_RUNTIME,
            description="Direct Kit CPU module environment with the pinned wheel set",
        ),
        ComponentDescriptor(
            component_id="ffmpeg",
            kind=KIND_FFMPEG,
            description="STEMwerk's own pinned ffmpeg and ffprobe pair",
        ),
        ComponentDescriptor(
            component_id="drumsep_assets",
            kind=KIND_ASSET,
            description="DrumSep MDX23C checkpoint and config",
            assets=_drumsep_asset_pins(),
        ),
        ComponentDescriptor(
            component_id="reaper_activation",
            kind=KIND_ACTIVATION,
            description="STEMwerk actions registered in REAPER",
        ),
    ),
)

MODULE_DESCRIPTORS: Mapping[str, ModuleDescriptor] = MappingProxyType(
    {DIRECT_KIT.module_id: DIRECT_KIT}
)


def get_module_descriptor(module_id: str) -> ModuleDescriptor:
    """Return the descriptor for ``module_id``; ``ValueError`` if unknown."""

    try:
        return MODULE_DESCRIPTORS[module_id]
    except (KeyError, TypeError):
        raise ValueError(f"unknown module {module_id!r}") from None
