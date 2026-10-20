# Sharing a space through Git: examples

> **Status: design.** The Git sync described here is not implemented yet. The files in this folder show the
> proposed format (version 2) so the layout can be discussed before any code is written. Hostnames are fictional.

A **space** can be bound to a place in a Git repository. Everything in that place is shared; everything else in
the space stays yours (custom groups, hidden items, zoom, window size and so on).

A space is bound with three values:

| | |
|---|---|
| `url`  | the repository, e.g. `git@gitlab.example.com:platform/infra-links.git` |
| `path` | a **folder** (one file per group) or a **file** (all groups in one file) |
| `ref`  | a branch to follow and push to, or a tag to pin a version (read-only) |

Two layouts are supported. Pick one per binding.

---

## Variant A: a folder, one file per group

```
infra-links/                     ← the GitLab repository
├── README.md
└── platform/                    ← path of the binding: "platform/"
    ├── clusters.json            →  group "Clusters"
    ├── grafana.json             →  group "Grafana"
    └── jira-and-docs.json       →  group "Jira & docs"
```

Files: [`folder-per-group/`](folder-per-group/)

```json
{
  "version": 2,
  "id": "9062635e-c4db-489f-8968-8e4103fa0236",
  "name": "Grafana",
  "entities": [
    { "id": "948b6a34-…", "type": "link", "title": "Cluster overview",
      "url": "https://grafana.example.com/d/k8s-overview?var-env=prod", "tags": ["prod"] }
  ]
}
```

* One file is one group. Its `id` is what ties the file to the group in your space, so the **file name can be
  anything** and is never changed by renaming the group.
* A new file in the folder appears in every bound space as a new group on the next sync. A deleted file removes it.
* Groups are listed in file-name order unless you reorder them locally (that order is yours and is not pushed).
  To control the order for everyone, prefix the names: `01-clusters.json`, `02-grafana.json`.
* The space name is local (it defaults to the folder name).

**Why this layout:** two people editing different groups touch different files, so Git never has to merge them.
Adding a group is adding a file, which cannot conflict. Conflicts are possible only inside one group.

---

## Variant B: one file with all groups

```
infra-links/
├── README.md
└── stickspace.json              ← path of the binding: "stickspace.json"
```

File: [`single-file/stickspace.json`](single-file/stickspace.json)

```json
{
  "version": 2,
  "name": "Platform team",
  "groups": [
    { "id": "…", "name": "Clusters", "entities": [ … ] },
    { "id": "…", "name": "Grafana",  "entities": [ … ] }
  ]
}
```

* One file, easy to read in a merge request and to copy around.
* The space name comes from the file (`name`).
* Two people adding a group at the end of the list touch neighbouring lines, so Git may ask for a manual merge.
  Fine for a small team; the folder layout scales better.

---

## One repository, several spaces

Each binding has its own `path`, so a single repository can feed several spaces:

```
company-links/
├── platform/        ← space "Platform"   (folder, one file per group)
│   ├── clusters.json
│   └── grafana.json
├── oncall/          ← space "On-call"    (folder)
│   ├── runbooks.json
│   └── contacts.json
└── onboarding.json  ← space "Onboarding" (single file)
```

---

## What lives where

| Shared (in Git) | Yours only (never pushed) |
|---|---|
| group name, entities, their order | custom groups (not bound to any file) |
| entity type, text / url, title, tags | hidden, expanded, group order in the window |
| | zoom, window position and width, pin, Single |
| | **Mask**: it only masks the display on your Mac. Do not put secrets in a shared repo. |

---

## The everyday flow

1. A cluster is added. You right-click the space → **Sync** shows `Grafana: 1 update`, or the background check
   (every few hours) already did.
2. You edit the group in the app: add the entity "Cluster overview · prod-us", tag it `prod`.
   The group is marked as modified.
3. **Push**: the app creates the branch `stickspace/anna-2026-10-21` from `main`, commits only the changed file
   (`platform/grafana.json`) and pushes it. On GitLab it also opens the merge request.
4. A teammate approves and merges. Everyone else gets the change on their next sync.

If the same entity was edited by two people, Sync asks per item: **Keep mine** or **Take theirs**.

### What the diff of a push looks like

```diff
--- a/platform/grafana.json
+++ b/platform/grafana.json
@@ -12,6 +12,13 @@
       "tags": ["prod"]
     },
+    {
+      "id": "5d0c2e8e-7a45-4f0e-9d0b-0a6a4d9b7c11",
+      "type": "link",
+      "title": "Cluster overview",
+      "url": "https://grafana.example.com/d/k8s-overview?var-env=prod-us",
+      "tags": ["prod"]
+    },
```

Files are written pretty-printed with a stable key order, so diffs stay this small.
