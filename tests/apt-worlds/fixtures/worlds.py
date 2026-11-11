"""Synthetic apt worlds for tests/apt-worlds and tests/container.

A world is a dpkg status file and a local repository with the suites of a release,
shaped like the real records of Ubuntu kernels and NVIDIA drivers: the same names,
Source fields, Depends and Provides, so the engine meets what it meets on a machine.
Nothing here describes a machine. It runs under the system's python3 (3.10 on Ubuntu
22.04) with the standard library only.

    worlds.py list
    worlds.py build NAME ROOT [--codename NAME] [--debs]
    worlds.py installed NAME            name=version per line, what the base state holds

`build` leaves ROOT/apt.conf for APT_CONFIG (a rootless apt with its own status file,
lists and caches), or with --debs real packages and ROOT/sources.base.list and
ROOT/sources.world.list for a disposable container, where dpkg installs them.
"""

from __future__ import annotations

import copy
import hashlib
import os
import shutil
import subprocess
import sys

MAINTAINER = "Example Maintainer <maintainer@example.invalid>"
RELEASE_DATE = "Thu, 01 Jan 2026 00:00:00 UTC"
MACHINE_ID = "0123456789abcdef0123456789abcdef"
FLAVOUR = "generic-hwe-24.04"
DEFAULT_CODENAME = "noble"
# A suite of a world is written with this placeholder for the code name of the release.
RELEASE = "{codename}"
UPDATES = "{codename}-updates"
SECURITY = "{codename}-security"
PROPOSED = "{codename}-proposed"
BACKPORTS = "{codename}-backports"
PPA = "ppa-graphics-drivers"
VENDOR = "{codename}-vendor"


def rec(name, version, source, **fields):
    """One package record; the keyword names are the fields of a Packages stanza."""
    record = {"name": name, "version": version, "source": source, "arch": "amd64", "component": "main"}
    record.update(fields)
    return record


def upstream(version):
    return version.split("-")[0]


def kernel_abi(abi, version, src="7.0", phased=None, base="generic", suite=None):
    """The packages of one kernel ABI: their Source is not gated, the meta package pulls them."""
    head = f"{abi}-{base}"
    fields = {"phased": phased}
    if suite:
        fields["suite"] = suite
    return [
        rec(
            f"linux-image-{head}",
            version,
            f"linux-signed-hwe-{src}",
            depends=f"linux-base, linux-modules-{head}",
            conflicts=f"linux-image-unsigned-{head}",
            provides="linux-image",
            **fields,
        ),
        rec(
            f"linux-modules-{head}",
            version,
            f"linux-hwe-{src}",
            depends=f"linux-main-modules-zfs-{head}",
            **fields,
        ),
        rec(
            f"linux-main-modules-zfs-{head}",
            version,
            f"linux-main-signed-hwe-{src}",
            depends=f"linux-image-{head} | linux-image-unsigned-{head}",
            provides="zfs-modules",
            **fields,
        ),
        rec(f"linux-headers-{head}", version, f"linux-hwe-{src}", depends=f"linux-hwe-{src}-headers-{abi}", **fields),
        rec(f"linux-hwe-{src}-headers-{abi}", version, f"linux-hwe-{src}", **fields),
        rec(f"linux-tools-{head}", version, f"linux-hwe-{src}", depends=f"linux-hwe-{src}-tools-{abi}", **fields),
        rec(f"linux-hwe-{src}-tools-{abi}", version, f"linux-hwe-{src}", **fields),
    ]


def kernel_meta(abi, version, src="7.0", flavour=FLAVOUR, phased=None, base="generic", source=None):
    """The three level meta package: linux-generic-hwe -> linux-image-generic-hwe -> linux-image-<abi>."""
    head = f"{abi}-{base}"
    source = source or f"linux-meta-hwe-{src}"
    return [
        rec(
            f"linux-{flavour}",
            version,
            source,
            depends=f"linux-image-{flavour} (= {version}), linux-headers-{flavour} (= {version})",
            recommends=f"linux-tools-{head}, ubuntu-kernel-accessories",
            phased=phased,
        ),
        rec(
            f"linux-image-{flavour}",
            version,
            source,
            depends=f"linux-image-{head}, linux-modules-{head}, linux-main-modules-zfs-{head}, linux-firmware",
            phased=phased,
        ),
        rec(f"linux-headers-{flavour}", version, source, depends=f"linux-headers-{head}", phased=phased),
    ]


def kernel(abi, version, src="7.0", phased=None):
    return kernel_meta(abi, version, src, phased=phased) + kernel_abi(abi, version, src, phased=phased)


def module_abi(n, abi, version, up, src="7.0", kind="-open", phased=None, base="generic"):
    """The module of one ABI: it fixes the upstream version of the driver."""
    head = f"{abi}-{base}"
    return [
        rec(
            f"linux-modules-nvidia-{n}{kind}-{head}",
            version,
            f"linux-restricted-signatures-hwe-{src}",
            depends=(
                f"linux-image-{head} | linux-image-unsigned-{head}, "
                f"nvidia-kernel-common-{n} (<= {up}-1), nvidia-kernel-common-{n} (>= {up})"
            ),
            phased=phased,
        )
    ]


