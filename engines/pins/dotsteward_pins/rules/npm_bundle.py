"""``npm-bundle``: an npm package directory (package.json and a
lockfileVersion 3 package-lock.json, both primary and never written) and
the lock values that mirror it.

Fields:

    dir                     instance-relative directory (required)
    dependencies_at         lock path that mirrors package.json
                            "dependencies" as a whole
    overrides_at            lock path that mirrors package.json "overrides"
                            ({} when absent)
    mirrors                 object: dependency -> lock path of its pin
                            object, or { "at": <lock path>, "fields":
                            { <pin field>: <dotted path in the
                            package-lock node> } }; the pin carries
                            "version" and "integrity"
    security_overrides_at   lock path of an object: name -> pin of a
                            security override ("version", "integrity",
                            optional "override_scope" (the dependency whose
                            nested copy is meant; the version then comes
                            from overrides[<scope>][<name>]), "lock_path"
                            (package-lock key, default
                            node_modules/<name>), "official_tag")
    nix_hash_at             lock path of the bundle's SRI hash
    name, formats           (see rules/__init__.py)

Check: package-lock root dependencies equal package.json dependencies;
lockfileVersion is 3; each dependency's node has its version and a sha512
integrity; the mirrored maps equal package.json; every pin (mirror or
security override) has the package.json version, the node's version and
the node's integrity (and the declared extra fields); ``official_tag`` is
``v<version>``; the Nix hash is SRI.

Sync: writes the mirrored maps, the pins' version and integrity (and extra
fields) and official tags.
"""

from __future__ import annotations

import copy
from typing import Any, ClassVar

from ..checker import Checker
from ..lockfile import DeclarationError, LockPath, Scope, load_json, parse_path
from . import Context, FieldSpec, Rule, relative_file


def _mirrors(value: Any) -> list[tuple[str, LockPath, list[tuple[str, list[str]]]]]:
    if not isinstance(value, dict) or not value:
        raise DeclarationError(f"expected an object of dependency -> lock path, found {value!r}")
    result = []
    for dependency, spec in value.items():
        if isinstance(spec, str):
            result.append((dependency, parse_path(spec), []))
            continue
        if not isinstance(spec, dict) or set(spec) - {"at", "fields"} or "at" not in spec:
            raise DeclarationError(f"{dependency}: expected a lock path or {{ at, fields }}")
        fields = spec.get("fields", {})
        if not isinstance(fields, dict) or not all(isinstance(v, str) and v for v in fields.values()):
            raise DeclarationError(f"{dependency}: fields must map pin fields to package-lock paths")
        result.append((dependency, parse_path(spec["at"]), [(k, v.split(".")) for k, v in fields.items()]))
    return result


def _dig(node: Any, keys: list[str]) -> Any:
    for key in keys:
        if not isinstance(node, dict):
            return None
        node = node.get(key)
    return node


def _override_target(name: str, pin: dict[str, Any], overrides: dict[str, Any]) -> tuple[str, Any]:
    """The package-lock key and the package.json version of a security
    override; a scoped override targets the copy below its scope."""
    scope = pin.get("override_scope")
    if scope:
        scoped = overrides.get(scope, {})
        version = scoped.get(name) if isinstance(scoped, dict) else None
    else:
        version = overrides.get(name)
    return pin.get("lock_path", f"node_modules/{name}"), version


class NpmBundle(Rule):
    kind = "npm-bundle"
    SYNCS = True
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "dir": FieldSpec(relative_file, required=True),
        "dependencies_at": FieldSpec(parse_path),
        "overrides_at": FieldSpec(parse_path),
        "mirrors": FieldSpec(_mirrors, default=[]),
        "security_overrides_at": FieldSpec(parse_path),
        "nix_hash_at": FieldSpec(parse_path),
    }

    def _load(self, ctx: Context) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any], dict[str, Any]]:
        directory = ctx.instance.path(self.values["dir"])
        package = load_json(directory / "package.json")
        package_lock = load_json(directory / "package-lock.json")
        return package, package_lock, package["dependencies"], package.get("overrides", {})

    def _pins(self, ctx: Context, overrides: dict[str, Any], dependencies: dict[str, Any]):
        """(label, pin, lock key, version, extra fields, tagged) of every
        mirrored pin."""
        for dependency, at, fields in self.values["mirrors"]:
            path = ctx.locks.resolve(at)
            pin = ctx.locks.get(path)
            yield path.text(), pin, f"node_modules/{dependency}", dependencies[dependency], fields, False
        if self.values["security_overrides_at"] is not None:
            path = ctx.locks.resolve(self.values["security_overrides_at"])
            for name, pin in ctx.locks.entries(path):
                lock_key, version = _override_target(name, pin, overrides)
                yield f"{path.text()}.{name}", pin, lock_key, version, [], True

    def check_scope(self, ctx: Context, c: Checker, scope: Scope) -> None:
        locks = ctx.locks
        label = self.values["dir"]
        _, package_lock, dependencies, overrides = self._load(ctx)
        nodes = package_lock["packages"]
        lock_label = f"{label}/package-lock.json"
        c.eq(f"{lock_label} root dependencies", nodes[""].get("dependencies"), dependencies)
        for key, value in (("dependencies_at", dependencies), ("overrides_at", overrides)):
            if self.values[key] is not None:
                path = locks.resolve(self.values[key])
                c.eq(path.text(), locks.get_leaf(path), value)
        c.eq(f"{lock_label} lockfileVersion", package_lock.get("lockfileVersion"), 3)
        for dependency, version in dependencies.items():
            node = nodes.get(f"node_modules/{dependency}", {})
            c.eq(f"{lock_label} {dependency}.version", node.get("version"), version)
            c.fmt(f"{lock_label} {dependency}.integrity", "sha512", node.get("integrity"))
        for pin_label, pin, lock_key, version, fields, tagged in self._pins(ctx, overrides, dependencies):
            node = nodes.get(lock_key, {})
            c.eq(f"{pin_label}.version", pin.get("version"), version)
            c.eq(f"{pin_label}.version (package-lock)", node.get("version"), version)
            c.eq(f"{pin_label}.integrity (package-lock)", pin.get("integrity"), node.get("integrity"))
            for field, keys in fields:
                c.eq(f"{pin_label}.{field} (package-lock)", pin.get(field), _dig(node, keys))
            if tagged and "official_tag" in pin:
                c.eq(f"{pin_label}.official_tag", pin["official_tag"], f"v{pin.get('version')}")
        if self.values["nix_hash_at"] is not None:
            path = locks.resolve(self.values["nix_hash_at"])
            c.fmt(path.text(), "sri", locks.get_leaf(path))

    def sync_scope(self, ctx: Context, scope: Scope) -> None:
        locks = ctx.locks
        _, package_lock, dependencies, overrides = self._load(ctx)
        nodes = package_lock["packages"]
        if self.values["dependencies_at"] is not None:
            locks.set(locks.resolve(self.values["dependencies_at"]), copy.deepcopy(dependencies))
        if self.values["overrides_at"] is not None:
            locks.set(locks.resolve(self.values["overrides_at"]), copy.deepcopy(overrides))
        for _, pin, lock_key, version, fields, tagged in self._pins(ctx, overrides, dependencies):
            node = nodes[lock_key]
            pin["version"] = version
            pin["integrity"] = node["integrity"]
            for field, keys in fields:
                pin[field] = _dig(node, keys)
            if tagged and "official_tag" in pin:
                pin["official_tag"] = f"v{version}"
