# dotsteward upgrade

One command that brings this machine and the shared lock to the newest stable versions. It stops
only for what a person decides. Run it again at any time: every run works out what is left, so
there is no resume command. Your checkout is yours: `upgrade` never resets, cleans or adds anything
in it. The new pins are made, proven and published from a clone of its own, and the checkout only
fast-forwards, when it is clean.

```sh
dotsteward upgrade              # asks: tracked only, or everything
dotsteward upgrade --tracked    # what the instance tracks, then a look at the rest and one offer
dotsteward upgrade --all        # everything, no second question
dotsteward upgrade --plan       # what both would do; changes nothing and asks nothing
```

Never, in any mode: an OS release upgrade, sources moved to another release, `apt autoremove`, a
reboot. A reboot that is due is only said.

## The two modes

| | `--tracked` | `--all` |
| --- | --- | --- |
| On a terminal | apt for the tracked packages; the pins, the rebuild, own updaters, skills, E2E, publishing; then a read only analysis of everything else and "Update these too?" | all of that with apt as a whole, snap, flatpak and the tools the instance declares, in one run; no analysis and no second question |
| Without a terminal | also what no flag means: the sudo steps wait in `review.json`, the analysis runs and only its counts go there; no question | what runs as the user (the declared tools, flatpak `--user`); what needs sudo waits, exit 3 |

Updating something outside the tracked set does not track it: the intent, the shared lock and the
key of E2E stay as they are. The analysis stays on this machine in `<state>/upgrade/analysis.json`
(mode 0600) and is never published; `review.json` holds only its counts and the path.

## Other updaters

The framework knows the channels of the system: apt, snap and flatpak. Which other package managers
a person uses is theirs to say, so every other updater is a table in `workstation.toml`, and all of
them are treated alike:

```toml
[[upgrade.tools]]
name = "example-lang"
check = "example-lang outdated"
update = "example-lang update \"$@\""
skip_providers = "example-lang provides \"$1\""
```

Each command runs through `sh` in the checkout, as the user, with a limit of 60 seconds for `check`
and `skip_providers`. A tool that is not declared is not run.

| Key | Required | What it does |
| --- | --- | --- |
| `name` | yes | The name in the menu, the analysis (`channels.<name>`) and the report (`tool:<name>`). |
| `check` | yes | Read only: one line per thing that can be updated, the first word its name. Exit 0 is an answer, 127 means the tool is not on this machine, anything else is shown as an error, and in `--all` it is a failed step. |
| `update` | yes | Runs when `check` named something, with the names as arguments (`"$@"`). |
| `skip_providers` | no | Read only: given a name as `$1`, prints the commands it puts on PATH. A name that provides a tracked command stays out of `update` (`tracked-command`), and so does one this command fails for (`providers-unknown`). |

A tool that has several installs on one machine says so in its names, for example
`<install>/<package>`, and its commands read them back. Offline no declared command runs.

`--accept KEY` answers in advance; a terminal is needed in the end, and without one nothing moves:

| KEY | Meaning |
| --- | --- |
| `install:PACKAGE` | a package the apt plan refused for its risk class (constrained major, another kernel flavour, DKMS) |
| `series:kernel=X.Y` | move to this kernel series |
| `series:nvidia=N` | move to this NVIDIA series, such as `615-open` |
| `firmware` | answers the firmware question with yes for every device that can be updated |

## What you see

```text
Update what?
  1) Tracked only (then a read only analysis of the system and an offer)
  2) Everything (apt, snap, flatpak, example-lang, example-pkgs)
Choice [1/2]: 1
Firmware Example SSD: 1.0 -> 2.0. Apply? [y/N] y
[upgrade] the sudo window: apt first, sudo closes before the long builds
[sudo] password for you:
[upgrade] apt (tracked): 1 install, 2 upgrade
[upgrade] pins moved: flake_inputs.nixpkgs, agent_tools.codex.linux; the gate decides
[dotsteward] flake-check  ok (41s)
[upgrade] committed 15e283e055db next to the checkout; it goes out after a green E2E
[upgrade] rebuild of profile workstation
[upgrade] E2E of profile workstation
[upgrade] E2E is green
[dotsteward] published 15e283e055db to main without force
[upgrade] outside what is tracked, nothing changed:
[upgrade]   apt 1 packages (example-untracked)
[upgrade]   snap 1
Update these too? [y/N] n
[upgrade] ok: report <state>/runs/upgrade/2026-11-03T080000Z-1a2b.json
[upgrade] series-available: NVIDIA 615-open is available; recommended 595-open -> dotsteward upgrade --accept series:nvidia=615-open
[upgrade] reboot-required: a reboot is due when it suits you: 7.0.0-42-generic is installed, 7.0.0-38-generic runs. This command never reboots.
```