def module_meta(n, abi, version, driver_version, src="7.0", kind="-open", phased=None, base="generic", flavour=FLAVOUR):
    """The module meta package: it provides the DKMS package the driver depends on."""
    up = upstream(driver_version)
    return [
        rec(
            f"linux-modules-nvidia-{n}{kind}-{flavour}",
            version,
            f"linux-restricted-modules-hwe-{src}",
            depends=f"linux-modules-nvidia-{n}{kind}-{abi}-{base} (= {version}), nvidia-kernel-common-{n} (>= {up})",
            provides=f"nvidia-dkms-{n}{kind} (= {driver_version}), nvidia-prebuilt-kernel",
            phased=phased,
        )
    ]


def module(n, abi, version, driver_version, src="7.0", kind="-open", phased=None):
    up = upstream(driver_version)
    return module_meta(n, abi, version, driver_version, src, kind, phased) + module_abi(
        n, abi, version, up, src, kind, phased
    )


def driver(n, version, kind="-open", phased=None, component="restricted", dkms=True):
    """The driver stack of one series, with the versioned firmware package and i386 libraries."""
    up = upstream(version)
    source = f"nvidia-graphics-drivers-{n}"
    same = {"phased": phased, "component": component}
    records = [
        rec(
            f"nvidia-driver-{n}{kind}",
            version,
            source,
            depends=(
                f"libnvidia-gl-{n} (= {version}), "
                f"nvidia-dkms-{n}{kind} (<= {up}-1), nvidia-dkms-{n}{kind} (>= {up}), "
                f"nvidia-kernel-common-{n} (<= {up}-1), nvidia-kernel-common-{n} (>= {up}), "
                f"nvidia-kernel-source-{n}{kind} (= {version}), libnvidia-compute-{n} (= {version}), "
                f"nvidia-utils-{n} (= {version})"
            ),
            recommends=f"libnvidia-gl-{n}:i386 (= {version}), libnvidia-compute-{n}:i386 (= {version}), nvidia-prime",
            **same,
        ),
        rec(
            f"nvidia-kernel-common-{n}",
            version,
            source,
            depends=f"nvidia-firmware-{n}-{up}",
            provides=f"nvidia-kernel-common, nvidia-kernel-common-{n}-{up}",
            conflicts="nvidia-kernel-common",
            replaces="nvidia-kernel-common",
            **same,
        ),
        rec(f"nvidia-firmware-{n}-{up}", version, source, **same),
        rec(
            f"nvidia-kernel-source-{n}{kind}",
            version,
            source,
            provides="nvidia-kernel-source",
            conflicts="nvidia-kernel-source",
            replaces="nvidia-kernel-source",
            multi_arch="foreign",
            **same,
        ),
        rec(
            f"nvidia-utils-{n}",
            version,
            source,
            depends=f"nvidia-kernel-common-{n}-{up}, libnvidia-compute-{n} (>= {up})",
            provides="nvidia-utils",
            conflicts="nvidia-utils",
            replaces="nvidia-utils",
            **same,
        ),
        rec(f"libnvidia-common-{n}", version, source, multi_arch="foreign", **same),
    ]
    for library, extra in (
        (f"libnvidia-compute-{n}", {}),
        (
            f"libnvidia-gl-{n}",
            {"provides": "libnvidia-gl", "conflicts": "libnvidia-gl", "replaces": "libnvidia-gl"},
        ),
    ):
        needs = f"libnvidia-common-{n}"
        if library.startswith("libnvidia-gl"):
            needs += f", libnvidia-compute-{n} (>= {up})"
        records.append(
            rec(
                library,
                version,
                source,
                depends=f"nvidia-kernel-common-{n}-{up}, {needs}",
                multi_arch="same",
                **extra,
                **same,
            )
        )
        records.append(rec(library, version, source, depends=needs, multi_arch="same", arch="i386", **extra, **same))
    if dkms:
        records.append(
            rec(
                f"nvidia-dkms-{n}{kind}",
                version,
                source,
                depends=(
                    f"dkms, nvidia-kernel-source-{n}{kind} (<= {up}-1), nvidia-kernel-source-{n}{kind} (>= {up}), "
                    f"nvidia-kernel-common-{n} (<= {up}-1), nvidia-kernel-common-{n} (>= {up})"
                ),
                provides="nvidia-dkms-kernel",
                conflicts="nvidia-dkms-kernel",
                replaces="nvidia-dkms-kernel",
                multi_arch="foreign",
                **same,
            )
        )
    return records


def transitional(n, version, to, kind="-open"):
    """A retired series: the same name and Source, a Depends on the next series."""
    return [
        rec(
            f"nvidia-driver-{n}{kind}",
            version,
            f"nvidia-graphics-drivers-{n}",
            depends=f"nvidia-driver-{to}{kind}",
            component="restricted",
        )
    ]


def support():
    """What the kernel and driver records depend on, from Sources that are not gated."""
    return [
        rec("linux-base", "4.5ubuntu9+24.04.2", "linux-base"),
        rec("linux-firmware", "20240318.git3b128b60-0ubuntu2.26", "linux-firmware"),
        rec("linux-libc-dev", "6.8.0-147.147", "linux"),
        rec("linux-tools-common", "6.8.0-147.147", "linux"),
        rec("nvidia-prime", "0.8.17.2", "nvidia-prime"),
        rec("dkms", "3.0.11-1ubuntu13", "dkms"),
        rec("ubuntu-kernel-accessories", "1.1", "ubuntu-kernel-accessories"),
        rec("example-lib", "1.0-1", "example-lib"),
        rec("example-tracked", "1.0-1", "example-tracked"),
        rec("example-other", "1.0-1", "example-other"),
    ]


