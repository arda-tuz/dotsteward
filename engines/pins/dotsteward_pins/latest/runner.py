"""``dotsteward pins latest [--out FILE] [--all] [--jobs N]``.

1. Validate every ``pins.latest`` declaration of the manifest mirrors
   (exit 2 on an invalid one, before any query).
2. Plan: expand declarations against the lock files and add the built-in
   rows (core.py); a declared row replaces the built-in row with the same
   id, two declared rows with the same id are an error (exit 2); rows
   that follow other pins are dropped without --all.
3. Query in parallel (``--jobs`` workers): one job per row, or per group
   of rows sharing a compare. An ``UpstreamError`` becomes error rows of
   the job's ids; any other failure becomes one ``job-<n>`` error row
   (``n`` the job's index, ``details.ids`` the rows it was for) and never
   stops the other jobs.
4. Sort (model.sort_key), write the report to --out with the lock
   serializer, print the summary and the rows that need attention (every
   row with --all). Exit 1 when any row is an error, else 0.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime
from pathlib import Path

from ..instance import EngineError, Instance
from ..lockfile import dump, write_atomic
from . import core, model
from .adapters import PlanContext, Planned, Request, declared
from .upstream import Upstream, UpstreamError

PREFIX = "[pins]"

Job = list[Request]


def plan(instance: Instance, include_optional: bool) -> list[Planned]:
    adapters = [declared(declaration) for declaration in instance.declarations("latest")]
    locks = instance.load_locks()
    ctx = PlanContext(instance, locks)
    planned: list[Planned] = []
    owners: dict[str, str] = {}
    for adapter in adapters:
        for entry in adapter.plan(ctx):
            if entry.id in owners:
                raise EngineError(
                    f"duplicate latest row id {entry.id!r} (components {owners[entry.id]} and {entry.component})"
                )
            owners[entry.id] = entry.component
            planned.append(entry)
    planned += [entry for entry in core.rows(instance, locks) if entry.id not in owners]
    if not include_optional:
        planned = [entry for entry in planned if not entry.optional]
    return planned


def jobs_of(planned: list[Planned]) -> list[Job]:
    jobs: list[Job] = []
    groups: dict[object, Job] = {}
    for entry in planned:
        request = entry.request
        if request is None:
            continue
        key = request.adapter.group_key(request)
        if key is None:
            jobs.append([request])
        elif key in groups:
            groups[key].append(request)
        else:
            groups[key] = [request]
            jobs.append(groups[key])
    return jobs


def run_job(job: Job, upstream: Upstream) -> list[model.Row]:
    first = job[0]
    try:
        if len(job) > 1 or first.adapter.group_key(first) is not None:
            return first.adapter.fetch_group(job, upstream)
        return first.adapter.fetch(first, upstream)
    except UpstreamError as error:
        return [request.error(str(error)) for request in job]


def research(planned: list[Planned], workers: int) -> list[model.Row]:
    rows = [entry.row for entry in planned if entry.row is not None]
    jobs = jobs_of(planned)
    upstream = Upstream()
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(run_job, job, upstream): index for index, job in enumerate(jobs)}
        for future in concurrent.futures.as_completed(futures):
            index = futures[future]
            try:
                rows.extend(future.result())
            except Exception as error:  # every job is reported on its own
                ids = [request.id for request in jobs[index]]
                rows.append(model.error_item(f"job-{index}", "error", str(error) or repr(error), ids=ids))
    rows.sort(key=model.sort_key)
    return rows


def run(instance: Instance, args: argparse.Namespace) -> int:
    planned = plan(instance, args.all)
    researched = model.researched_at(datetime.datetime.now(datetime.UTC))
    rows = research(planned, args.jobs)
    report = model.report(rows, researched)
    if args.out:
        try:
            write_atomic(Path(args.out), dump(report))
        except OSError as error:
            raise EngineError(f"cannot write {args.out}: {error.strerror or error}") from error
    attention = sum(row["status"] in model.ATTENTION for row in rows)
    print(f"{PREFIX} Researched at {researched}: {len(rows)} items, {attention} need attention")
    for row in rows:
        if args.all or row["status"] in model.ATTENTION:
            print(model.line(row))
    return 1 if any(row["status"] == "error" for row in rows) else 0
