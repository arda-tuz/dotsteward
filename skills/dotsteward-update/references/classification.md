# Classifying a request

Classify every request before the first write. The class decides which skill does the work.

| Class | Definition | Route |
| --- | --- | --- |
| personal | Expressible by changing instance files: `workstation.toml`, the lock files, `home.nix`, `components/`, `agent/`, skill overlays, the settings buffer, instance tests and instance docs. | `dotsteward-maintain`, or `dotsteward-update` for a full version refresh |
| framework | Changes behaviour or text shipped by the framework: the CLI, the engines, the gate, catalog components, framework skills, the template or framework docs. | `dotsteward-contribute` |
| mixed | Both. | `dotsteward-contribute` first (it ends with an instance upgrade to the new framework release), then `dotsteward-maintain` on the upgraded instance |

## Tie-breakers

- A preference only this user wants is personal when the component contract can express it: a configuration value, an overlay or a private component.
- A defect any user would hit is framework.
- An application outside the catalog is personal: it becomes a private component. Proposing it for the catalog is a separate, explicit framework request.
- Ask the user only when "for everyone or only for me" is unclear.

## Installed framework files

Editing installed framework files in place is forbidden. The next rebuild replaces them from the pinned framework release, so a framework change always goes through `dotsteward-contribute`.