K38 = "7.0.0-38.38~24.04.4"
K42 = "7.0.0-42.42~24.04.1"
K44 = "7.0.0-44.44~24.04.1"
K46 = "7.0.0-46.46~24.04.1"
K74 = "7.4.0-5.5~24.04.1"
D99 = "595.99.02-0ubuntu0.24.04.1"
D99B = "595.99.02-0ubuntu0.24.04.2"
D106 = "595.106.01-0ubuntu0.24.04.1"
D615 = "615.71.09-0ubuntu0.24.04.2"
UP99 = upstream(D99)
UP106 = upstream(D106)


def kernel_installed():
    """The kernels of a machine: the newest with a meta package, the fallback before it."""
    return kernel("7.0.0-42", K42) + kernel_abi("7.0.0-38", K38)


def nvidia_installed():
    """The fallback kernel has its module at `...+1`, a string its kernel does not have."""
    return module("595", "7.0.0-42", K42, D99) + module_abi("595", "7.0.0-38", K38 + "+1", UP99)


BASE_INSTALLED = kernel_installed() + nvidia_installed() + driver("595", D99, dkms=False) + support()
# The records the base state needs from the repository, plus the real DKMS package of the series.
ARCHIVE = BASE_INSTALLED + [r for r in driver("595", D99) if r["name"].startswith("nvidia-dkms-")]
NO_NVIDIA = kernel_installed() + support()
# The meta package of the release pocket has another Source and a lower version.
RELEASE_POCKET = kernel_meta("6.8.0-31", "6.8.0-31.31", "6.8", source="linux-meta") + kernel_abi(
    "6.8.0-31", "6.8.0-31.31", "6.8"
)


def world(new=(), *, installed=None, archive=None, suites=None, description=""):
    """A world: NEW lands in -updates next to the archive; SUITES adds records to other suites."""
    repo = {RELEASE: list(RELEASE_POCKET), UPDATES: list(archive if archive is not None else ARCHIVE) + list(new)}
    for suite, records in (suites or {}).items():
        repo.setdefault(suite, [])
        repo[suite].extend(records)
    return {
        "description": description,
        "installed": installed if installed is not None else BASE_INSTALLED,
        "repo": repo,
    }


NEW_KERNEL_44 = kernel("7.0.0-44", K44)


def _hooked(records, name, stages=("preinst", "postinst")):
    """A copy of RECORDS with a package whose maintainer scripts wait while a flag exists and fail
    while another exists: a test can stop dpkg at a known point of a commit. They also keep what
    the pin file says while dpkg runs."""
    records = copy.deepcopy(records)
    hook = """#!/bin/sh
state=/run/dotsteward-test
[ -d "$state" ] || exit 0
cp /etc/apt/preferences.d/60dotsteward "$state/pin-during-commit" 2>/dev/null
if [ -e "$state/hang-STAGE" ]; then
  : >"$state/in-STAGE"
  while [ -e "$state/hang-STAGE" ]; do sleep 0.1; done
  echo "example hook: STAGE goes on"
fi
[ ! -e "$state/fail-STAGE" ]
"""
    for record in records:
        if record["name"] == name:
            record["scripts"] = {stage: hook.replace("STAGE", stage) for stage in stages}
    return records


def _failing_package():
    record = rec("example-broken", "1.0-1", "example-broken")
    record["scripts"] = {"postinst": "#!/bin/sh\n[ ! -e /run/dotsteward-test/fail-unrelated ]\n"}
    return record


def _controls(*names):
    """Packages outside the gated classes, for the updates that keep flowing."""
    return [rec(name, "2.0-1", name) for name in names]


CONTROLS = ("example-lib", "example-other", "example-tracked")


def _bind_records():
    """A kernel with its module, a new upstream driver: all that a user of libapt must not move."""
    return (
        _hooked(kernel("7.0.0-44", K44), "linux-image-7.0.0-44-generic")
        + module("595", "7.0.0-44", K44, D106)
        + driver("595", D106)
    )


def _general_availability(records):
    """The kernel of the release itself: Sources without -hwe-<series>, meta package without -hwe."""
    renamed = {
        "linux-meta-hwe-6.8": "linux-meta",
        "linux-signed-hwe-6.8": "linux-signed",
        "linux-hwe-6.8": "linux",
        "linux-main-signed-hwe-6.8": "linux-main-signed",
        "linux-restricted-modules-hwe-6.8": "linux-restricted-modules",
        "linux-restricted-signatures-hwe-6.8": "linux-restricted-signatures",
    }
    return [{**record, "source": renamed.get(record["source"], record["source"])} for record in records]


def _ga_kernel(abi, version):
    return kernel_meta(abi, version, "6.8", flavour="generic") + kernel_abi(abi, version, "6.8")


def _ga_module(abi, version):
    return module_meta("595", abi, version, D99, "6.8", flavour="generic") + module_abi(
        "595", abi, version, UP99, "6.8"
    )


GA_INSTALLED = [
    *_general_availability(_ga_kernel("6.8.0-147", "6.8.0-147.147") + _ga_module("6.8.0-147", "6.8.0-147.147")),
    *driver("595", D99, dkms=False),
    *support(),
]


def _driver_respin(extra=()):
    return driver("595", D106) + module("595", "7.0.0-42", K42 + "+1", D106) + list(extra)


def _driver_615():
    """A newer series in multiverse, with its module for the installed kernel (as on a real archive)."""
    return driver("615", D615, component="multiverse") + module("615", "7.0.0-42", K42, D615)


