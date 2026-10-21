# Git sync: decisions

Examples of the layouts are in [`docs/examples`](../examples/README.md). This file fixes what is built and how.

## Vocabulary

**space** (window) → **group** (a list) → **entity** (one text or link). Code types are still `StickGroup`, `Stick`, `Block`.

## File format (version 2)

* **Group file**: `{ "version": 2, "id", "name", "entities": [ … ] }`.
* **Space file**: `{ "version": 2, "name", "groups": [ <inline group> | { "file": "<relative path>" } ] }`.
  The space file always exists; its list is the group order.
* **Entity**: `{ "id", "type": "text" | "link", "text" | "url", "title"?, "tags"? }`.
* All ids are UUIDs made by the app. Output is pretty-printed with sorted keys, so diffs stay small.
* The paste/copy Import and Export use the same format. Version 1 (`sticks` / `sections`) is still read.

## What can be imported from Git

* **Space**: path of a space file → a new space with all its groups. New groups appear on sync, removed ones go away.
* **File**: path of a group file → one group added to an existing space.

There is no "one inline group out of a space file": hide the groups you do not want (a local choice).

## Export to Git (the way in)

The Export window has two tabs, JSON (copy) and GIT. GIT publishes **custom** groups so that others can import them:

* **Space**: writes a space file with the space's visible custom groups, inline or (option) each in its own file under
  `groups/`. A space that is already linked to Git, and groups that already come from Git, are not exported: use Push.
* **Group**: writes one group file at the given path.
* Masked entities and hidden groups are left out. A file that already exists with different content is never overwritten.
* The files go to a new branch from the chosen branch (a merge request on GitLab); *direct push* writes straight to it.
* Afterwards the exported groups are **linked** to the new files, so Sync and Push work on them like on imported ones.
  Until the merge request is merged the files are not on the branch yet: that state is remembered
  (`awaitingMerge`), Sync reports "waiting for a merge request" instead of treating the groups as deleted, and the
  background check does not call it an update. When the files appear, the next sync clears the flag.
* After the merge, a teammate imports it (Import → GIT). The ids are the same ones the exporter has, so the exporter
  cannot import it a second time.

## What is shared and what is local

Shared (in Git): space name, group list and order, group names, entities (type, text/url, title, tags) and their order.

Local only: custom groups, hidden, expanded, zoom, window position and width, pin, Single, group order in the window.

**Masked entities never leave the Mac.** An entity that is masked and not in the shared version is local-only: it is not
pushed and sync leaves it alone. (A shared entity that you mask keeps syncing; masking is then only how you see it.)

## Sync

* Manual **Sync**, plus a background `git fetch` at launch and every 3 hours. The check only marks "updates
  available"; nothing is applied until Sync.
* Three-way merge by uuid: **base** (the shared version at the last sync, stored with the group), **local**, **remote**.
  * only one side changed → take it;
  * both changed the same entity → **yours is kept**, the group stays *modified*, and the sync report says so.
    *Revert* on a group or an entity restores the shared version (that is "take theirs");
  * deleted on one side and edited on the other → the edit wins;
  * deleted upstream and untouched locally → deleted; deleted upstream but edited locally → the group becomes custom.
* Order: the remote order, unless only you reordered, then yours. Entities added on either side are kept.

## Push

* Only groups that differ from their base are pushed. Custom groups are never pushed.
* The app syncs first, then writes the changed files on a new branch `stickspace/<user>-<date>` from `ref`, commits with
  your `git config` identity and pushes. On GitLab the push options open a merge request; elsewhere the branch is pushed
  and the app shows the URL. **Direct push** to `ref` is an option per source.
* A tag `ref` is read-only (no push).
* Pushing never changes the base. After the merge request is merged, the next sync sees the same content on both sides
  and moves the base forward.

## Git itself

The system `git` is used (`/usr/bin/git`, Homebrew paths); there is no hard dependency. Your ssh agent and credential
helper work as usual; an optional ssh key can be set per source (`-o IdentitiesOnly=yes`). Prompts are disabled
(`GIT_TERMINAL_PROMPT=0`, `BatchMode`), so a missing credential is an error message, never a hang.
Clones live in `~/Library/Application Support/Stickspace/remotes/`.
