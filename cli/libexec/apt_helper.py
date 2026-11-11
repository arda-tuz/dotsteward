"""The apt engine of `dotsteward upgrade`: it plans and applies in one depcache and refuses by named risk classes.

This file runs under the system's /usr/bin/python3 with python3-apt, not under the
python of the CLI, and as root when it changes something, so it holds to Python 3.10
syntax and the standard library (Ubuntu 22.04 has apt 2.4 and Python 3.10) and imports
nothing of the framework. dotsteward_cli.apt_plan calls it:

    /usr/bin/python3 -I apt_helper.py ACTION [--output FILE] < request.json

    plan      what the run would do: the shared target of kernel, module and driver,
              the changes of the depcache and what the refusal list says about them;
              it needs no privileges and changes nothing
    analysis  the upgradable packages outside the tracked set, read only
    policy    (root) under the lock of dpkg: the pin file, from what dpkg has, and the hook
              that keeps the pin file there whoever calls dpkg (the drop-in of unattended-upgrades
              is the system component apt-policy); the file of the constraints and holds
    recover   (root) `dpkg --configure -a` when dpkg was left half way
    commit    (root) the plan, under the lock of dpkg, and when nothing refuses it the
              same depcache applied
    files     the pin file and the file of the constraints and holds as policy would write
              them now (path and text; no text when no file belongs there), read only

The answer is one JSON document on standard output or in FILE. Exit status 0: the
action ran, whatever the plan says; 1: it could not, and the document holds `error`
with `code` and `message`; 2: a usage error.

The classes of the kernel and of the NVIDIA stack are gated: only the shared target
moves them, kernel, module meta package and driver as one unit, all or nothing, and
never past the phasing of any member. Everything is derived from the records of what
is installed; no version of a kernel or a driver is data of the framework. The pin file
in /etc/apt/preferences.d always tells what dpkg has, so that no other user of libapt
ever sees a target: a plan and a commit read their pin from a temporary directory, and a
hook of dpkg keeps the file right after every dpkg, also when a person calls it.

The version constraints and holds of the instance (`kept` of the request) bind what this engine
does, never the owner's own apt: no preferences file is written for them. In each depcache of a plan,
a commit and the analysis a package of a constrained or held component takes the newest version its
rules allow from the origins apt trusts as much as the version apt would take (so no prerelease of a
lower origin, no backport, nothing of an origin the owner turned off); with none it stays where it
is and the newer one waits. A package the owner took out of its rule, one another package needs in a
version outside the rule (a shared library: Depends, a versioned Provides, Breaks), a rule that is no
series or no version, firmware and the gated classes are never bound, and the answer says so.
"""

from __future__ import annotations

import datetime
import functools
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

try:
    import apt
    import apt.progress.base
    import apt.progress.text
    import apt_pkg
except ImportError:
    apt = None
    apt_pkg = None

SCHEMA_VERSION = 1
SCRATCH_PREFIX = "dotsteward-apt-pins-"
SCRATCH_MAX_AGE_SECONDS = 24 * 60 * 60
PIN_FILE = "60dotsteward"
PIN_PRIORITY = 990
# After every run of dpkg the pin file follows what dpkg has, also after `dpkg -i` by hand. A hook
# that fails costs dpkg nothing. The script is a copy in a place of root: it runs as root.
PIN_HOOK_FILE = "60dotsteward-pin"
PIN_SYNC_FILE = "usr/local/lib/dotsteward/pin-sync.py"
PIN_HEADER = "# Managed by dotsteward: gated classes stay as dpkg has them. Only `dotsteward upgrade` moves them."
# A series of a version constraint: an optional epoch, numbers, an optional .* (16, 16.*, 5:27, 1.140).
SERIES_RE = re.compile(r"(?:([0-9]+):)?([0-9]+(?:\.[0-9]+)*)(?:\.\*)?")
# What may follow a series inside it (16.4, 16-1, 16+dfsg, 16~rc1), and the Debian revision of a line.
SERIES_BOUNDARY = ".+~-"
LINE_BOUNDARY = "-"
VERSION_TEXT_RE = re.compile(r"[0-9A-Za-z.+~:-]+")
# The relations through which another package needs a version of a package.
NEEDS = ("Depends", "PreDepends")
EXCLUDES = ("Breaks", "Conflicts")
# An exact version constraint of an earlier release: that version alone.
EXACT_RE = re.compile(r"[0-9][0-9A-Za-z.+~:-]*")
PACKAGE_RE = re.compile(r"[a-z0-9][a-z0-9+.-]+")
# The Sources of the gated classes: what the pin holds. The other kernel packages
# (linux-signed-*, linux-hwe-*) carry the ABI in their names: only these pull them in. A rebuild
# of the same ABI (~24.04.1 to .2) moves under the pin: the module of that ABI still loads.
GATED_SOURCE = re.compile(
    r"^(?:linux-meta|linux-restricted-modules|linux-restricted-signatures|nvidia-graphics-drivers-)"
)
KERNEL_GLOBS = ("linux-meta*",)
NVIDIA_GLOBS = ("linux-restricted-modules*", "linux-restricted-signatures*", "nvidia-graphics-drivers-*")
NVIDIA_GLOB = f"src:{NVIDIA_GLOBS[-1]}:any"
ROLLBACK_DIR = "/var/cache/dotsteward/apt-rollback"
ROLLBACK_CLASSES = {"nvidia-driver", "nvidia-module"}
DEFAULT_LOCK_TIMEOUT = 300
ABI = r"\d+\.\d+\.\d+-\d+"
IMAGE_RE = re.compile(rf"^linux-image-(?:unsigned-)?({ABI})-([a-z0-9]+(?:-[a-z0-9]+)*)$")
# A package of one kernel ABI: linux-modules-7.0.0-42-generic, linux-hwe-7.0-headers-7.0.0-42.
ABI_PACKAGE_RE = re.compile(rf"^linux-(?:[a-z0-9.-]*-)?({ABI})(?:-[a-z0-9]+(?:-[a-z0-9]+)*)?$")
# Packages of one kernel flavour, the ones a new flavour brings along.
FLAVOUR_RE = re.compile(
    rf"^linux-(?:image|modules|modules-extra|headers)-(?:unsigned-)?{ABI}-([a-z0-9]+(?:-[a-z0-9]+)*)$"
)
DRIVER_RE = re.compile(r"^nvidia-driver-(\d+)(-server)?(-open)?$")
DKMS_RE = re.compile(r"^nvidia-dkms-")
BOOT_LOW_MIB = 200
# The refusals a person can lift with `--accept install:<package>`.
ACCEPTABLE = {"constrained-major", "kernel-flavour", "dkms"}
UBUNTU_DRIVERS_RE = re.compile(r"^driver\s*:\s*(nvidia-driver-\S+)\s+-\s+(.*)$")