def _module_with_conflict():
    records = module("595", "7.0.0-44", K44, D99)
    records[-1]["conflicts"] = "linux-modules-nvidia-595-open-7.0.0-38-generic"
    return records


WORLDS = {
    # ---- what the real history of a machine holds
    "no-change": world(description="nothing new: the gated classes stay"),
    "same-string": world(
        NEW_KERNEL_44 + module("595", "7.0.0-44", K44, D99),
        description="kernel and module at the same string",
    ),
    "plus-n": world(
        NEW_KERNEL_44 + module("595", "7.0.0-44", K44 + "+1", D99),
        description="the module meta is a +N respin of the kernel version",
    ),
    "no-module": world(NEW_KERNEL_44, description="the kernel arrives without a module"),
    "driver-respin": world(
        _driver_respin(),
        description="an upstream driver move with a respin for this ABI only: -38 loses its module",
    ),
    "driver-respin-both": world(
        _driver_respin(module_abi("595", "7.0.0-38", K38 + "+2", UP106)),
        description="the same with a respin for the fallback ABI too: it keeps its module",
    ),
    "driver-ahead": world(driver("595", D106), description="the driver is published before any module accepts it"),
    "packaging-bump": world(
        driver("595", D99B),
        description="a packaging bump inside the range of the module moves alone",
    ),
    "kernel-and-driver": world(
        NEW_KERNEL_44 + module("595", "7.0.0-44", K44, D106) + driver("595", D106),
        description="a new kernel whose module needs a new driver: both move, the older ABIs lose theirs",
    ),
    "transitional": world(
        transitional("595", "595.200.01-0ubuntu0.24.04.1", "615") + _driver_615(),
        description="the series is retired: same name, same Source, a Depends on the next series",
    ),
    "phase-module": world(
        NEW_KERNEL_44 + module("595", "7.0.0-44", K44, D99, phased=0),
        description="the kernel is not phased, the module meta is at 0%: the set waits",
    ),
    "phase-kernel": world(
        kernel("7.0.0-44", K44, phased=0) + module("595", "7.0.0-44", K44, D99),
        description="the kernel is phased, the module meta is not: the set waits",
    ),
    "new-series": world(
        kernel("7.4.0-5", K74, "7.4") + module("595", "7.4.0-5", K74, D99, "7.4"),
        description="a new series of the kernel on the same binary name",
    ),
    # ---- more of the real shapes
    "module-ahead": world(
        NEW_KERNEL_44 + module("595", "7.0.0-44", K44, D106),
        description="the module of the new kernel needs a driver that is not in the archive yet",
    ),
    "series-gone": world(
        archive=[r for r in ARCHIVE if not r["source"].startswith("nvidia-graphics-drivers-")],
        description="the archive has no version of the driver at all any more",
    ),
    "phase-security": world(
        kernel("7.0.0-44", K44, phased=0) + module("595", "7.0.0-44", K44, D99, phased=0),
        suites={SECURITY: NEW_KERNEL_44 + module("595", "7.0.0-44", K44, D99)},
        description="the same versions in -security: phasing does not apply there",
    ),
    "newest-without-module": world(
        NEW_KERNEL_44
        + module("595", "7.0.0-44", K44, D99)
        + kernel("7.0.0-46", K46)
        + driver("595", D106)
        + module_abi("595", "7.0.0-38", K38 + "+1", UP99),
        description="the newest kernel has no module yet: the newest one that has moves, the driver waits",
    ),
    "proposed-and-ppa": world(
        suites={
            PROPOSED: kernel("7.0.0-46", K46) + module("595", "7.0.0-46", K46, D99),
            PPA: driver("595", "595.120.01-0ubuntu0.24.04.1"),
        },
        description="-proposed and a PPA have newer versions: neither is stable",
    ),
    "backports-kernel": world(
        suites={BACKPORTS: kernel("7.0.0-46", K46) + module("595", "7.0.0-46", K46, D99)},
        description="-backports is not stable either",
    ),
    "no-nvidia": world(
        NEW_KERNEL_44,
        installed=NO_NVIDIA,
        archive=NO_NVIDIA,
        description="a machine without the NVIDIA class: the kernel moves alone",
    ),
    "no-classes": world(
        installed=support(),
        archive=support(),
        description="no kernel and no driver: a container, a machine without gated classes",
    ),
    "ga-kernel": world(
        _general_availability(_ga_kernel("6.8.0-149", "6.8.0-149.149") + _ga_module("6.8.0-149", "6.8.0-149.149")),
        installed=GA_INSTALLED,
        archive=GA_INSTALLED,
        description="the kernel of the release itself: no version and no name of a flavour is data",
    ),
    "dkms-machine": world(
        NEW_KERNEL_44 + driver("595", D106),
        installed=kernel_installed() + driver("595", D99) + support(),
        archive=kernel_installed() + driver("595", D99) + support(),
        description="the driver through DKMS, no module meta: kernel and driver move on their own",
    ),
    "new-series-kernel-only": world(
        kernel("7.4.0-5", K74, "7.4"),
        description="a new kernel series without a module of the installed NVIDIA series",
    ),
    "new-series-nvidia": world(
        _driver_615(),
        description="a new NVIDIA series with its module for the installed kernel",
    ),
    "tracked": world(
        [
            rec("example-tracked", "2.0-1", "example-tracked"),
            rec("example-other", "2.0-1", "example-other"),
            rec("example-lib", "2.0-1", "example-lib", phased=0),
            rec("linux-libc-dev", "6.8.0-149.149", "linux"),
        ],
        description="an upgrade of a tracked package, an untracked one and a phased one",
    ),
    "tracked-phased": world(
        [
            rec("example-tracked", "2.0-1", "example-tracked", phased=0),
            rec("example-other", "2.0-1", "example-other"),
        ],
        description="a tracked package whose upgrade is phased: a mark must not pierce the phase",
    ),
    "tracked-phased-dependency": world(
        [
            rec("example-tracked", "2.0-1", "example-tracked", depends="example-lib (>= 2.0)"),
            rec("example-lib", "2.0-1", "example-lib", phased=0),
        ],
        description="a tracked package that needs a phased library: the mark must not pull it in",
    ),
    # ---- the refusal list
    "constrained-major": world(
        [
            rec("sampledbms-postgis-scripts", "3.7.0+dfsg-1", "postgis", depends="sampledbms-19-postgis-3-scripts"),
            rec("sampledbms-19-postgis-3-scripts", "3.7.0+dfsg-1", "postgis", depends="sampledbms-19"),
            rec("sampledbms-19", "19.1-1", "sampledbms-19"),
            rec("sampledbms-16", "16.16-1", "sampledbms-16"),
            rec("sampledbms-17", "17.12-1", "sampledbms-17"),
        ],
        installed=[
            *BASE_INSTALLED,
            rec("sampledbms-postgis-scripts", "3.6.4+dfsg-1", "postgis"),
            rec("sampledbms-16", "16.15-1", "sampledbms-16"),
            rec("sampledbms-17", "17.11-1", "sampledbms-17"),
        ],
        description="a floating meta package reaches for another major version of a constrained server",
    ),
    # ---- the constraints and holds of the instance (P10)
    "constraints": world(
        [
            rec("sampledbms-16", "16.16-1", "sampledbms-16"),
            rec("sampledbms-client", "16.16-1", "sampledbms-common"),
            rec("sampledbms-client", "17.2-1", "sampledbms-common"),
            rec("sampledbms-16-ext-3", "3.8.0-1", "sampledbms-ext"),
            rec("sampledbms-17", "17.12-1", "sampledbms-17"),
            rec("sampletool", "1.9-1", "sampletool"),
            rec("sampletool", "2.5-1", "sampletool"),
            rec("sampleapp", "1.5-1", "sampleapp"),
            rec("sampleapp", "2.0-1", "sampleapp"),
            rec("sampleheld", "1.5-1", "sampleheld"),
            rec("samplenew", "16.2-1", "samplenew"),
            rec("samplenew", "17.0-1", "samplenew"),
        ],
        installed=[
            *BASE_INSTALLED,
            rec("sampledbms-16", "16.15-1", "sampledbms-16"),
            rec("sampledbms-client", "16.15-1", "sampledbms-common"),
            rec("sampledbms-16-ext-3", "3.7.0-1", "sampledbms-ext"),
            rec("sampledbms-17", "17.11-1", "sampledbms-17"),
            rec("sampletool", "2.4-1", "sampletool"),
            rec("sampleapp", "1.0-1", "sampleapp"),
            rec("sampleheld", "1.2-1", "sampleheld"),
        ],
        description="a constrained server, a package with its own versions, one the owner moved out of "
        "its constraint, another major the owner installed, a held package and one the owner moved past its hold",
    ),
    "new-flavour": world(
        [
            *kernel_meta("7.0.0-44", K44)[:1],
            rec(
                f"linux-image-{FLAVOUR}",
                K44,
                "linux-meta-hwe-7.0",
                depends="linux-image-7.0.0-44-generic, linux-modules-7.0.0-44-generic, "
                "linux-image-7.0.0-44-lowlatency, linux-firmware",
            ),
            kernel_meta("7.0.0-44", K44)[2],
            *kernel_abi("7.0.0-44", K44, base="lowlatency"),
            *kernel_abi("7.0.0-44", K44),
            *module("595", "7.0.0-44", K44, D99),
        ],
        description="the target kernel brings another flavour",
    ),
    "proposed-abi": world(
        kernel_meta("7.0.0-44", K44) + module("595", "7.0.0-44", K44, D99),
        suites={PROPOSED: kernel_abi("7.0.0-44", K44)},
        description="the meta package is stable, the kernel it needs only exists in -proposed",
    ),
    "dkms-pull": world(
        [
            *driver("595", D106),
            rec(
                f"linux-modules-nvidia-595-open-{FLAVOUR}",
                K42 + "+1",
                "linux-restricted-modules-hwe-7.0",
                depends="linux-modules-nvidia-595-open-7.0.0-42-generic (= " + K42 + "+1), "
                f"nvidia-kernel-common-595 (>= {UP106})",
                provides=f"nvidia-dkms-595-open (= {D99}), nvidia-prebuilt-kernel",
            ),
            *module_abi("595", "7.0.0-42", K42 + "+1", UP106),
        ],
        description="the module accepts the driver but does not provide its DKMS dependency: apt reaches for DKMS",
    ),
    "other-series-pull": world(
        [rec("example-tracked", "2.0-1", "example-tracked", depends="nvidia-driver-615-open"), *_driver_615()],
        description="an upgrade outside the classes asks for another NVIDIA series",
    ),
    "other-series-new": world(
        [
            rec("example-tracked", "2.0-1", "example-tracked", depends="nvidia-driver-700-open"),
            rec("nvidia-driver-700-open", "700.1-0ubuntu0.24.04.1", "nvidia-graphics-drivers-700"),
        ],
        description="an upgrade outside the classes pulls a driver of another series next to the installed one",
    ),
    "module-conflict": world(
        [*NEW_KERNEL_44, *_module_with_conflict()],
        description="the new module pushes out the module of an ABI that the driver still suits: no rule allows that",
    ),
    "held-package": world(
        [rec("example-tracked", "2.0-1", "example-tracked"), rec("example-other", "2.0-1", "example-other")],
        installed=[{**r, "held": r["name"] == "example-tracked"} for r in BASE_INSTALLED],
        description="a hold is honoured, and reported",
    ),
    "held-kernel": world(
        NEW_KERNEL_44 + module("595", "7.0.0-44", K44, D99),
        installed=[{**r, "held": r["name"] == f"linux-{FLAVOUR}"} for r in BASE_INSTALLED],
        description="a hold on the kernel meta package holds the whole set",
    ),
    "two-metas": world(
        [
            *kernel_meta("6.8.0-149", "6.8.0-149.149", "6.8", flavour="generic", source="linux-meta"),
            *kernel_abi("6.8.0-149", "6.8.0-149.149", "6.8"),
            *NEW_KERNEL_44,
            *module("595", "7.0.0-44", K44, D99),
        ],
        installed=BASE_INSTALLED
        + kernel_meta("6.8.0-147", "6.8.0-147.147", "6.8", flavour="generic", source="linux-meta")
        + kernel_abi("6.8.0-147", "6.8.0-147.147", "6.8"),
        archive=ARCHIVE
        + kernel_meta("6.8.0-147", "6.8.0-147.147", "6.8", flavour="generic", source="linux-meta")
        + kernel_abi("6.8.0-147", "6.8.0-147.147", "6.8"),
        description="a second kernel meta package: the newest is the one that moves, the other is named",
    ),
    "foreign-removal": world(
        [rec("example-tracked", "2.0-1", "example-tracked", conflicts="example-other")],
        description="an upgrade that removes a package of another Source",
    ),
    "same-source-removal": world(
        [
            rec(
                "libexample-new1t64",
                "2.0-1",
                "example-lib",
                conflicts="example-lib",
                replaces="example-lib",
                provides="example-lib (= 2.0-1)",
            ),
            rec("example-tracked", "2.0-1", "example-tracked", depends="libexample-new1t64"),
        ],
        description="a library transition: the old name goes, the new name of the same Source comes",
    ),
    "old-abi-conflict": world(
        [rec("example-tracked", "2.0-1", "example-tracked", conflicts="linux-tools-7.0.0-38-generic")],
        description="an upgrade removes a package of an old ABI: allowed unless that ABI is protected",
    ),
    # ---- real commits in a container
    "bind": world(
        [*_bind_records(), *_controls(*CONTROLS)],
        suites={SECURITY: [*_bind_records(), *_controls(*CONTROLS)]},
        description="new gated packages and control packages, in -updates and -security",
    ),
    # A package that has nothing to do with the classes and whose postinst fails while a flag exists.
    "broken-other": world(
        _bind_records(),
        installed=[*BASE_INSTALLED, _failing_package()],
        archive=[*ARCHIVE, _failing_package()],
        description="an unrelated package that dpkg cannot configure",
    ),
    "series-hooked-old": world(
        driver("615", D615, component="multiverse")
        + module("615", "7.0.0-42", K42, D615)
        + kernel("7.0.0-44", K44)
        + module("595", "7.0.0-44", K44, D99),
        installed=_hooked(BASE_INSTALLED, "nvidia-driver-595-open", ("prerm",)),
        archive=_hooked(ARCHIVE, "nvidia-driver-595-open", ("prerm",)),
        description="a series change that can stop in the prerm of the old driver",
    ),
    "series-hooked-new": world(
        _hooked(driver("615", D615, component="multiverse"), "nvidia-driver-615-open", ("preinst",))
        + module("615", "7.0.0-42", K42, D615)
        + kernel("7.0.0-44", K44)
        + module("595", "7.0.0-44", K44, D99),
        description="a series change that can stop in the preinst of the new driver",
    ),
    "series-keeps-fallback": world(
        _driver_615() + module_abi("615", "7.0.0-38", K38 + "+1", upstream(D615)),
        description="the new series has a module for the fallback kernel too",
    ),
    "bump-security": world(
        driver("595", D99B),
        suites={SECURITY: driver("595", D99B)},
        description="a packaging bump of the driver, also in -security: what a person may undo by hand",
    ),
    "no-module-installed": world(
        installed=kernel("7.0.0-44", K44)
        + kernel_abi("7.0.0-42", K42)
        + module("595", "7.0.0-42", K42, D99)
        + module_abi("595", "7.0.0-38", K38 + "+1", UP99)
        + kernel_abi("7.0.0-38", K38)
        + driver("595", D99, dkms=False)
        + support(),
        archive=ARCHIVE + kernel("7.0.0-44", K44),
        description="the newest installed kernel has no module, and the archive has none: nothing moves",
    ),
    "image-above-meta": world(
        _controls("example-lib"),
        installed=BASE_INSTALLED + kernel_abi("7.0.0-44", K44),
        archive=ARCHIVE + kernel_abi("7.0.0-44", K44),
        description="an image newer than the one the meta package names, installed by hand",
    ),
    "conffile": world(
        [
            rec(
                "example-conf",
                "2.0-1",
                "example-conf",
                files={"etc/example-conf.conf": "packaged 2\n"},
                conffiles=["/etc/example-conf.conf"],
            )
        ],
        installed=[
            *BASE_INSTALLED,
            rec(
                "example-conf",
                "1.0-1",
                "example-conf",
                files={"etc/example-conf.conf": "packaged 1\n"},
                conffiles=["/etc/example-conf.conf"],
            ),
        ],
        description="a configuration file changed here and in the new package",
    ),
    # ---- what a default-allow plan lets through
    "firmware-split": world(
        [
            rec(
                "linux-firmware",
                "20240318.git3b128b60.0ubuntu3.1",
                "linux-firmware",
                depends="linux-firmware-intel-graphics, linux-firmware-misc",
            ),
            rec("linux-firmware-intel-graphics", "20240318.git3b128b60-0ubuntu3.1", "linux-firmware-intel-graphics"),
            rec("linux-firmware-misc", "20240318.git3b128b60-0ubuntu3.1", "linux-firmware-misc"),
        ],
        description="linux-firmware split into new packages",
    ),
    "soname": world(
        suites={
            VENDOR: [
                rec("postgis-tool", "3.7.0-1", "postgis", depends="libgeos3.15.0, libgdal39"),
                rec("libgeos3.15.0", "3.15.0-1", "geos"),
                rec("libgdal39", "3.13.3+dfsg-2", "gdal", depends="libgeos3.15.0"),
            ]
        },
        installed=[
            *BASE_INSTALLED,
            rec("postgis-tool", "3.6.4-1", "postgis", depends="libgeos3.14.1"),
            rec("libgeos3.14.1", "3.14.1-1", "geos"),
        ],
        archive=[
            *ARCHIVE,
            rec("postgis-tool", "3.6.4-1", "postgis", depends="libgeos3.14.1"),
            rec("libgeos3.14.1", "3.14.1-1", "geos"),
        ],
        description="a soname transition in a vendor repository pulls new libraries",
    ),
}


