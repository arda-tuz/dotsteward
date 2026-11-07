# What another machine changed

The repository always moves forward. What lands on this machine depends on the user's answer, one item at a time: install it here, ask later, or never on this machine. This reference is the conversation about those items. Nothing here commits by hand: the commands do what the answer says.

## When

- `dotsteward upgrade` left `incoming` items in `review.json` (no terminal could ask), or the user asks what other machines changed.
- A hook never asks about this: hooks stay off the network, so the question comes with the next update.

## Steps

1. Look at what waits:

   ```bash
   dotsteward incoming --json
   ```

   This brings a clean checkout forward and prints `{machine, items}`. Each item has `id`, `kind` (`skill`, `plugin`, `component`), `change` (`new`, `changed`, `removed`), `name`, `by` (the machine that made the change, `null` for an unknown machine), `when`, and the commands `show` and `answer`. The same items are in `review.json` under the code `incoming`. Exit 3 only means that questions wait; the rest of the machine is fine.

   `dotsteward incoming list --json` gives the same list without a fetch, and a machine without a name has no items: `dotsteward host init` names it.

2. For each item, read what it is about and tell the user in plain words which machine did what and what an install would change here:

   ```bash
   dotsteward incoming show <id>
   ```

3. Ask the user about each item. Never answer for the user, and never assume an answer from an earlier item.

| The user says | Run | What happens |
| --- | --- | --- |
| Install it (or, for `removed`, remove it) | `dotsteward incoming answer <id> --install` | A skill or plugin lands at once, a changed own skill is backed up first; a `removed` skill is backed up and removed here; a component is activated by the next `dotsteward upgrade` or rebuild, and the command says so |
| Ask later | nothing | Nothing is stored, the same question comes with the next update, and nothing of the item is installed |
| Never on this machine | `dotsteward incoming answer <id> --never` | The answer goes to `hosts/<this machine>.toml` in a commit of its own, without force, and holds after a reinstall under the same name; without a network it holds here and a later run publishes it. A copy that is here stays and is no longer tracked |

4. Report what was installed, what stays a question and what is declined, and name the machines.

## Rules

- A change of an item the user changed locally too is no item here: it is a conflict, `dotsteward skills status` shows it and `dotsteward skills resolve` answers it.
- Something meant for other machines (`machines`, or `tags` of a component that this machine does not carry) is never an item. Do not bring it up or install it by hand.
- `--never` on a component is refused when this machine then no longer evaluates (another component needs it). Say which one needs it; the choice stays with the user.
- Pins, hashes, third-party skill updates and every other change of the repository take no question: the next rebuild applies them.
- Do not edit `hosts/*.toml`, `known.json` or `base.json` by hand.