class HelperError(Exception):
    """The action could not run; `code` names the reason for a report."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def vcmp(left, right):
    return apt_pkg.version_compare(left, right)


def newest_first(versions):
    return sorted(versions, key=functools.cmp_to_key(lambda a, b: vcmp(a.version, b.version)), reverse=True)


def deps(version):
    """The Pre-Depends and Depends of a version as (name, relation, version), or-groups flattened."""
    return [(dep.name, dep.relation, dep.version) for group in version.dependencies for dep in group.or_dependencies]


def series_of(version):
    """The series of a kernel: the first two numbers of the version of its meta package (7.0.0-42 is 7.0)."""
    match = re.match(r"(?:\d+:)?(\d+)\.(\d+)", version)
    return f"{match.group(1)}.{match.group(2)}" if match else ""


def series_key(series):
    return tuple(int(part) for part in series.split(".") if part)


def source_class(name, source):
    """The named class of a package, by its Source; None for every other package."""
    if source.startswith("nvidia-graphics-drivers-"):
        return "nvidia-driver"
    if source.startswith("linux-restricted-"):
        return "nvidia-module"
    if source.startswith("linux-meta"):
        return "kernel"
    if source.startswith("linux-firmware"):
        return "firmware"
    if (source == "linux" or source.startswith("linux-")) and ABI_PACKAGE_RE.match(name):
        return "kernel"
    return None


def split_epoch(version):
    """(epoch, the rest): the epoch is "0" when the version names none."""
    match = re.match(r"([0-9]+):(.*)", version)
    return (match.group(1), match.group(2)) if match else ("0", version)


def parse_series(constraint):
    """(epoch or None for any, the series) of a version constraint, None when it is no series."""
    match = SERIES_RE.fullmatch(str(constraint).strip())
    return (match.group(1), match.group(2)) if match else None


def parse_rule(constraint):
    """(epoch, literal, boundary) of a version constraint: a series, or one exact version (nothing may
    follow it, its epoch is its own); None when it is neither. A leading v of a tag is no part of it."""
    constraint = str(constraint).strip()
    if constraint[:1] == "v" and constraint[1:2].isdigit():
        constraint = constraint[1:]
    series = parse_series(constraint)
    if series is not None:
        return (series[0], series[1], SERIES_BOUNDARY)
    text = str(constraint).strip()
    if not EXACT_RE.fullmatch(text):
        return None
    epoch, rest = split_epoch(text)
    return (epoch, rest, "")


def in_line(version, epoch, literal, boundary):
    """Whether VERSION is LITERAL, or LITERAL and then a character of BOUNDARY, with EPOCH (None: any)."""
    found, rest = split_epoch(version)
    if epoch is not None and found != epoch:
        return False
    if not rest.startswith(literal):
        return False
    tail = rest[len(literal) :]
    return tail == "" or tail[0] in boundary


def in_constraint(constraint, version):
    rule = parse_rule(constraint)
    return rule is not None and in_line(version, *rule)


def one_line(text):
    return " ".join(str(text).split())


def gated_package(pkg):
    """A package of a gated class or firmware: the series rule and the kernel are its rules, never a
    constraint or a hold."""
    sources = {version.source_name for version in pkg.versions}
    classes = ("kernel", "nvidia-driver", "nvidia-module", "firmware")
    return any(source_class(pkg.shortname, source) in classes for source in sources)


def shared_with(cache, pkg, allowed, packages):
    """A package outside the component (not in PACKAGES) that needs a version of PKG the rules do not
    allow, or excludes every one they allow: a limit would break it (another major the owner
    installs). Through the package itself and through each name its allowed versions provide. None
    when there is none."""
    inside = [version for version in pkg._pkg.version_list if allowed(version.ver_str)]
    names = {pkg.name: [(version.ver_str, version.ver_str) for version in inside]}
    for version in inside:
        for name, provided, _ in version.provides_list:
            names.setdefault(name, []).append((provided, version.ver_str))
    for name, offers in names.items():
        try:
            target = pkg._pkg if name == pkg.name else cache._cache[name]
        except KeyError:
            continue
        for dependency in target.rev_depends_list:
            parent = dependency.parent_pkg.name
            if parent in packages or parent == pkg.name:
                continue
            kind = dependency.dep_type_untranslated
            meets = [
                not dependency.target_ver
                or (bool(offer) and apt_pkg.check_dep(offer, dependency.comp_type, dependency.target_ver))
                for offer, _ in offers
            ]
            if kind in NEEDS and dependency.target_ver and not any(meets):
                return parent
            if kind in EXCLUDES and name == pkg.name and offers and all(meets):
                return parent
    return None


def _rule_note(code, rule, message, **fields):
    return report_item(
        code,
        component=one_line(rule.get("component") or ""),
        version=one_line(rule.get("version")),
        message=message,
        **fields,
    )


def read_rules(rules):
    """The usable rules of the request by package, and a note for each that is not:
    ({name: [{kind, component, version, reason, allows}]}, items). A constraint allows its series or
    its one version, a hold what is below it."""
    by_package = {}
    items = []
    for rule in rules:
        kind = rule.get("kind")
        version = str(rule.get("version") or "")
        component = one_line(rule.get("component") or "")
        if kind == "constraint":
            parsed = parse_rule(version)
            if parsed is None:
                items.append(
                    _rule_note(
                        "constraint-invalid",
                        rule,
                        f"version {one_line(version)!r} of {component} is no series (16, 16.*, 5:27) and no version: "
                        "dotsteward moves no package of it by this rule",
                    )
                )
                continue

            def allows(candidate, parsed=parsed):
                return in_line(candidate, *parsed)

        elif kind == "hold":
            if not VERSION_TEXT_RE.fullmatch(version):
                items.append(_rule_note("constraint-invalid", rule, f"the hold of {component} names no version"))
                continue

            def allows(candidate, version=version):
                return vcmp(candidate, version) < 0

        else:
            continue
        entry = {
            "kind": kind,
            "component": component,
            "version": version,
            "reason": one_line(rule.get("reason") or ""),
            "allows": allows,
            "packages": [str(name) for name in rule.get("packages") or ()],
        }
        for name in entry["packages"]:
            by_package.setdefault(name, []).append(entry)
    return by_package, items


def limit_candidates(rules, cache):
    """Sets, in CACHE, the candidate of each package the RULES bind to the newest version they allow
    from an origin apt trusts as much as its own candidate, or to the installed version. Answers
    ({name: {rule, newest, chosen}}, items); a package the rules leave alone has no entry."""
    by_package, items = read_rules(rules)
    limits = {}
    policy = cache._depcache.policy
    for name, entries in sorted(by_package.items()):
        if name not in cache:
            continue
        pkg = cache[name]
        if gated_package(pkg):
            continue

        def allowed(text, entries=entries):
            return all(entry["allows"](text) for entry in entries)

        candidate = pkg.candidate
        installed = pkg.installed
        if candidate is None:
            continue
        if allowed(candidate.version):
            continue
        rule = (
            entries[0]
            if len(entries) == 1
            else next(entry for entry in entries if not entry["allows"](candidate.version))
        )
        if installed is not None and not allowed(installed.version):
            items.append(
                report_item(
                    "constraint-left-by-owner",
                    package=name,
                    component=rule["component"],
                    installed=installed.version,
                    version=rule["version"],
                    message=f"{name} {installed.version} is outside {rule['kind']} {rule['version']} of "
                    f"{rule['component']}: the owner took it there, and dotsteward leaves it as it is",
                )
            )
            pkg.candidate = installed
            limits[name] = {"rule": rule, "newest": candidate.version, "chosen": installed.version}
            continue
        packages = {package for entry in entries for package in entry["packages"]}
        other = shared_with(cache, pkg, allowed, packages)
        if other is not None:
            items.append(
                report_item(
                    "constraint-shared",
                    package=name,
                    component=rule["component"],
                    needed_by=other,
                    version=rule["version"],
                    message=f"{other} needs {name} outside {rule['kind']} {rule['version']} of {rule['component']}: "
                    "the rule does not bind it, so that install stays possible",
                )
            )
            continue
        trust = policy.get_priority(candidate._cand)
        options = [
            version
            for version in pkg.versions
            if allowed(version.version)
            and policy.get_priority(version._cand) >= trust
            and (installed is None or vcmp(version.version, installed.version) >= 0)
        ]
        chosen = max(options, key=functools.cmp_to_key(lambda a, b: vcmp(a.version, b.version)), default=None)
        if chosen is None and installed is None:
            continue
        pkg.candidate = chosen or installed
        limits[name] = {"rule": rule, "newest": candidate.version, "chosen": (chosen or installed).version}
        items.append(
            report_item(
                "constraint-waits",
                package=name,
                component=rule["component"],
                version=rule["version"],
                newest=candidate.version,
                chosen=(chosen or installed).version,
                message=f"{name} {candidate.version} is outside {rule['kind']} {rule['version']} of "
                f"{rule['component']}: dotsteward takes {(chosen or installed).version}, the newer one waits for you",
            )
        )
    reported = set()
    for entries in by_package.values():
        for entry in entries:
            if entry["kind"] != "constraint" or id(entry) in reported:
                continue
            reported.add(id(entry))
            if not any(
                name in cache and any(entry["allows"](version.version) for version in cache[name].versions)
                for name in entry["packages"]
            ):
                items.append(
                    _rule_note(
                        "constraint-matches-nothing",
                        entry,
                        f"no package of {entry['component']} has a version inside {entry['version']}: it binds nothing",
                    )
                )
    return limits, items


PIN_PAIR = "Package: src:{source}:any\nPin: version {version}\nPin-Priority: {priority}\n"
PIN_SYNC_SCRIPT = """#!/usr/bin/python3 -I
# Managed by dotsteward. The dpkg hook of 60dotsteward-pin: the pin file names what dpkg has, under
# the rule of what is gated that the file already holds. Only `dotsteward upgrade` changes that rule.
import os
import re
import subprocess
import sys
import tempfile

GATED_SOURCE = re.compile(r"@GATED@")
HEADER = "@HEADER@"
PAIR = "@PAIR@"