def _suite_name(suite, codename):
    return suite.format(codename=codename)


def _stanza(record, *, installed, filename=None, size=1, sha256="0" * 64):
    lines = [f"Package: {record['name']}"]
    if installed:
        lines.append(f"Status: {'hold' if record.get('held') else 'install'} ok installed")
    lines += ["Priority: optional", "Section: misc", "Installed-Size: 1", f"Maintainer: {MAINTAINER}"]
    lines += [f"Architecture: {record['arch']}", f"Version: {record['version']}"]
    if record.get("multi_arch"):
        lines.append(f"Multi-Arch: {record['multi_arch']}")
    if not installed:
        lines += [f"Filename: {filename or 'pool/none.deb'}", f"Size: {size}", f"SHA256: {sha256}"]
    lines.append(f"Source: {record['source']}")
    for field, key in (
        ("Depends", "depends"),
        ("Recommends", "recommends"),
        ("Provides", "provides"),
        ("Conflicts", "conflicts"),
        ("Breaks", "breaks"),
        ("Replaces", "replaces"),
    ):
        if record.get(key):
            lines.append(f"{field}: {record[key]}")
    if record.get("phased") is not None and not installed:
        lines.append(f"Phased-Update-Percentage: {record['phased']}")
    lines.append(f"Description: synthetic {record['name']}")
    return "\n".join(lines) + "\n\n"