## What happens, in order

1. **The CLI of the tree.** Before it reads the configuration, `upgrade` compares its own revision
   with the one `flake.lock` pins, and goes on with `.dotsteward/cli.sh` when they differ, once
   (`DOTSTEWARD_UPGRADE_REEXEC`). A development CLI (`DOTSTEWARD_CLI`, `DOTSTEWARD_FRAMEWORK_OVERRIDE`,
   no `source-info`) stays. The same happens after a pull that moves the pin, with the mode of the menu.
2. **Lock and front work.** The instance lock; a busy lock is refused at once. The host file, the
   skill comparison and capture go out first. Then the fetch, and the fast-forward when the checkout
   is clean. A commit in the checkout that is not on the remote is yours: the run is refused and it
   stays. Uncommitted changes stop nothing but the fast-forward and a rebuild from the checkout. The
   questions come here: what other machines changed, one item at a time with the machine named (install,
   ask later, never on this machine: [machines.md](machines.md)), then the firmware list and its approval.
   Without a terminal every item is ask later, in `review.json` under `incoming`, and the run ends in 3.
3. **One sudo window before all Nix work.** `sudo -v`, `dpkg --configure -a` when dpkg was left half
   way, the pin file from what dpkg has (with its dpkg hook), the files of the active system
   components that are missing or differ (such as the drop-in of `apt-policy`, [the system
   method](component-contract.md#method-semantics)), the apt bridge when it is installed, `apt-get update`, the
   apt plan and its commit in one depcache, snap and flatpak with `--all`, then `sudo -k`. Sudo runs
   out during a long step: a terminal asks once more; if that fails too, the rest of the window waits
   in `review.json` and everything else still runs. The pin file of the gated classes
   (`/etc/apt/preferences.d/60dotsteward`) comes from this window only, and its dpkg hook keeps its
   pairs at what dpkg has after every dpkg run. `dotsteward e2e` holds it to what the apt engine
   writes from what dpkg has now (`core:apt-files`): a header or pairs that are not that is a
   finding; what the owner's own apt can bring (another rule after a purge or an install of a
   driver, a file the machine no longer wants) and a file not there yet are warnings.
4. **The pins, on the producer only, in a clone.** A clone of the fetched tip below
   `<state>/upgrade/work` takes `pins latest`, `pins apply`, the gate in the update scope and a
   commit. The producer is `[hosts] producer`; without one it is this machine when `hosts/` holds at
   most one file, and nobody when it holds more (the command to name one is said). A machine without a
   name or a profile moves no pins, since nothing could prove them there: the command to run is said.
   Flake inputs move at most once a week, counted from the publish of their last move: a red gate or a
   red E2E starts no week; a move of them whose way back is red too, which holds nothing, pauses them
   for a day. The floor of a deb package moves only to a version dpkg has installed for its package
   (`dpkg-query`, after the sudo window or the owner's own apt; the names of `packageNames` are
   aliases, and any one of them at the version is enough, as for the install); otherwise it waits
   as `deb-floors-wait`, with the version it wants and what is installed, since a floor above what
   dpkg has turns the E2E of the package red. A deb pin without `packageNames` (the evaluation
   refuses such a component) stays where it is, as `deb-floor-unknown`. Every other pin, such as an official binary of Codex,
   moves when upstream does. A framework that moved runs the writer once more with its own CLI, and
   the rest of the run with it too. What fails in one group of the writer is named, and what the
   others moved goes on. A pin whose upstream gives no answer (GitHub, a package index, a vendor
   site) while the remote does, or answers what cannot be used, waits for the next run: the step
   `pins-apply` is `partial` and names it (`unread`), never red; every query of `pins latest` and
   of the signature lookups is bounded by a timeout. Skills with a recorded transform are counted and left to `dotsteward-update`
   without holding the exit status; other items of the writer wait in `review.json` under
   `pins-apply`. The commit is kept as `refs/dotsteward/upgrade/waiting` until it is on the remote,
   and what it moved in `<state>/upgrade/waiting.json`. The clone keeps the local settings of the
   checkout (signing, a `pushurl`, credentials) and runs its hooks: `.git/hooks` or its
   `core.hooksPath`, as an absolute path.
5. **Own updaters.** A component that declares its updater (`claude update`) is asked to update
   when it has `updater = "self"`, or no `updater` and a method other than `deb`. Nothing else.
   `dotsteward context --json` shows both for each component: `updater` and `self_update`.
6. **Plugins are not updated here.** Marketplaces update themselves; `upgrade` starts no agent and
   changes no `autoUpdate`. It compares the installed trees with `<state>/plugins/scan.json`, scans
   what changed with `dotsteward scan --tree --secrets-only --redact`, and says so. A finding is a
   note and nothing is rolled back. The scan looks for the shape of real credentials; it does not
   look for prompt injection.
7. **Rebuild and E2E.** `rebuild --switch` when another tree, profile or place is active: from the
   clone while a commit waits, else from the checkout, if it is clean. E2E runs in full, unless its
   key is unchanged after a green run: the generation, the tree, the profile, the versions of the
   tracked packages and of the own updaters. Without a network or with a dirty checkout it runs
   without the repository checks. An apt commit that changed something always runs it. A dirty
   checkout behind what was published waits as `checkout-behind`, exit 3: the active generation is of
   the published commit, and the lock of the checkout is older. An E2E that ran green in this run
   checked what dpkg had when it started, the change of this run and the owner's own alike: that
   becomes the last observation of `dotsteward observe` (`<state>/observe/dpkg-snapshot.json`), so
   the observer this run woke has nothing to do, unless dpkg changed while E2E ran. A green E2E
   passes each tracked deb component with checks, at the versions dpkg had when it started; a red
   one fails those its findings name and passes none (`<state>/state/checks.json`), so the state
   record says `verified`, `red` or `unverified` with the version. A skipped E2E changes neither: a
   dependency the owner moved outside the key is still the observer's to check.
8. **Machine checks.** Whether a reboot is due: the newest installed kernel as the apt engine names
   it against `uname -r`, or `/run/reboot-required` when it is there. Its absence proves nothing. The
   engine also checks the module of that kernel, in every run. Only said.
9. **Publish, then the checkout follows.** `txn publish` from the clone, only after a green E2E of
   that tree on this machine. Then the checkout fast-forwards if it is clean, on the branch of the
   instance and without commits of its own; else `checkout-behind` says which and the command for it,
   and the checkout is not touched. Its tracking ref follows the remote. A last rebuild gives it the
   records of the machine back (the build comes from the store), and the clone goes; when that rebuild
   fails, approved firmware waits. Then the state of this machine goes to its branch `state/<name>`
   (`dotsteward state record`, [machines.md](machines.md)), so what this run moved reaches the
   remote; offline it waits here and the next run sends it. Then the analysis and the offer, a
   second record after the extra pass, firmware last, and the run report. What the extra pass or
   `--all` updates outside what is tracked is in no record: it never becomes tracked.

The profile of a run is the one of the machine (`hosts/<name>.toml`, `machine.json`, the last
rebuild), never `profiles.default`. A machine without a name is asked on a terminal, and gets
`machine-name-required` without one; without any profile the rebuild and E2E wait. Without a green E2E
nothing is published and no firmware is written.

Ctrl-C, SIGTERM and SIGHUP stop the whole run from every phase with status 130: no later step starts,
dpkg and a firmware write under way are left to finish, the clone goes, and the next run finishes.

## Kernel, NVIDIA and firmware

A same-series kernel and NVIDIA update moves with no question, as one unit, after the checks of the
apt engine. A new series is said with the command that takes it, and nothing waits for it:

```text
series-available: NVIDIA 615-open (noble-updates) is available; recommended 595-open -> dotsteward upgrade --accept series:nvidia=615-open
```

Firmware comes only on your word: listed first, asked device by device on a terminal, applied last
after a green E2E in a short sudo window of its own, on mains power only. Locked devices are named and
left to the vendor. Without a terminal it is never applied.

## When something goes red

- **The gate says no:** only what the red can be put on is held, never an innocent group. The run
  first gates the tip itself: red, the base is red, the item says so (`base_red`) and nothing is
  held. Else it gates the tip with all moves but a part of the groups of the writer, halves first,
  then finer: a part without which the gate is green narrows the search. One group left: it gets a
  hold, and the other groups, which the gate just passed, are committed and go on in the same run.
  Several left: the whole set is gated once more; green, everything goes on (the red was not there
  again); red, the others go on and those wait unheld, or, when every group is among them, the red
  cannot be attributed and every moved pin is held, exit 1. `gate-failed` names the group in
  `attribution` and the pins in `held`. At most 12 gates go into the search; each runs in a new
  clone of the tip against the tip, so another machine that publishes meanwhile changes nothing
  (the publish runs again on its tip, without what is held). When the framework moved, nothing is
  tried: every moved pin is held and the item says why. A gate that cannot judge its tree holds
  nothing.
- **The gate could not judge the tree:** another gate holds its lock, its preflight failed, its log
  says the disk is full or the memory ran out, or the network went away during it. `gate-failed`
  names it in `environment`; nothing is committed and nothing is held, and the next run tries again.
- **E2E ends without a result, or the rebuild is killed** (137, out of memory or from outside):
  `e2e-no-result` or a failed `rebuild`, exit 1. Nothing goes back and nothing is held; a waiting
  commit waits for the next run.
- **Holds:** each run names what is held (`held`). `dotsteward upgrade --retry-held` takes every hold
  back first, so those pins move again; the hold of a version that went red again comes back.
- **E2E or the rebuild is red after a move of this run:** the commit goes with its clone, the checkout
  never had it. A rebuild from the checkout returns the tree from before (from a clone of that tree
  when the checkout is dirty), official binaries that moved get their saved copy back, of the user
  services whose unit files are in a generation (`home-files/.config/systemd/user`, what Home Manager
  manages) one that only the moved generation has is stopped and one whose file it changed is
  restarted, unless the rebuild back restarted it (`systemctl --user`); a unit no generation has, and
  a session unit (D-Bus, the session manager, the audio server and the like, and `<name>-*` and
  `org.<name>.*` for each name of the desktop that runs in `XDG_CURRENT_DESKTOP` of this command
  and of the user manager, `systemctl --user show-environment`, so a run over SSH or from a timer
  protects the desktop too), is never touched; when neither environment names a desktop there (a
  session name in `XDG_SESSION_DESKTOP` or `DESKTOP_SESSION` is no unit prefix and counts as no
  name), only the `dotsteward*` and `home-manager*` units of the moved generation go back, and E2E checks the way back. When that is
  green, the pins of each red component, named by the pin of its binary or by its name in the pin
  id, get a local hold in `<state>/holds.json`, or all that moved when the checks name none; the writer leaves those pins until upstream calls something newer the
  latest, and each run says what is held. Item `red-held`, exit 3. If the way back is red too, the
  move is not what broke the machine: no hold, `e2e-red`, exit 1. A daemon that a command starts
  outside the user manager is not known here; its component stops it in an `agentsPost` hook, which
  the rebuild back runs.
- **A shared lock red on a machine that is not the producer (T19):** the checkout followed the
  remote, the rebuild of it moved the shared lock from the one of the active generation, and E2E
  went red. The shared lock is what only the producer moves: the pins of `versions.lock.json`, the
  inputs of `flake.lock`, the skills lock and the vendored skills, the npm locks
  (`packages/*/package-lock.json`) and the hash-pinned requirements. The generation of the commit
  before comes back from a clone, with the same care for user services and binaries, and a pypi
  environment goes back with its pin; E2E checks it. Green: the marker
  `<state>/upgrade/held-at.json` keeps this machine there (`consumer-held`, exit 3). The checkout
  follows the remote as always, but no commit with that lock is built or checked here. A later
  lock is tried only when it moves what the marker watches: the pins of the components that went
  red, or every path the red lock moved when none of them is a pin the producer can put back; a
  lock that moves only other things leaves the machine where it is, with no rebuild and no E2E.
  Each held run says `e2e: held, unverified` and waits (exit 3): nothing of that run, an apt commit
  or the extra pass included, is checked until the marker goes. When the red lock became active
  outside `upgrade` (a rebuild with `--ignore-hold`), the next run checks it with E2E: red, it goes
  back again; green, the marker goes. `dotsteward rebuild --switch` and `dotsteward apply
  --activate` refuse the red lock on a held machine. The state record carries the marker as `held`
  (the commit it went back to, the commit of the red lock, the components that went red), so the
  producer reads it from `state/<name>`. Red on the way back too: nothing is held, `e2e-red`, exit 1.
  A machine that becomes the producer drops its marker.
- **The producer answers a consumer:** each producer run fetches `state/*`. A record that holds a
  lock back is open while a pin of what went red there (an official binary and its companions, a
  pypi application, a deb download: the pins its components install) still has the value of the red
  lock, whatever else moved since. Such a pin goes back only to a value every consumer that holds it
  back was green on, and only when no other consumer's last green run (the commit it went back to,
  or the commit of a record whose last E2E passed) had a newer value; whatever the order of the
  names. It goes back through the writer, `pins apply --restore` ([pins-engine.md](pins-engine.md)):
  the whole group comes back from the commit the consumer was green on (a pypi pin with its
  hash-pinned requirements, a binary with its companions), so the lock stays consistent and `pins
  check` passes; a source the lock records as signed never comes back unsigned. A local hold at the
  red value keeps the writer from moving it there again while upstream calls it the latest
  (`consumer-red`). The commit message names what went back and for whom. That commit takes the
  gate, the rebuild and E2E of the producer and is published as any move of the lock. Everything
  else waits for a person (`consumer-red`, exit 3): consumers green on different values, a newer
  green consumer, and a red lock that moved no such pin (a flake input, the skills lock, an npm
  lock: these are never put back, the item names what moved). A record this producer cannot read,
  or a hold with fields it does not know, is said (`consumer-unread`) and never acted on. Only a
  named producer answers, and only a machine with a named producer goes back.