def main(pin, admin):
    with open(pin, encoding="utf-8") as handle:
        text = handle.read()
    if not text.startswith(HEADER + "\\n"):
        return
    parts = text[len(HEADER) + 1 :].split("\\n\\n")
    rules = [part.strip("\\n") + "\\n" for part in parts if "Pin: version *" in part]
    query = subprocess.run(
        ["/usr/bin/dpkg-query", "--admindir=" + admin, "-W", "-f=${db:Status-Abbrev} ${source:Package} ${Version}\\n"],
        capture_output=True,
        text=True,
        check=True,
    )
    pairs = set()
    for line in query.stdout.splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[0][1] not in "nc" and GATED_SOURCE.match(fields[1]):
            pairs.add((fields[1], fields[2]))
    body = [PAIR.format(source=source, version=version) for source, version in sorted(pairs)]
    wanted = HEADER + "\\n" + "\\n".join(body + rules)
    if wanted == text:
        return
    descriptor, temporary = tempfile.mkstemp(prefix=".dotsteward-", dir=os.path.dirname(pin))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(wanted)
            stream.flush()
            os.fchmod(stream.fileno(), 0o644)
            os.fsync(stream.fileno())
        os.replace(temporary, pin)
    except BaseException:
        os.unlink(temporary)
        raise


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
"""


def pin_sync_script():
    pair = PIN_PAIR.replace("{priority}", str(PIN_PRIORITY)).replace("\n", "\\n")
    return (
        PIN_SYNC_SCRIPT.replace("@GATED@", GATED_SOURCE.pattern).replace("@HEADER@", PIN_HEADER).replace("@PAIR@", pair)
    )


def pin_text(pairs, *, kernel, nvidia):
    """The pin file: each (source, version) at 990, every other version of a gated Source at -1,
    for the classes this machine has: a machine without the NVIDIA stack can still install it.
    `:any` because a `src:` pin without it holds only packages of the native architecture,
    and the driver stack has i386 libraries."""
    body = [PIN_PAIR.format(source=source, version=version, priority=PIN_PRIORITY) for source, version in pairs]
    globs = (KERNEL_GLOBS if kernel else ()) + (NVIDIA_GLOBS if nvidia else ())
    if globs:
        names = " ".join(f"src:{name}:any" for name in globs)
        body.append(f"Package: {names}\nPin: version *\nPin-Priority: -1\n")
    return PIN_HEADER + "\n" + "\n".join(body)


def installed_pin(classes, *, keep_nvidia=False):
    nvidia = classes["nvidia"] is not None or keep_nvidia
    return pin_text(classes["pairs"], kernel=classes["kernel"] is not None, nvidia=nvidia)


def target_pin(classes, target):
    nvidia = classes["nvidia"] is not None or bool(target.get("installs"))
    return pin_text(target["pairs"], kernel=classes["kernel"] is not None, nvidia=nvidia)


class Session:
    """One action: its request, the temporary pin directories and the caches."""

    def __init__(self, request):
        self.request = request
        self.mode = request.get("mode", "tracked")
        self.tracked = set(request.get("tracked") or [])
        self.gated = request.get("gated", True) is not False
        self.running_kernel = request.get("running_kernel") or os.uname().release
        self.codename = request.get("codename") or os_release_codename()
        self.constraints = {name: str(value) for name, value in (request.get("constraints") or {}).items()}
        self.kept_rules = [rule for rule in request.get("kept") or [] if isinstance(rule, dict)]
        self.limits = None
        self.kept_items = []
        self.accept_install = set()
        self.accept_kernel = None
        self.accept_nvidia = None
        for key in request.get("accept") or []:
            if key.startswith("install:"):
                self.accept_install.add(key[len("install:") :])
            elif key.startswith("series:kernel="):
                self.accept_kernel = key[len("series:kernel=") :]
            elif key.startswith("series:nvidia="):
                self.accept_nvidia = key[len("series:nvidia=") :]
        self.stable_suites = {self.codename, f"{self.codename}-updates", f"{self.codename}-security"}
        apt_pkg.init_config()
        apt_pkg.init_system()
        self.real_parts = apt_pkg.config.find_dir("Dir::Etc::PreferencesParts")
        self.preferences = apt_pkg.config.find("Dir::Etc::Preferences")
        self.scratch = tempfile.mkdtemp(prefix=SCRATCH_PREFIX)
        self.pin_dirs = 0
        self.lock_error = ""
        self.journal_recovery = None
        self.dpkg_broken = []
        self.fix_broken = False
        self.classes = None

    def close(self):
        shutil.rmtree(self.scratch, ignore_errors=True)

    def pin_dir(self, text):
        """A directory for Dir::Etc::PreferencesParts: the files of others as they are, ours with TEXT."""
        self.pin_dirs += 1
        directory = os.path.join(self.scratch, f"pins-{self.pin_dirs}")
        os.mkdir(directory)
        if os.path.isdir(self.real_parts):
            for name in os.listdir(self.real_parts):
                if name != PIN_FILE:
                    os.symlink(os.path.join(self.real_parts, name), os.path.join(directory, name))
        if text is not None:
            with open(os.path.join(directory, PIN_FILE), "w", encoding="utf-8") as handle:
                handle.write(text)
        return directory

    def limit(self, cache):
        """The constraints and holds of the request in CACHE (again after a clear of its marks)."""
        limits, items = limit_candidates(self.kept_rules, cache)
        if self.limits is None:
            self.limits, self.kept_items = limits, items
        return limits

    def open_cache(self, text, limited=True):
        """A cache under the other's pins and the pin TEXT, the real file of ours never read; with
        LIMITED, the constraints and holds set its candidates."""
        apt_pkg.config.set("Dir::Etc::PreferencesParts", self.pin_dir(text))
        cache = apt.Cache()
        if limited and self.kept_rules:
            self.limit(cache)
            cache.dotsteward_limit = lambda: self.limit(cache)
        return cache

    def open_pinless(self):
        """A cache without any pin: every version in the archive is a candidate for the records."""
        directory = os.path.join(self.scratch, "no-pins")
        os.makedirs(directory, exist_ok=True)
        apt_pkg.config.set("Dir::Etc::PreferencesParts", directory)
        apt_pkg.config.set("Dir::Etc::Preferences", "/dev/null")
        cache = apt.Cache()
        apt_pkg.config.set("Dir::Etc::Preferences", self.preferences)
        return cache

    def stable(self, version):
        """Ubuntu's own release, -updates or -security; not -proposed, not -backports, not a PPA."""
        return any(origin.origin == "Ubuntu" and origin.archive in self.stable_suites for origin in version.origins)

    def suite_of(self, version):
        for origin in version.origins:
            if origin.origin == "Ubuntu" and origin.archive in self.stable_suites:
                return origin.archive
        return version.origins[0].archive if version.origins else ""


def os_release_codename():
    path = os.environ.get("DOTSTEWARD_OS_RELEASE") or "/etc/os-release"
    values = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                if "=" in line:
                    key, value = line.strip().split("=", 1)
                    values[key] = value.strip("\"'")
    except OSError:
        return ""
    return values.get("VERSION_CODENAME") or values.get("UBUNTU_CODENAME") or ""


# --- the gated classes, derived from what is installed ------------------------------


def abi_of_meta(cache, version):
    """(abi, flavour base) of a kernel meta package version, through its Depends, never its version string."""
    pending = [version]
    seen = set()
    while pending:
        current = pending.pop()
        for name, _relation, _value in deps(current):
            match = IMAGE_RE.match(name)
            if match:
                return match.group(1), match.group(2)
        for name, _relation, _value in deps(current):
            if name.startswith("linux-image-") and name in cache and name not in seen:
                seen.add(name)
                pending.extend(v for v in cache[name].versions if v.version == current.version)
    return None


def read_classes(cache):
    """What is gated on this machine: the kernel meta package, the driver and its module meta package."""
    pairs = set()
    metas = []
    drivers = []
    images = []
    for pkg in cache:
        installed = pkg.installed
        if installed is None:
            continue
        source = installed.source_name
        if GATED_SOURCE.match(source):
            pairs.add((source, installed.version))
        if source.startswith("linux-meta"):
            found = abi_of_meta(cache, installed)
            if found:
                metas.append((pkg, found))
        match = DRIVER_RE.match(pkg.shortname)
        if match:
            drivers.append((int(match.group(1)), pkg, match))
        image = IMAGE_RE.match(pkg.shortname)
        if image:
            images.append((image.group(1), image.group(2)))
    needed = {name for pkg, _found in metas for name, _relation, _value in deps(pkg.installed)}
    tops = [(pkg, found) for pkg, found in metas if pkg.shortname not in needed] or metas
    tops.sort(key=functools.cmp_to_key(lambda a, b: vcmp(a[0].installed.version, b[0].installed.version)), reverse=True)
    classes = {
        "pairs": sorted(pairs),
        "kernel": None,
        "nvidia": None,
        "other_metas": [pkg.shortname for pkg, _found in tops[1:]],
        "bases": sorted({base for _abi, base in images}),
        "abis": sorted({abi for abi, _base in images}),
        "newest": max(images, key=functools.cmp_to_key(lambda a, b: vcmp(a[0], b[0]))) if images else None,
    }
    flavour = None
    if tops:
        pkg, (abi, base) = tops[0]
        flavour = pkg.shortname[len("linux-") :]
        if flavour.startswith("image-"):
            flavour = flavour[len("image-") :]
        classes["kernel"] = {
            "meta": pkg.shortname,
            "version": pkg.installed.version,
            "series": series_of(pkg.installed.version),
            "flavour": flavour,
            "abi": abi,
            "base": base,
        }
    if drivers:
        _n, pkg, match = max(drivers, key=lambda row: row[0])
        kind = (match.group(2) or "") + (match.group(3) or "")
        classes["nvidia"] = driver_line(cache, match.group(1), kind, flavour, pkg.installed.version)
        classes["nvidia"]["source"] = pkg.installed.source_name
    return classes


def newest_kernel(classes, *, planned=False):
    """What GRUB boots by default, the newest installed image, for the look at its module. PLANNED: the
    plan in hand brings that module, or a newer kernel with its own."""
    if classes["newest"] is None:
        return None
    abi, base = classes["newest"]
    nvidia = classes["nvidia"]
    return {
        "abi": abi,
        "base": base,
        "release": f"{abi}-{base}",
        "nvidia": nvidia is not None,
        "prebuilt": bool(nvidia and nvidia["module_version"]),
        "driver_version": nvidia["version"] if nvidia else None,
        "planned": planned,
    }


def driver_line(cache, number, kind, flavour, installed_version):
    """The names of one driver series: the driver, its module packages, the package that holds the range."""
    server = "-server" if kind.startswith("-server") else ""
    module_meta = f"linux-modules-nvidia-{number}{kind}-{flavour}"
    line = {
        "series": f"{number}{kind}",
        "number": number,
        "kind": kind,
        "driver": f"nvidia-driver-{number}{kind}",
        "version": installed_version,
        "common": f"nvidia-kernel-common-{number}{server}",
        "module_prefix": f"linux-modules-nvidia-{number}{kind}",
        "module_meta": module_meta,
        "module_version": None,
    }
    if module_meta in cache and cache[module_meta].installed is not None:
        line["module_version"] = cache[module_meta].installed.version
    return line


def is_transitional(version, driver):
    """A version whose Depends names another nvidia-driver-*: the series is retired, however
    much the same name and Source look like an update of this series."""
    return any(name.startswith("nvidia-driver-") and name != driver for name, _relation, _value in deps(version))


def accepts(version, common, driver_version):
    """Whether a module version takes this driver: its range on the package that holds the upstream version."""
    bound = False
    for name, relation, value in deps(version):
        if name == common and relation:
            bound = True
            if not apt_pkg.check_dep(driver_version, relation, value):
                return False
    return bound


def version_of(cache, name, wanted):
    if name not in cache:
        return None
    return next((v for v in cache[name].versions if v.version == wanted), None)


def loses_running(losses, running):
    """Whether a module of the running kernel is among LOSSES: its ABI, not a part of it."""
    return any((match := ABI_PACKAGE_RE.match(name.split(":")[0])) and match.group(1) == running for name in losses)


def abi_of_release(release):
    """The ABI of `uname -r`: 7.0.0-42-generic is 7.0.0-42."""
    match = re.match(rf"^{ABI}", release)
    return match.group(0) if match else release


def report_item(code, *, pending=False, **fields):
    return {"code": code, "pending": pending, **fields}