def _control(record):
    lines = [
        f"Package: {record['name']}",
        f"Version: {record['version']}",
        f"Architecture: {record['arch']}",
        f"Maintainer: {MAINTAINER}",
        f"Source: {record['source']}",
        # As in the stanza: apt takes a version whose Installed-Size differs for another version.
        "Installed-Size: 1",
    ]
    if record.get("multi_arch"):
        lines.append(f"Multi-Arch: {record['multi_arch']}")
    for field, key in (
        ("Depends", "depends"),
        ("Recommends", "recommends"),
        ("Provides", "provides"),
        ("Conflicts", "conflicts"),
        ("Breaks", "breaks"),
        ("Replaces", "replaces"),
    ):
        if record.get(key):
            lines.append(f"{field}: {record[key]}")
    lines.append(f"Description: synthetic {record['name']}")
    return "\n".join(lines) + "\n"


def _build_deb(record, pool, scratch):
    """A real empty package, with the Depends and Provides of its record."""
    name = f"{record['name']}_{record['version'].replace(':', '%3a')}_{record['arch']}.deb"
    path = os.path.join(pool, name)
    if not os.path.exists(path):
        tree = os.path.join(scratch, name)
        os.makedirs(os.path.join(tree, "DEBIAN"))
        with open(os.path.join(tree, "DEBIAN", "control"), "w", encoding="utf-8") as handle:
            handle.write(_control(record))
        for script, text in record.get("scripts", {}).items():
            script_path = os.path.join(tree, "DEBIAN", script)
            with open(script_path, "w", encoding="utf-8") as handle:
                handle.write(text)
            os.chmod(script_path, 0o755)
        for relative, text in record.get("files", {}).items():
            file_path = os.path.join(tree, relative)
            os.makedirs(os.path.dirname(file_path), exist_ok=True)
            with open(file_path, "w", encoding="utf-8") as handle:
                handle.write(text)
        if record.get("conffiles"):
            with open(os.path.join(tree, "DEBIAN", "conffiles"), "w", encoding="utf-8") as handle:
                handle.write("\n".join(record["conffiles"]) + "\n")
        subprocess.run(["dpkg-deb", "--root-owner-group", "-Zgzip", "-b", tree, path], check=True, capture_output=True)
        shutil.rmtree(tree)
    return path