- **E2E is red with nothing of this run to go back to:** `e2e-red` names the checks, exit 1, no offer
  and no firmware. A red `deb` component gets the `sudo apt-mark hold` command to run if you want it.
  Nothing is written to the TOML; later releases carry holds in the machine layer.
- **The remote refuses the commit:** `publish-refused` says why, exit 1; the commit goes and the next
  run makes it again.
- **Another machine came first** (`txn publish` exits 3: the remote is not at the base, or the push
  was rejected as no fast-forward): no text is merged. After a random pause the writer runs again in
  a new clone of the new tip, with the rows this run researched (`pins latest` does not run again),
  then the gate, the rebuild and E2E against the new base, and the push again; a `replay` step says
  so. Only the tree that E2E checked goes out: when the rebuild of the new tree is killed or has no
  network, the commit waits for the next run (`publish-waits`). A refused fetch of the new tip is
  `publish-refused`. When the remote moved before each of three pushes, `publish-race`, exit 3: the commit goes and
  the next run makes it again.
- **No network:** network steps are skipped and the checks run, exit 6. A waiting commit stays and
  the next online run publishes it, or makes it again when the remote moved. A rebuild that fails
  because the network is gone holds nothing.

## Exit status and files

| Code | Meaning |
| --- | --- |
| 0 | done |
| 1 | a refusal or a failed step, a red that could not be rolled back among them |
| 2 | usage error, nothing ran |
| 3 | a decision or a sudo step waits: `review.json` |
| 4 | a privacy stop: nothing was published |
| 6 | no network: the network steps were skipped, the checks ran |
| 130 | Ctrl-C, SIGTERM or SIGHUP stopped the run: the report has `interrupted`, the next run finishes |