def joint_target(session, cache, classes):
    """One shared target for kernel, module meta and driver, read from the records.
    The answer has `pairs`, the (source, version) that may move, and `losses`, the module packages
    of other ABIs that apt removes because nothing in the archive takes the new driver; None when
    there is no target, with the reasons in `items`."""
    items = []
    kernel = classes["kernel"]
    target = {
        "pairs": [],
        "losses": [],
        "kernel": None,
        "module": None,
        "abi_module": None,
        "driver": None,
        "abi": None,
    }
    if kernel is None and classes["nvidia"] is None:
        return None, items

    kernels = []
    if kernel:
        meta = cache[kernel["meta"]]
        kernels = [
            v
            for v in newest_first(meta.versions)
            if v.version == kernel["version"] or (session.stable(v) and vcmp(v.version, kernel["version"]) > 0)
        ]
        target["kernel"] = kernel["version"]
    wanted_series = session.accept_kernel or (kernel["series"] if kernel else None)
    candidates = [v for v in kernels if series_of(v.version) == wanted_series]
    if session.accept_kernel and not candidates:
        items.append(
            report_item(
                "apt-denied",
                pending=True,
                **{"class": "series-unknown"},
                packages=[kernel["meta"]] if kernel else [],
                message=f"no stable kernel of series {session.accept_kernel} for this machine",
            )
        )
        return None, items

    line = classes["nvidia"]
    changing_driver = False
    if session.accept_nvidia:
        number, kind = parse_series_key(session.accept_nvidia, line)
        if line is None or number != line["number"] or kind != line["kind"]:
            changing_driver = True
            line = driver_line(cache, number, kind, kernel["flavour"] if kernel else "generic", None)

    if line is None:
        chosen = candidates[0] if candidates else None
        if chosen is None:
            return None, items
        target.update(kernel=chosen.version, pairs=[(chosen.source_name, chosen.version)])
        return target, items

    driver_name = line["driver"]
    if driver_name not in cache:
        items.append(
            report_item(
                "apt-denied",
                pending=True,
                **{"class": "series-unknown"},
                packages=[driver_name],
                message=f"no driver {driver_name} in the archive",
            )
        )
        return None, items
    driver_pkg = cache[driver_name]
    drivers = []
    retired = False
    for version in newest_first(driver_pkg.versions):
        if line["version"] is not None and vcmp(version.version, line["version"]) < 0:
            continue
        if version.version != line["version"] and not session.stable(version):
            continue
        if is_transitional(version, driver_name):
            retired = True
            continue
        drivers.append(version)
    target["retired"] = retired

    module_version = line["module_version"]
    if line["version"] is not None and module_version is None:
        # DKMS: no module package to pair with; the kernel and the driver move on their own.
        chosen = candidates[0] if candidates else None
        pairs = []
        if chosen is not None:
            target["kernel"] = chosen.version
            pairs.append((chosen.source_name, chosen.version))
        if drivers:
            target["driver"] = drivers[0].version
            pairs.append((drivers[0].source_name, drivers[0].version))
        target["pairs"] = pairs
        items.append(report_item("module-through-dkms", driver=driver_name))
        return target, items

    module_meta = line["module_meta"]
    if module_meta not in cache:
        modules = []
    else:
        modules = [
            v
            for v in newest_first(cache[module_meta].versions)
            if v.version == module_version
            or (session.stable(v) and (module_version is None or vcmp(v.version, module_version) > 0))
        ]
    chosen = None
    for kv in candidates:
        found = abi_of_meta(cache, kv)
        if not found:
            continue
        abi, base = found
        abi_module = f"{line['module_prefix']}-{abi}-{base}"
        here = []
        for mv in modules:
            here += [(mv, value) for name, _relation, value in deps(mv) if name == abi_module]
        if not here:
            if kernel is None or kv.version != kernel["version"]:
                items.append(report_item("kernel-waiting", kernel=kv.version, reason="no-module"))
            continue
        for mv, value in here:
            av = version_of(cache, abi_module, value)
            if av is None:
                continue
            for dv in drivers:
                if accepts(av, line["common"], dv.version):
                    chosen = (kv, mv, av, dv, abi)
                    break
            if chosen:
                break
        if chosen:
            break
        if kernel is None or kv.version != kernel["version"]:
            items.append(report_item("kernel-waiting", kernel=kv.version, reason="no-driver"))
    if chosen is None:
        if session.accept_kernel:
            items.append(
                report_item(
                    "apt-denied",
                    pending=True,
                    **{"class": "series-needs-nvidia"},
                    packages=[kernel["meta"]],
                    message=(
                        f"the kernel series {session.accept_kernel} has no module of the NVIDIA series "
                        f"{line['series']}: change the NVIDIA series first"
                    ),
                )
            )
        if changing_driver:
            items.append(
                report_item(
                    "apt-denied",
                    pending=True,
                    **{"class": "series-unknown"},
                    packages=[driver_name],
                    message=f"no module of the NVIDIA series {line['series']} for this kernel",
                )
            )
        if drivers and line["version"] is not None and drivers[0].version != line["version"]:
            items.append(report_item("driver-waiting", driver=drivers[0].version))
        return None, items

    kv, mv, av, dv, abi = chosen
    pairs = {
        (kv.source_name, kv.version),
        (mv.source_name, mv.version),
        (av.source_name, av.version),
        (dv.source_name, dv.version),
    }
    if drivers and dv.version != drivers[0].version:
        items.append(report_item("driver-waiting", driver=drivers[0].version))
    # The modules of the other ABIs: kept when the new driver suits them, else a respin, else lost.
    losses = []
    other = re.compile(rf"^{re.escape(line['module_prefix'])}-({ABI})-[a-z0-9-]+$")
    for pkg in cache:
        match = other.match(pkg.shortname)
        if not (match and pkg.is_installed) or match.group(1) == abi:
            continue
        if accepts(pkg.installed, line["common"], dv.version):
            pairs.add((pkg.installed.source_name, pkg.installed.version))
            continue
        respins = [
            v for v in newest_first(pkg.versions) if session.stable(v) and accepts(v, line["common"], dv.version)
        ]
        if respins:
            pairs.add((respins[0].source_name, respins[0].version))
        else:
            losses.append(pkg.name)
    # A series change: the module of the old series goes with it, on every kernel that has one. The
    # new series takes its place where the archive has a module that suits the driver.
    fallback_modules = []
    if changing_driver and classes["nvidia"]:
        old = re.compile(rf"^{re.escape(classes['nvidia']['module_prefix'])}-({ABI})-([a-z0-9-]+)$")
        for pkg in cache:
            match = old.match(pkg.shortname)
            if not (match and pkg.is_installed) or match.group(1) == abi:
                continue
            name = f"{line['module_prefix']}-{match.group(1)}-{match.group(2)}"
            versions = cache[name].versions if name in cache else ()
            suited = [v for v in newest_first(versions) if session.stable(v) and accepts(v, line["common"], dv.version)]
            if suited:
                pairs.add((suited[0].source_name, suited[0].version))
                fallback_modules.append(name)
            else:
                losses.append(pkg.name)
    target.update(
        kernel=kv.version,
        module=mv.version,
        abi_module=av.version,
        driver=dv.version,
        abi=abi,
        pairs=sorted(pairs),
        losses=sorted(losses),
    )
    if changing_driver:
        # The module first: its Provides satisfies the driver, which otherwise pulls the DKMS package.
        target["installs"] = [module_meta, *sorted(fallback_modules), driver_name]
        target["old_series"] = classes["nvidia"]
    return target, items


def parse_series_key(key, line):
    """615-open or 615; a bare number keeps the kind of the installed driver."""
    match = re.match(r"^(\d+)((?:-server)?(?:-open)?)$", key)
    if not match:
        raise HelperError("usage", f"not a series of NVIDIA: {key}")
    kind = match.group(2)
    if not kind and line is not None:
        kind = line["kind"]
    return match.group(1), kind


