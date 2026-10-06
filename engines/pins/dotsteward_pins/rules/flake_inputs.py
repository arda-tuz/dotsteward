"""``flake-inputs`` (core, always on): ``flake_inputs`` of the versions lock
against the instance's ``flake.lock`` and ``flake.nix``.

Fields:

    excluded    root inputs left out of the comparison (core passes
                ``[pins] excluded_flake_inputs``, default ["dotsteward"])

Check:
- the root inputs of flake.lock (those that are nodes, not ``follows``)
  minus ``excluded`` equal the keys of ``flake_inputs``;
- per entry: ``reference`` appears quoted in flake.nix; ``revision`` is 40
  hex digits; ``nar_hash`` (when present) is SRI; ``version`` (when
  present) matches the reference tag ``/v<version>``; and against its
  flake.lock node (when there is one): the reference
  (``github:<owner>/<repo>/<ref or rev>`` of ``original``), ``revision``
  (``locked.rev``) and ``nar_hash`` (``locked.narHash``).

Sync: from the flake.lock node of each entry, ``reference`` (GitHub nodes),
``revision``, and where the keys exist ``nar_hash`` and ``version`` (from a
``v``-prefixed tag). flake.lock and flake.nix are never written.
"""

from __future__ import annotations

from typing import Any, ClassVar

from ..checker import Checker
from ..lockfile import DeclarationError, Scope, load_json, parse_path
from . import Context, FieldSpec, Rule

FLAKE_LOCK = "flake.lock"
FLAKE_NIX = "flake.nix"
_INPUTS = parse_path("flake_inputs")


def _excluded(value: Any) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise DeclarationError(f"expected a list of input names, found {value!r}")
    return list(value)


def root_nodes(flake_lock: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """The root inputs of a flake.lock that are nodes (not follows paths)."""
    nodes = flake_lock["nodes"]
    roots = {}
    for name, node in nodes[flake_lock["root"]]["inputs"].items():
        if isinstance(node, str):
            roots[name] = nodes[node]
    return roots


def reference_of(node: dict[str, Any]) -> str | None:
    """``github:<owner>/<repo>/<ref or rev>`` of a GitHub node, else None."""
    original = node.get("original", {})
    if original.get("type") != "github":
        return None
    ref = original.get("ref") or original.get("rev")
    return f"github:{original['owner']}/{original['repo']}/{ref}"


class FlakeInputs(Rule):
    kind = "flake-inputs"
    SYNCS = True
    FIELDS: ClassVar[dict[str, FieldSpec]] = {"excluded": FieldSpec(_excluded, default=[])}

    def _roots(self, ctx: Context) -> dict[str, dict[str, Any]]:
        roots = root_nodes(load_json(ctx.instance.path(FLAKE_LOCK)))
        for name in self.values["excluded"]:
            roots.pop(name, None)
        return roots

    def check_scope(self, ctx: Context, c: Checker, scope: Scope) -> None:
        pins = ctx.locks.get(_INPUTS)
        roots = self._roots(ctx)
        flake_text = ctx.instance.path(FLAKE_NIX).read_text(encoding="utf-8")
        c.eq("flake.lock root inputs", sorted(roots), sorted(pins))
        for name, pin in pins.items():
            label = f"flake_inputs.{name}"
            reference = pin["reference"]
            c.ok(f"{label}.reference", f'"{reference}"' in flake_text, f"{reference!r} not found in {FLAKE_NIX}")
            c.fmt(f"{label}.revision", "hex40", pin.get("revision"))
            if "nar_hash" in pin:
                c.fmt(f"{label}.nar_hash", "sri", pin["nar_hash"])
            if "version" in pin:
                suffix = f"/v{pin['version']}"
                c.ok(
                    f"{label}.version",
                    isinstance(reference, str) and reference.endswith(suffix),
                    f"reference {reference!r} does not end with {suffix!r}",
                )
            node = roots.get(name)
            if node is None:
                continue
            c.eq(f"{label}.reference ({FLAKE_LOCK})", reference_of(node), reference)
            c.eq(f"{label}.revision ({FLAKE_LOCK})", node["locked"].get("rev"), pin.get("revision"))
            if "nar_hash" in pin:
                c.eq(f"{label}.nar_hash ({FLAKE_LOCK})", node["locked"].get("narHash"), pin["nar_hash"])

    def sync_scope(self, ctx: Context, scope: Scope) -> None:
        pins = ctx.locks.get(_INPUTS)
        roots = self._roots(ctx)
        for name, pin in pins.items():
            node = roots[name]
            reference = reference_of(node)
            if reference:
                pin["reference"] = reference
            pin["revision"] = node["locked"]["rev"]
            if "nar_hash" in pin:
                pin["nar_hash"] = node["locked"]["narHash"]
            if "version" in pin and reference:
                tag = reference.rsplit("/", 1)[1]
                if tag.startswith("v"):
                    pin["version"] = tag[1:]