The heaviest one of a run is the status, in the order 4, 1, 3, 6, 0 ([exit-codes.md](exit-codes.md));
130 is the status of the process, and the report of that run says `failed` with `interrupted`.

| Path under `<state>` | What |
| --- | --- |
| `runs/upgrade/<run>.json` | the run report; `data.own_commits` names a commit waiting for the remote |
| `upgrade/work` | the clone of the run; it goes at the end of every run |
| `review.json` | what needs a person or an agent |
| `upgrade/analysis.json` | the read only analysis of the last tracked run |
| `upgrade/latest.json` | the rows of the last `pins latest` |
| `upgrade/nix-week.json` | when a move of the flake inputs was last published |
| `upgrade/e2e-key.json` | the key of the last green E2E |
| `upgrade/waiting.json` | what the waiting commit moved |
| `plugins/scan.json` | the digests of the installed plugin trees and the open findings |
| `holds.json` | the local holds |
| `upgrade/held-at.json` | on a consumer, the shared lock that went red here and the commit it went back to |
| `rollback/` | the official binaries saved while a move is not green yet |
| `apt-logs/` | what dpkg printed, the newest 20 |

Review codes of this command: `sudo-required`, `machine-name-required`, `profile-required`,
`remote-refused`, `gate-failed`, `e2e-no-result`, `checkout-behind` (a dirty checkout behind what
was published), `publish-waits`, `publish-race`, `publish-refused`, `red-held`, `e2e-red`,
`firmware-available`, `firmware-needs-ac`, the codes of the apt engine that wait (`apt-denied`,
`dpkg-lock-busy`, `module-missing`, `python3-apt-missing`), and of the skills (`origin-unknown`,
`skill-conflict`, `capture-blocked`). Notes that wait for nothing: `analysis`, `boot-space-low`,
`reboot-required`, `checkout-dirty`, `checkout-behind`, `held`, `consumer-held`, `consumer-red`,
`deb-floors-wait`, `deb-floor-unknown`, `pins-group-failed`, `series-available`, `phased-waiting`,
`module-loss`, `producer-unset`,
`producer-stale`, `plugin-scan-finding`, `plugin-scan-failed`, `firmware-locked`,
`firmware-needs-reboot`.

macOS has no apt, snap or firmware step; the rest runs the same.