def ubuntu_devices(session):
    """What `ubuntu-drivers devices` says for this hardware under no pin at all, as (drivers,
    recommended); None when it does not answer. Its noise goes to standard error."""
    if not shutil.which("ubuntu-drivers"):
        return None
    empty = os.path.join(session.scratch, "no-pins")
    os.makedirs(empty, exist_ok=True)
    config = os.path.join(session.scratch, "ubuntu-drivers.conf")
    with open(config, "w", encoding="utf-8") as handle:
        original = os.environ.get("APT_CONFIG")
        if original:
            handle.write(f'#include "{original}";\n')
        handle.write(f'Dir::Etc::Preferences "/dev/null";\nDir::Etc::PreferencesParts "{empty}";\n')
    try:
        done = subprocess.run(
            ["ubuntu-drivers", "devices"],
            env={**os.environ, "APT_CONFIG": config},
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if done.returncode != 0:
        return None
    drivers = set()
    recommended = None
    for text in done.stdout.splitlines():
        match = UBUNTU_DRIVERS_RE.match(text.strip())
        if match:
            drivers.add(match.group(1))
            if "recommended" in match.group(2).split():
                recommended = match.group(1)[len("nvidia-driver-") :]
    return drivers, recommended


def newer_nvidia_series(session, cache, line, flavour):
    """The series above the installed one, highest first: same kind, no server series, a stable
    driver that is no transitional package and a stable module for this kernel flavour."""
    rows = []
    names = cache.keys()
    for name in names:
        match = DRIVER_RE.match(name)
        if not match or match.group(2) or (match.group(3) or "") != line["kind"]:
            continue
        number = int(match.group(1))
        module = f"linux-modules-nvidia-{number}{line['kind']}-{flavour}"
        if number <= int(line["number"]) or module not in cache:
            continue
        drivers = [v for v in newest_first(cache[name].versions) if session.stable(v)]
        if (
            not drivers
            or is_transitional(drivers[0], name)
            or not any(session.stable(v) for v in cache[module].versions)
        ):
            continue
        rows.append(
            {
                "number": number,
                "driver": name,
                "series": f"{number}{line['kind']}",
                "version": drivers[0].version,
                "suite": session.suite_of(drivers[0]),
                "module": module,
            }
        )
    rows.sort(key=lambda row: row["number"], reverse=True)
    return rows


def series_items(session, cache, classes, target):
    """A new series is found and named, and nothing moves until the owner says so."""
    items = []
    kernel = classes["kernel"]
    line = classes["nvidia"]
    if kernel and not session.accept_kernel:
        newer = [
            v
            for v in newest_first(cache[kernel["meta"]].versions)
            if session.stable(v) and series_key(series_of(v.version)) > series_key(kernel["series"])
        ]
        if newer:
            top = newer[0]
            series = series_of(top.version)
            ready = False
            if line and line["module_version"] is not None:
                found = abi_of_meta(cache, top)
                module_meta = line["module_meta"]
                if found and module_meta in cache:
                    abi_module = f"{line['module_prefix']}-{found[0]}-{found[1]}"
                    ready = any(
                        name == abi_module for mv in cache[module_meta].versions for name, _relation, _value in deps(mv)
                    )
            items.append(
                report_item(
                    "series-available",
                    **{"class": "kernel"},
                    series=series,
                    version=top.version,
                    suite=session.suite_of(top),
                    nvidia_ready=ready if line else None,
                    accept=f"dotsteward upgrade --accept series:kernel={series}",
                    message=(
                        f"kernel {series} ({session.suite_of(top)}) is available"
                        + (f"; it has no module of NVIDIA {line['series']} yet" if line and not ready else "")
                    ),
                )
            )
    if line and not session.accept_nvidia:
        rows = newer_nvidia_series(session, cache, line, kernel["flavour"] if kernel else "generic")
        retired = bool(target and target.get("retired"))
        driver_pkg = cache.get(line["driver"])
        if driver_pkg is not None and not any(session.stable(v) for v in driver_pkg.versions):
            retired = True
        recommended = None
        if rows or retired:
            # The tool knows the hardware and takes seconds: only when there is something to say.
            devices = ubuntu_devices(session)
            if devices is not None:
                listed, recommended = devices
                if listed:
                    rows = [row for row in rows if row["driver"] in listed]
        if rows or retired:
            item = {"class": "nvidia", "retired": retired, "recommended": recommended, "installed": line["series"]}
            if rows:
                best = rows[0]
                item.update(
                    series=best["series"],
                    version=best["version"],
                    suite=best["suite"],
                    module=best["module"],
                    accept=f"dotsteward upgrade --accept series:nvidia={best['series']}",
                )
                text = f"NVIDIA {best['series']} ({best['suite']}, module {best['module']}) is available"
                if recommended:
                    text += f"; recommended {recommended}"
            else:
                text = f"no newer NVIDIA series for {line['series']}"
            if retired:
                text += f"; the series {line['series']} gets no more updates"
            items.append(report_item("series-available", message=text, **item))
    return items


# --- one plan in one depcache --------------------------------------------------------


def phased_percentage(version):
    value = version.record.get("Phased-Update-Percentage")
    return int(value) if value not in (None, "") and str(value).isdigit() else None


def upgradable(cache):
    """The packages this cache could upgrade, by name. Read it before the marks: when the
    resolver keeps a package back, the depcache no longer calls it upgradable."""
    rows = {}
    for pkg in cache:
        if pkg.installed is None or pkg.candidate is None or not pkg.is_upgradable:
            continue
        rows[pkg.name] = {
            "name": pkg.name,
            "short": pkg.shortname,
            "current": pkg.installed.version,
            "candidate": pkg.candidate.version,
            "source": pkg.candidate.source_name,
            "origin": origin_text(pkg.candidate),
            "percentage": phased_percentage(pkg.candidate),
            "held": pkg._pkg.selected_state == apt_pkg.SELSTATE_HOLD,
        }
    return rows


def mark_series_change(cache, target):
    """The driver series a person chose in place of the installed one: the old stack goes by name,
    first. Left to the problem resolver the same move works or fails with the rest of the system,
    because its scores count every reverse dependency."""
    extra = (target or {}).get("installs") or ()
    old = (target or {}).get("old_series")
    if old:
        prefix = old["module_prefix"] + "-"
        for pkg in cache:
            if pkg.is_installed and (pkg.installed.source_name == old["source"] or pkg.shortname.startswith(prefix)):
                pkg.mark_delete(auto_fix=False)
    for name in extra:
        cache[name].mark_install()


def upgrade_all(cache, target=None, fix=False):
    """The full upgrade of this cache, which keeps to pins, holds and phasing, plus the series change
    of TARGET. FIX: dpkg was stopped during an unpack, and that package is unpacked again; first, so
    that the answer also tells what this does to the upgrade. Answers the packages it keeps or brings
    in, by name."""
    if fix:
        cache.fix_broken()
    cache.upgrade(dist_upgrade=True)
    with cache.actiongroup():
        mark_series_change(cache, target)
    return {pkg.name for pkg in cache.get_changes() if not pkg.marked_delete}


def mark_tracked(cache, names, target=None, fix=False):
    """The tracked mode marks by hand; every name comes from the full upgrade, because a mark
    goes through phasing where a full upgrade does not."""
    cache.clear()
    # A clear sets the candidates of the policy again: the constraints and holds come back first.
    limit = getattr(cache, "dotsteward_limit", None)
    if limit is not None:
        limit()
    if fix:
        cache.fix_broken()
    with cache.actiongroup():
        for name in sorted(names):
            cache[name].mark_upgrade()
        mark_series_change(cache, target)


def origin_text(version):
    if version is None or not version.origins:
        return ""
    first = version.origins[0]
    return f"{first.origin}/{first.archive}"


def pulled_by(cache, wanted, changes):
    """The first package of the plan that needs WANTED, for the person who reads the refusal."""
    shortname = wanted.split(":")[0]
    for pkg in changes:
        version = pkg.candidate
        if pkg.marked_delete or version is None or pkg.name == wanted:
            continue
        names = {name for name, _relation, _value in deps(version)}
        names |= {dep.name for group in version.recommends for dep in group.or_dependencies}
        if shortname in names:
            return pkg.name
    return None


def removal_allowed(pkg, new_sources, protected, losses, old_series_sources, old_series_prefix):
    """A removal is refused unless it is a named case; the protected kernels never are one."""
    installed = pkg.installed
    match = ABI_PACKAGE_RE.match(pkg.shortname)
    if pkg.name in losses or pkg.shortname in losses:
        return "module-loss"
    if match and source_class(pkg.shortname, installed.source_name) == "kernel":
        if match.group(1) in protected:
            return None
        return "old-abi"
    if installed.source_name in old_series_sources:
        return "series-change"
    if old_series_prefix and pkg.shortname.startswith(old_series_prefix):
        return "series-change"
    # A module of another ABI is no transition of a name: only `losses` lets it go.
    if installed.source_name in new_sources and source_class(pkg.shortname, installed.source_name) != "nvidia-module":
        return "same-source"
    return None


def evaluate(session, cache, classes, target):
    """The refusal list over the changes of the depcache: default allow, named risk classes."""
    changes = sorted(cache.get_changes(), key=lambda pkg: pkg.name)
    rows = {"install": [], "upgrade": [], "remove": [], "downgrade": []}
    denied = []
    losses = set(target["losses"]) if target else set()
    line = classes["nvidia"]
    accepted_nvidia = None
    if session.accept_nvidia and line is not None:
        number, kind = parse_series_key(session.accept_nvidia, line)
        accepted_nvidia = f"nvidia-driver-{number}{kind}"
    planned_new = {pkg.shortname for pkg in changes if pkg.marked_install}
    new_sources = {pkg.candidate.source_name for pkg in changes if pkg.marked_install and pkg.candidate is not None}
    dkms_installed = any(DKMS_RE.match(pkg.shortname) and pkg.is_installed for pkg in cache)
    allowed_bases = set(classes["bases"])

    def deny(cls, package, *, message=None):
        item = {"class": cls, "packages": [package]}
        if pulled := pulled_by(cache, package, changes):
            item["pulled_by"] = pulled
        if cls in ACCEPTABLE:
            if package in session.accept_install or package.split(":")[0] in session.accept_install:
                return
            item["accept"] = f"dotsteward upgrade --accept install:{package}"
        if message:
            item["message"] = message
        denied.append(item)

    def module_ready(abi, base):
        return f"{line['module_prefix']}-{abi}-{base}" in planned_new

    for pkg in changes:
        name = pkg.name
        short = pkg.shortname
        if pkg.marked_delete:
            source = pkg.installed.source_name
            rows["remove"].append({"name": name, "version": pkg.installed.version, "source": source})
            continue
        version = pkg.candidate
        source = version.source_name
        cls = source_class(short, source)
        row = {
            "name": name,
            "source": source,
            "version": version.version,
            "origin": origin_text(version),
            "auto": pkg.is_auto_installed,
        }
        if cls:
            row["class"] = cls
        if pkg.marked_install:
            rows["install"].append(row)
        elif pkg.marked_downgrade:
            row["from"] = pkg.installed.version
            rows["downgrade"].append(row)
            deny("downgrade", name)
        else:
            row["from"] = pkg.installed.version if pkg.installed else None
            rows["upgrade"].append(row)
        if cls in {"kernel", "nvidia-driver", "nvidia-module"} and not session.stable(version):
            deny(
                "origin",
                name,
                message=f"{name} {version.version} comes from {origin_text(version)}, not a stable suite",
            )
        if pkg.marked_install:
            match = FLAVOUR_RE.match(short)
            if cls == "kernel" and match and allowed_bases and match.group(1) not in allowed_bases:
                deny("kernel-flavour", name)
            if DKMS_RE.match(short) and not dkms_installed:
                deny("dkms", name)
            driver = DRIVER_RE.match(short)
            if driver and line is not None and short != line["driver"] and short != accepted_nvidia:
                deny("driver-series", name)
            for constrained, wanted in session.constraints.items():
                major = re.match(rf"^{re.escape(constrained)}-(\d+)$", source)
                series = parse_series(wanted)
                if major and series is not None and major.group(1) != series[1].split(".")[0]:
                    deny("constrained-major", name)
            image = IMAGE_RE.match(short)
            if (
                image
                and line is not None
                and line.get("module_version") is not None
                and not module_ready(image.group(1), image.group(2))
                and not session.accept_nvidia
                and short not in session.accept_install
            ):
                deny(
                    "module-missing",
                    name,
                    message=f"the new kernel {image.group(1)} has no module of the installed driver",
                )

    # The kernels that never go: the running one, the newest, the newest with a module.
    protected = {abi_of_release(session.running_kernel)}
    all_abis = list(classes["abis"]) + [
        match.group(1) for pkg in changes if pkg.marked_install and (match := IMAGE_RE.match(pkg.shortname))
    ]
    if all_abis:
        protected.add(max(all_abis, key=functools.cmp_to_key(vcmp)))
    if line is not None:
        with_module = []
        prefix = re.compile(rf"^{re.escape(line['module_prefix'])}-({ABI})-")
        for pkg in cache:
            match = prefix.match(pkg.shortname)
            if match and (pkg.is_installed or pkg.marked_install) and not pkg.marked_delete:
                with_module.append(match.group(1))
        if with_module:
            protected.add(max(with_module, key=functools.cmp_to_key(vcmp)))
    old_sources = set()
    old_prefix = None
    if target and target.get("old_series"):
        old_sources.add(target["old_series"]["source"])
        old_prefix = target["old_series"]["module_prefix"] + "-"
    for row in rows["remove"]:
        pkg = cache[row["name"]]
        reason = removal_allowed(pkg, new_sources, protected, losses, old_sources, old_prefix)
        if reason:
            row["reason"] = reason
        else:
            deny("removal", row["name"], message=f"the plan removes {row['name']}, which no rule allows")
    return rows, denied


def waiting_reason(row):
    if row is None:
        return "kept"
    if row["held"]:
        return "held"
    return "phased" if row["percentage"] is not None else "kept"


def make_plan(session):
    """The plan of one run. The answer holds the depcache that a later commit applies."""
    pinless = session.open_pinless()
    classes = read_classes(pinless)
    session.classes = classes
    items = []
    target = None
    gated_info = {
        "enabled": session.gated,
        "kernel": classes["kernel"],
        "nvidia": classes["nvidia"],
        "other_metas": classes["other_metas"],
        "installed_pairs": classes["pairs"],
        "pin": installed_pin(classes),
        "decision": "off" if not session.gated else "no-move",
        "target": None,
    }
    moved = False
    if session.gated:
        if classes["other_metas"]:
            items.append(
                report_item(
                    "kernel-meta-held",
                    packages=classes["other_metas"],
                    message="only the newest kernel meta package moves; the others stay where they are",
                )
            )
        target, target_items = joint_target(session, pinless, classes)
        items += target_items
        items += series_items(session, pinless, classes, target)
        moved = target is not None and bool({tuple(pair) for pair in target["pairs"]} - set(classes["pairs"]))
        if session.dpkg_broken:
            items.append(
                report_item(
                    "dpkg-broken",
                    pending=True,
                    packages=session.dpkg_broken,
                    message="dpkg cannot configure these: no kernel or driver moves on top of that",
                )
            )
            gated_info["decision"] = "waiting"
            moved = False
            target = None
        if target is not None:
            gated_info["target"] = {key: value for key, value in target.items() if key != "old_series"}
    del pinless

    cache = None
    moves = set()
    upgrades = set()
    candidates = {}
    if not session.gated:
        cache = session.open_cache(None)
        candidates = upgradable(cache)
        upgrades = upgrade_all(cache, fix=session.fix_broken)
    else:
        if moved:
            cache = session.open_cache(target_pin(classes, target))
            candidates = upgradable(cache)
            moves = {name for name, row in candidates.items() if GATED_SOURCE.match(row["source"])}
            upgrades = upgrade_all(cache, target, fix=session.fix_broken)
            left = moves - upgrades
            if left:
                # The set stays together; the pin of what is installed takes over.
                reasons = {name: waiting_reason(candidates.get(name)) for name in sorted(left)}
                code = "phased-waiting" if "phased" in reasons.values() else "gated-kept-back"
                items.append(
                    report_item(
                        code,
                        scope="gated",
                        packages=sorted(left),
                        reasons=reasons,
                        target=target["kernel"],
                        message="the kernel and driver set waits as one unit",
                    )
                )
                gated_info["decision"] = "waiting"
                moved = False
                moves = set()
                target = None
            else:
                gated_info["decision"] = "move"
        if not moved:
            cache = session.open_cache(gated_info["pin"])
            candidates = upgradable(cache)
            upgrades = upgrade_all(cache, fix=session.fix_broken)

    if session.mode == "tracked":
        names = {
            name
            for name, row in candidates.items()
            if name in upgrades
            and (name in session.tracked or row["short"] in session.tracked)
            and not (session.gated and GATED_SOURCE.match(row["source"]))
        }
        mark_tracked(cache, names | moves, target if moved else None, fix=session.fix_broken)
        outside = [pkg.name for pkg in cache.get_changes() if pkg.marked_upgrade and pkg.name not in upgrades]
        for name in outside:
            items.append(
                report_item(
                    "apt-denied",
                    pending=True,
                    **{"class": "outside-upgrade"},
                    packages=[name],
                    message=f"a tracked upgrade pulls {name}, which a full upgrade leaves alone",
                )
            )
    if cache.broken_count:
        items.append(report_item("apt-denied", pending=True, **{"class": "unsolvable"}, packages=[]))

    # The constraints and holds, said once: the first cache that read them.
    items += list(session.kept_items)
    rows, denied = evaluate(session, cache, classes, target)
    items += [report_item("apt-denied", pending=True, **entry) for entry in denied]

    # What waits, seen from the mode of this run.
    phased = []
    kept = []
    planned = {row["name"] for rows_of in rows.values() for row in rows_of}
    for name, row in sorted(candidates.items()):
        if name in planned or (
            session.mode == "tracked" and name not in session.tracked and row["short"] not in session.tracked
        ):
            continue
        entry = {"name": name, "current": row["current"], "candidate": row["candidate"]}
        if waiting_reason(row) == "phased" and name not in upgrades:
            entry["percentage"] = row["percentage"]
            phased.append(entry)
        else:
            kept.append(entry)
    if phased:
        items.append(
            report_item(
                "phased-waiting",
                scope=session.mode,
                packages=[entry["name"] for entry in phased],
                message="upgrades deferred by phasing come by themselves",
            )
        )
    if kept:
        items.append(report_item("kept-back", packages=[entry["name"] for entry in kept]))
    if target and target["losses"]:
        running = abi_of_release(session.running_kernel)
        items.append(
            report_item(
                "module-loss",
                packages=target["losses"],
                running=loses_running(target["losses"], running),
                message=loss_message(target["losses"], running),
            )
        )
    old_kernels = sorted(row["name"] for row in rows["remove"] if row.get("reason") == "old-abi")
    if old_kernels:
        items.append(report_item("kernel-removed", packages=old_kernels, message="an old kernel makes way"))
    if target and target.get("old_series"):
        items.append(
            report_item(
                "driver-needs-reboot",
                message="the loaded module stays of the old series: driver and user space differ until a reboot",
            )
        )
    module_names = {row["name"].split(":")[0] for bucket in ("install", "upgrade") for row in rows[bucket]}
    newest = classes["newest"]
    module_planned = bool(
        newest
        and classes["nvidia"]
        and (
            (target and target.get("abi") and vcmp(target["abi"], newest[0]) > 0)
            or f"{classes['nvidia']['module_prefix']}-{newest[0]}-{newest[1]}" in module_names
        )
    )
    plan = {
        "schema_version": SCHEMA_VERSION,
        "apt": apt_pkg.VERSION,
        "mode": session.mode,
        "newest_kernel": newest_kernel(classes, planned=module_planned),
        "codename": session.codename,
        "gated": gated_info,
        "changes": rows,
        "phased": phased,
        "kept_back": kept,
        "items": items,
        "applicable": not any(item["pending"] for item in items),
    }
    return cache, plan


def loss_message(losses, running):
    text = "NVIDIA modules of older kernels go: " + ", ".join(losses)
    if loses_running(losses, running):
        text += "; the running kernel is one of them, so driver and user space do not match until a reboot"
    return text


# --- read only analysis ---------------------------------------------------------------


def action_analysis(session):
    pinless = session.open_pinless()
    classes = read_classes(pinless)
    del pinless
    free = upgradable(session.open_cache(None, limited=False))
    cache = session.open_cache(installed_pin(classes) if session.gated else None)
    autoremovable = sum(1 for pkg in cache if pkg.is_installed and pkg.is_auto_removable)
    candidates = upgradable(cache)
    kept = kept_rows(session, cache, free)
    upgrades = upgrade_all(cache)
    packages = [
        {
            "name": name,
            "current": row["current"],
            "candidate": row["candidate"],
            "origin": row["origin"],
            "phased": name not in upgrades and row["percentage"] is not None,
            "held": row["held"],
        }
        for name, row in sorted(candidates.items())
        if name not in session.tracked and row["short"] not in session.tracked
    ]
    boot = session.request.get("boot_path") or "/boot"
    boot_low_mib = session.request.get("boot_low_mib") or BOOT_LOW_MIB
    try:
        boot_free = shutil.disk_usage(boot).free // (1024 * 1024)
    except OSError:
        boot_free = None
    return {
        "schema_version": SCHEMA_VERSION,
        "available": True,
        "count": len(packages),
        "packages": packages,
        "kernels": len(classes["abis"]),
        "kept": kept,
        "autoremovable": autoremovable,
        "boot_free_mib": boot_free,
        "boot_low": boot_free is not None and boot_free < boot_low_mib,
        "last_update": last_update(),
    }


def kept_rows(session, cache, free):
    """What dotsteward keeps from an upgrade apt would make: the installed packages whose candidate
    the constraints, the holds or the gated classes change, with why. ``free`` is the candidate
    without them. The owner's own apt is not bound by any of it."""
    limits = session.limits or {}
    rows = []
    for name, row in sorted(free.items()):
        candidate = cache[name].candidate.version if name in cache and cache[name].candidate is not None else None
        if candidate == row["candidate"]:
            continue
        entry = {
            "name": name,
            "current": row["current"],
            "candidate": candidate or row["current"],
            "free": row["candidate"],
        }
        limit = limits.get(name) or limits.get(row["short"])
        if limit is not None:
            rule = limit["rule"]
            entry.update(why=rule["kind"], component=rule["component"], version=rule["version"], reason=rule["reason"])
        elif source_class(row["short"], row["source"]) in ("kernel", "nvidia-driver", "nvidia-module"):
            entry.update(why="gated", reason="moves with the shared target of kernel, module and driver")
        else:
            entry.update(why="pin")
        rows.append(entry)
    return rows


def last_update():
    """When the lists were last fetched, in UTC, or None when there are none."""
    directory = apt_pkg.config.find_dir("Dir::State::lists")
    newest = None
    try:
        with os.scandir(directory) as entries:
            for entry in entries:
                if entry.is_file():
                    stamp = entry.stat().st_mtime
                    newest = stamp if newest is None else max(newest, stamp)
    except OSError:
        return None
    if newest is None:
        return None
    moment = datetime.datetime.fromtimestamp(newest, datetime.timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


# --- the command line ------------------------------------------------------------------


def interrupted_plan(session):
    """A journal that holds updates: apt sees half a transaction, in which a driver or a kernel may
    look absent. Nothing can be decided from that picture."""
    message = "dpkg is running or was stopped half way: the next run with sudo recovers it first"
    return {
        "schema_version": SCHEMA_VERSION,
        "apt": apt_pkg.VERSION,
        "mode": session.mode,
        "newest_kernel": None,
        "codename": session.codename,
        "gated": {
            "enabled": session.gated,
            "kernel": None,
            "nvidia": None,
            "other_metas": [],
            "installed_pairs": [],
            "pin": None,
            "decision": "waiting",
            "target": None,
        },
        "changes": {"install": [], "upgrade": [], "remove": [], "downgrade": []},
        "phased": [],
        "kept_back": [],
        "items": [report_item("dpkg-interrupted", pending=True, message=message)],
        "applicable": False,
    }


def action_plan(session):
    if journal_dirty():
        return interrupted_plan(session)
    _cache, plan = make_plan(session)
    return plan


# --- the changes: pin file, recovery, commit -------------------------------------------


def read_text(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return ""


def write_file(path, text, mode=0o644):
    """Replaces a file through a rename, so a reader sees the old text or the new one, also after
    a crash; a file that already holds TEXT is left alone. Answers whether it wrote."""
    try:
        with open(path, encoding="utf-8") as handle:
            if handle.read() == text and (os.stat(path).st_mode & 0o777) == mode:
                return False
    except OSError:
        pass
    directory = os.path.dirname(path) or "."
    handle, temporary = tempfile.mkstemp(prefix=".dotsteward-", dir=directory)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fchmod(stream.fileno(), mode)
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return True


def apply_pin_hook(pin_path, wanted):
    """The dpkg hook next to the pin file: it stands and goes with it."""
    root = apt_pkg.config.find_dir("Dir")
    script = os.path.join(root, PIN_SYNC_FILE)
    config = os.path.join(root, "etc/dpkg/dpkg.cfg.d", PIN_HOOK_FILE)
    changed = False
    if wanted:
        os.makedirs(os.path.dirname(script), exist_ok=True)
        os.makedirs(os.path.dirname(config), exist_ok=True)
        os.chmod(os.path.dirname(script), 0o755)
        changed = write_file(script, pin_sync_script(), 0o755)
        command = f"/usr/bin/python3 -I {script} {pin_path} {dpkg_admin_dir()} >/dev/null 2>&1 || true"
        header = "# Managed by dotsteward: the pin file follows what dpkg has, whoever calls dpkg."
        changed = write_file(config, f'{header}\npost-invoke="{command}"\n') or changed
    else:
        for path in (config, script):
            if os.path.exists(path):
                os.unlink(path)
                changed = True
    return {"config": config, "script": script, "present": wanted, "changed": changed}


def apply_policy(session, classes):
    """The files of this action from what dpkg has now, whatever they said before."""
    pin_path = os.path.join(session.real_parts, PIN_FILE)
    wanted_pin = session.gated and (classes["kernel"] is not None or classes["nvidia"] is not None)
    if wanted_pin:
        # Half a transaction may hide the driver; the class stays until dpkg is whole again.
        keep_nvidia = classes["nvidia"] is None and bool(dpkg_audit()) and NVIDIA_GLOB in read_text(pin_path)
        pin_changed = write_file(pin_path, installed_pin(classes, keep_nvidia=keep_nvidia))
    else:
        pin_changed = False
        if os.path.exists(pin_path):
            os.unlink(pin_path)
            pin_changed = True
    hook = apply_pin_hook(pin_path, wanted_pin)
    return {
        "pin": {"path": pin_path, "present": wanted_pin, "changed": pin_changed},
        "hook": hook,
        "installed_pairs": classes["pairs"],
    }


def action_policy(session):
    """Under the lock of dpkg, after the journal of a killed dpkg is worked off: what dpkg has is only
    then what apt sees. When others keep the lock the files stay as they are."""
    if not take_lock(session):
        return {
            "schema_version": SCHEMA_VERSION,
            "status": "blocked",
            "items": [lock_busy_item(session)],
            "recovery": None,
        }
    try:
        classes = read_classes(session.open_pinless())
        recovery = {"ran": session.journal_recovery is not None, "clean": not dpkg_audit()}
        return {
            "schema_version": SCHEMA_VERSION,
            "status": "done",
            "items": [],
            "recovery": recovery,
            **apply_policy(session, classes),
        }
    finally:
        apt_pkg.pkgsystem_unlock()


def action_files(session):
    """The pin file as `policy` would write it from what dpkg has now, read only: `dotsteward e2e`
    holds the file there to it. The same decision as apply_policy."""
    classes = read_classes(session.open_pinless())
    pin_path = os.path.join(session.real_parts, PIN_FILE)
    text = None
    if session.gated and (classes["kernel"] is not None or classes["nvidia"] is not None):
        keep_nvidia = classes["nvidia"] is None and bool(dpkg_audit()) and NVIDIA_GLOB in read_text(pin_path)
        text = installed_pin(classes, keep_nvidia=keep_nvidia)
    return {"schema_version": SCHEMA_VERSION, "pin": {"path": pin_path, "text": text, "header": PIN_HEADER}}


def dpkg_environment():
    """No question reaches a person: the child has no terminal to ask on."""
    os.environ["DEBIAN_FRONTEND"] = "noninteractive"
    os.environ["APT_LISTCHANGES_FRONTEND"] = "none"
    os.environ["UCF_FORCE_CONFFOLD"] = "1"
    os.environ.setdefault("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")


def dpkg_options():
    """A changed configuration file stays as it is; the new one lands next to it as .dpkg-dist."""
    apt_pkg.config.set("Dpkg::Options::", "--force-confdef")
    apt_pkg.config.set("Dpkg::Options::", "--force-confold")
    apt_pkg.config.set("APT::Get::AutomaticRemove", "false")


def dpkg_binary():
    return apt_pkg.config.find_file("Dir::Bin::dpkg", "/usr/bin/dpkg")


def dpkg_admin_dir():
    return os.path.dirname(apt_pkg.config.find_file("Dir::State::status"))


def dpkg_audit():
    done = subprocess.run(
        [dpkg_binary(), f"--admindir={dpkg_admin_dir()}", "--audit"], capture_output=True, text=True, check=False
    )
    return done.stdout.strip()


def journal_dirty():
    """Whether the journal of dpkg holds updates: of a dpkg that runs now, or of one that was killed."""
    directory = os.path.join(dpkg_admin_dir(), "updates")
    try:
        return any(name.isdigit() for name in os.listdir(directory))
    except OSError:
        return False


def configure_all(env=None):
    """`dpkg --configure -a`. Without its own lock (ENV) dpkg takes the lock or stops right away."""
    dpkg_environment()
    done = subprocess.run(
        [dpkg_binary(), "--configure", "-a", "--force-confdef", "--force-confold"],
        env=env,
        stdin=subprocess.DEVNULL,
        check=False,
    )
    return done.returncode


def take_lock(session):
    """The lock of dpkg, waiting as long as the request allows; False when others keep it. apt holds
    the lock back from a journal of a killed dpkg, and only dpkg itself reads that journal: dpkg
    takes the lock for this one call, and stops at once if a running dpkg has it after all."""
    apt_pkg.config.set("DPkg::Lock::Timeout", str(session.request.get("lock_timeout", DEFAULT_LOCK_TIMEOUT)))
    try:
        apt_pkg.pkgsystem_lock()
        return True
    except (apt_pkg.Error, SystemError) as error:
        session.lock_error = str(error)
    if not journal_dirty():
        return False
    before = dpkg_audit()
    session.journal_recovery = {"audit_before": before, "status": configure_all()}
    apt_pkg.config.set("DPkg::Lock::Timeout", "0")
    try:
        apt_pkg.pkgsystem_lock()
    except (apt_pkg.Error, SystemError) as error:
        session.lock_error = str(error)
        return False
    return True


def dpkg_rows():
    """(status abbreviation, name) of every package dpkg knows."""
    done = subprocess.run(
        [
            dpkg_binary() + "-query",
            f"--admindir={dpkg_admin_dir()}",
            "-W",
            "-f=${db:Status-Abbrev} ${binary:Package}\\n",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    return [tuple(line.split()) for line in done.stdout.splitlines() if len(line.split()) == 2]


def half_removed():
    """Installed packages whose selection says they go: what a removal that was killed leaves, and
    what a later dselect, aptitude or `dpkg --remove --pending` would still act on."""
    return sorted(name for abbrev, name in dpkg_rows() if abbrev[0] in "rp" and abbrev[1] not in "nc")


def unconfigurable():
    """Packages dpkg stays unable to configure after `--configure -a`; an unpack starts these over only
    when a person has looked at why."""
    return sorted(name for abbrev, name in dpkg_rows() if abbrev[1] in "FWt")


def run_recovery(session):
    """`dpkg --configure -a` under the lock, when dpkg was stopped half way, with the selections of a
    removal that was killed taken back first: dpkg leaves such a package alone otherwise. A package
    left half unpacked stays in the audit: the plan after this unpacks it again."""
    dpkg_environment()
    journal = session.journal_recovery
    halves = half_removed()
    before = dpkg_audit()
    if not before and not journal and not halves:
        return {"ran": False, "clean": True}
    returncode = journal["status"] if journal else 0
    if before or halves:
        locked = {**os.environ, "DPKG_FRONTEND_LOCKED": "1"}
        apt_pkg.pkgsystem_unlock_inner()
        try:
            if halves:
                subprocess.run(
                    [dpkg_binary(), f"--admindir={dpkg_admin_dir()}", "--set-selections"],
                    input="".join(f"{name} install\n" for name in halves),
                    text=True,
                    env=locked,
                    check=False,
                )
            returncode = configure_all(locked)
        finally:
            apt_pkg.pkgsystem_lock_inner()
    after = dpkg_audit()
    session.fix_broken = bool(after)
    session.dpkg_broken = unconfigurable() if after else []
    audit_before = journal["audit_before"] if journal else before
    return {
        "ran": True,
        "clean": not after,
        "status": returncode,
        "audit_before": audit_before,
        "audit": after,
        "selections_restored": halves,
    }


def recovery_items(recovery):
    if not recovery.get("selections_restored"):
        return []
    message = "a removal was stopped half way: these stay installed, and no later tool acts on it"
    return [report_item("dpkg-selection-restored", packages=recovery["selections_restored"], message=message)]


def lock_busy_item(session):
    return report_item(
        "dpkg-lock-busy",
        pending=True,
        message=f"another package manager keeps the lock of dpkg: {session.lock_error}",
    )


def action_recover(session):
    require_root()
    if not take_lock(session):
        return {
            "schema_version": SCHEMA_VERSION,
            "status": "blocked",
            "items": [lock_busy_item(session)],
            "recovery": None,
        }
    try:
        recovery = run_recovery(session)
    finally:
        apt_pkg.pkgsystem_unlock()
    items = recovery_items(recovery)
    if not recovery["clean"]:
        message = "the next commit unpacks these again"
        items.append(report_item("dpkg-half-installed", audit=recovery["audit"], message=message))
    return {"schema_version": SCHEMA_VERSION, "status": "done", "items": items, "recovery": recovery}


def remove_old_scratch():
    """What a killed helper of root left in the temporary directory: nothing reads it again."""
    base = tempfile.gettempdir()
    for name in os.listdir(base):
        path = os.path.join(base, name)
        if not name.startswith(SCRATCH_PREFIX):
            continue
        try:
            stat = os.lstat(path)
            if stat.st_uid == os.geteuid() == 0 and time.time() - stat.st_mtime > SCRATCH_MAX_AGE_SECONDS:
                shutil.rmtree(path, ignore_errors=True)
        except OSError:
            pass


def require_root():
    if os.geteuid() != 0:
        raise HelperError("not-root", "this action changes the system and needs root")


def dpkg_dist_files():
    found = set()
    for directory, _subdirectories, names in os.walk("/etc"):
        found.update(os.path.join(directory, name) for name in names if name.endswith((".dpkg-dist", ".ucf-dist")))
    return found


def rollback_file_name(pkg, version):
    quoted = version.version.replace(":", "%3a")
    return f"{pkg.shortname}_{quoted}_{version.architecture}.deb"


def fill_rollback(session, cache, rows):
    """The packages of the driver and of its modules that this commit replaces, in their old versions:
    what a person needs to go back. A version the archive has dropped is named; the run goes on."""
    directory = session.request.get("rollback_dir") or ROLLBACK_DIR
    wanted = []
    for row in rows["upgrade"] + rows["remove"]:
        pkg = cache[row["name"]]
        if source_class(pkg.shortname, pkg.installed.source_name) in ROLLBACK_CLASSES:
            wanted.append((pkg, pkg.installed))
    answer = {"directory": directory, "kept": [], "missing": []}
    if not wanted:
        return answer
    os.makedirs(directory, mode=0o755, exist_ok=True)
    archives = apt_pkg.config.find_dir("Dir::Cache::Archives")
    keep = set()
    for pkg, version in wanted:
        name = rollback_file_name(pkg, version)
        target = os.path.join(directory, name)
        cached = os.path.join(archives, name)
        try:
            if os.path.exists(cached):
                partial = target + ".partial"
                shutil.copyfile(cached, partial)
                os.replace(partial, target)
            else:
                fetched = version.fetch_binary(directory, apt.progress.base.AcquireProgress())
                target = fetched or target
        except (OSError, ValueError, SystemError, apt_pkg.Error, apt.package.FetchError):
            pass
        if os.path.exists(target):
            keep.add(os.path.basename(target))
            answer["kept"].append(os.path.basename(target))
        else:
            answer["missing"].append(f"{pkg.name}={version.version}")
    # What the way back needs comes first: with a part of this set missing the last set stays.
    if not answer["missing"]:
        for name in os.listdir(directory):
            if name.endswith(".deb") and name not in keep:
                os.unlink(os.path.join(directory, name))
    return answer


def run_commit(cache):
    """The depcache of the plan, applied. Answers a status for the report."""
    fetch_progress = apt.progress.text.AcquireProgress(sys.stderr) if sys.stderr.isatty() else None
    try:
        if not cache.commit(fetch_progress or apt.progress.base.AcquireProgress(), apt.progress.base.InstallProgress()):
            return "dpkg-failed", "dpkg did not complete the transaction"
    except apt.cache.FetchFailedException as error:
        return "fetch-failed", str(error)
    except apt.cache.LockFailedException as error:
        return "blocked", str(error)
    except (SystemError, apt_pkg.Error) as error:
        return "dpkg-failed", str(error)
    return "committed", None


def action_commit(session):
    require_root()
    remove_old_scratch()
    dpkg_environment()
    dpkg_options()
    if not take_lock(session):
        return {
            "schema_version": SCHEMA_VERSION,
            "status": "blocked",
            "committed": False,
            "items": [lock_busy_item(session)],
            "newest_kernel": newest_kernel(read_classes(session.open_pinless())),
        }
    try:
        recovery = run_recovery(session)
        cache, plan = make_plan(session)
        plan["recovery"] = recovery
        plan["items"] = [*recovery_items(recovery), *plan["items"]]
        plan["committed"] = False
        # A refused plan changes nothing but it still repairs the pin file.
        plan["policy"] = apply_policy(session, session.classes)
        # Nothing of the plan happens in these two: the kernel stays as it is, with or without a module.
        plan["newest_kernel"] = newest_kernel(session.classes)
        if not plan["applicable"]:
            plan["status"] = "refused"
            return plan
        changes = plan["changes"]
        if not any(changes.values()):
            plan["status"] = "nothing"
            return plan
        plan["rollback"] = fill_rollback(session, cache, changes)
        before = dpkg_dist_files()
        status, message = run_commit(cache)
        plan["status"] = status
        plan["committed"] = status == "committed"
        if message:
            plan["message"] = message
        plan["dpkg_dist"] = sorted(dpkg_dist_files() - before)
        del cache
        # What dpkg has now: the pin follows it; apt-cache and the others never see a target.
        after = read_classes(session.open_pinless())
        plan["policy"] = apply_policy(session, after)
        plan["after"] = {"kernel": after["kernel"], "nvidia": after["nvidia"], "installed_pairs": after["pairs"]}
        plan["newest_kernel"] = newest_kernel(after)
        if plan["committed"]:
            left = dpkg_audit() or " ".join(half_removed())
            if left:
                plan["status"] = "dpkg-failed"
                plan["committed"] = False
                plan["message"] = left
        return plan
    finally:
        apt_pkg.pkgsystem_unlock()


ACTIONS = {
    "plan": action_plan,
    "analysis": action_analysis,
    "files": action_files,
    "policy": action_policy,
    "recover": action_recover,
    "commit": action_commit,
}
# The actions that must finish once they started: a signal is noted and reported.
PROTECTED = {"commit", "recover"}


def write_answer(answer, output, stream):
    text = json.dumps(answer, indent=2, sort_keys=True) + "\n"
    if output is None:
        stream.write(text)
        stream.flush()
        return
    directory = os.path.dirname(output) or "."
    handle, temporary = tempfile.mkstemp(prefix=".apt-helper-", dir=directory)
    with os.fdopen(handle, "w", encoding="utf-8") as written:
        written.write(text)
        written.flush()
        os.fsync(written.fileno())
    # Under sudo the caller reads its own answer; the file is private to it.
    uid = os.environ.get("SUDO_UID")
    gid = os.environ.get("SUDO_GID")
    if os.geteuid() == 0 and uid and gid:
        os.chown(temporary, int(uid), int(gid))
    os.replace(temporary, output)


def main(argv):
    arguments = argv[1:]
    output = None
    if "--output" in arguments:
        at = arguments.index("--output")
        if at + 1 >= len(arguments):
            sys.stderr.write("apt_helper: --output needs a file\n")
            return 2
        output = arguments[at + 1]
        del arguments[at : at + 2]
    if len(arguments) != 1 or arguments[0] not in ACTIONS:
        sys.stderr.write("usage: apt_helper.py ACTION [--output FILE] < request.json; ACTION: ")
        sys.stderr.write(", ".join(sorted(ACTIONS)) + "\n")
        return 2
    action = arguments[0]
    # What dpkg prints goes to standard error and the answer to its own stream.
    answer_stream = os.fdopen(os.dup(1), "w", encoding="utf-8")
    os.dup2(2, 1)
    if apt is None or apt_pkg is None:
        write_answer(
            {"schema_version": SCHEMA_VERSION, "error": {"code": "python3-apt-missing", "message": "no python3-apt"}},
            output,
            answer_stream,
        )
        return 1
    received = []
    if action in PROTECTED:

        def note(signum, _frame):
            name = signal.Signals(signum).name
            if name not in received:
                received.append(name)

        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, note)
    session = None
    try:
        request = json.load(sys.stdin)
        devnull = os.open(os.devnull, os.O_RDONLY)
        os.dup2(devnull, 0)
        os.close(devnull)
        session = Session(request)
        answer = ACTIONS[action](session)
        if received:
            answer["signals"] = received
    except HelperError as error:
        write_answer(
            {"schema_version": SCHEMA_VERSION, "error": {"code": error.code, "message": error.message}},
            output,
            answer_stream,
        )
        return 1
    except (apt_pkg.Error, SystemError, OSError, ValueError, KeyError) as error:
        write_answer(
            {
                "schema_version": SCHEMA_VERSION,
                "error": {"code": "apt-error", "message": f"{type(error).__name__}: {error}"},
            },
            output,
            answer_stream,
        )
        return 1
    finally:
        if session is not None:
            session.close()
    write_answer(answer, output, answer_stream)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