def _write_suite(root, suite, records, codename, debs, origin):
    """dists/<suite> of the repository: Packages per component and architecture, and a Release file."""
    base = os.path.join(root, "repo", "dists", suite)
    pool = os.path.join(root, "repo", "pool")
    scratch = os.path.join(root, "repo", "scratch")
    stanzas = {}
    seen = set()
    for record in records:
        key = (record["name"], record["version"], record["arch"])
        if key in seen:
            continue
        seen.add(key)
        fields = {}
        if debs:
            os.makedirs(pool, exist_ok=True)
            path = _build_deb(record, pool, scratch)
            with open(path, "rb") as handle:
                data = handle.read()
            fields = {
                "filename": os.path.relpath(path, os.path.join(root, "repo")),
                "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            }
        stanzas.setdefault((record["component"], record["arch"]), []).append(_stanza(record, installed=False, **fields))
    sums = []
    components = sorted({component for component, _ in stanzas} | {"main"})
    for component in components:
        for arch in ("amd64", "i386"):
            directory = os.path.join(base, component, f"binary-{arch}")
            os.makedirs(directory, exist_ok=True)
            text = "".join(stanzas.get((component, arch), [])).encode("utf-8")
            with open(os.path.join(directory, "Packages"), "wb") as handle:
                handle.write(text)
            relative = f"{component}/binary-{arch}/Packages"
            sums.append(f" {hashlib.sha256(text).hexdigest()} {len(text)} {relative}")
    release = [
        f"Origin: {origin}",
        f"Label: {origin}",
        f"Suite: {suite}",
        f"Codename: {codename}",
        f"Date: {RELEASE_DATE}",
        "Architectures: amd64 i386",
        "Components: " + " ".join(components),
        "SHA256:",
    ]
    with open(os.path.join(base, "Release"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(release + sums) + "\n")
    return components


def _write_apt_conf(root):
    with open(os.path.join(root, "apt.conf"), "w", encoding="utf-8") as handle:
        handle.write(
            f'''Dir "{root}/";
Dir::State "var/lib/apt/";
Dir::State::status "{root}/var/lib/dpkg/status";
Dir::Cache "var/cache/apt/";
Dir::Etc "etc/apt/";
Dir::Etc::Parts "{root}/etc/apt/apt.conf.d/";
Dir::Etc::PreferencesParts "{root}/etc/apt/preferences.d/";
APT::Architecture "amd64";
APT::Architectures {{ "amd64"; "i386"; }};
Debug::NoLocking "true";
Acquire::Languages "none";
APT::Sandbox::User "";
APT::Machine-ID "{MACHINE_ID}";
'''
        )


def _source_line(root, suite, components):
    return f"deb [trusted=yes arch=amd64,i386] file:{root}/repo {suite} {' '.join(components)}\n"


def _origin_of(suite):
    if suite == PPA:
        return "LP-PPA-graphics-drivers"
    if suite == VENDOR:
        return "Example Vendor"
    return "Ubuntu"


def build(name, root, codename=DEFAULT_CODENAME, debs=False):
    spec = WORLDS[name]
    root = os.path.abspath(root)
    for directory in (
        "etc/apt/preferences.d",
        "etc/apt/apt.conf.d",
        "var/lib/dpkg",
        "var/lib/apt/lists/partial",
        "var/cache/apt/archives/partial",
        "repo",
    ):
        os.makedirs(os.path.join(root, directory), exist_ok=True)
    with open(os.path.join(root, "var/lib/dpkg/status"), "w", encoding="utf-8") as handle:
        handle.write("".join(_stanza(record, installed=True) for record in spec["installed"]))
    open(os.path.join(root, "var/lib/dpkg/available"), "w", encoding="utf-8").close()
    with open(os.path.join(root, "etc/machine-id"), "w", encoding="utf-8") as handle:
        handle.write(MACHINE_ID + "\n")
    lines = []
    for suite, records in spec["repo"].items():
        named = _suite_name(suite, codename)
        components = _write_suite(root, named, records, codename, debs, _origin_of(suite))
        lines.append(_source_line(root, named, components))
    if debs:
        base = "base"
        components = _write_suite(root, base, spec["installed"], codename, debs, "Example Base")
        with open(os.path.join(root, "sources.base.list"), "w", encoding="utf-8") as handle:
            handle.write(_source_line(root, base, components))
        with open(os.path.join(root, "sources.world.list"), "w", encoding="utf-8") as handle:
            handle.writelines(lines)
        shutil.rmtree(os.path.join(root, "repo", "scratch"), ignore_errors=True)
    with open(os.path.join(root, "etc/apt/sources.list"), "w", encoding="utf-8") as handle:
        handle.writelines(lines)
    _write_apt_conf(root)


def main(argv):
    if len(argv) >= 2 and argv[1] == "list":
        for name, spec in WORLDS.items():
            print(f"{name}\t{spec['description']}")
        return 0
    if len(argv) == 3 and argv[1] == "installed":
        for record in WORLDS[argv[2]]["installed"]:
            arch = f":{record['arch']}" if record["arch"] != "amd64" else ""
            print(f"{record['name']}{arch}={record['version']}")
        return 0
    if len(argv) >= 4 and argv[1] == "build":
        codename = DEFAULT_CODENAME
        debs = "--debs" in argv
        if "--codename" in argv:
            codename = argv[argv.index("--codename") + 1]
        build(argv[2], argv[3], codename, debs)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
