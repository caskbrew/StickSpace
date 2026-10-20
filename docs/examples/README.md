# Sharing a space through Git: examples

> **Status: design.** The Git sync described here is not implemented yet. The files in this folder show the
> proposed format (version 2) so the layout can be discussed before any code is written. Hostnames are fictional.

The snippets in this README are shortened; the files in the subfolders are exactly what the app writes
(a test re-encodes them and compares).

## The idea

A **space** is bound to a **space file** in a Git repository. The space file is always there. It holds the
space name and the list of its groups, in order. Each entry of that list is one of two things:

* **an inline group**: the group and its entities are written right in the space file;
* **a file reference**: `{ "file": "groups/grafana.json" }`: the group lives in its own file.

You can mix both in one space file, and a group can be moved from one form to the other at any time.

The binding has three values:

| | |
|---|---|
| `url`  | the repository, e.g. `git@gitlab.example.com:platform/infra-links.git` |
| `path` | the space file (or a group file) inside it, e.g. `platform/stickspace.json` |
| `ref`  | a branch to follow and push to, or a tag to pin a version (read-only) |

Paths in `{ "file": … }` are relative to the space file and must stay inside the repository.

## What can be imported

Two things, each pointing at one path in the repository:

| import | `path` points to | result |
|---|---|---|
| **Space** | a space file (`platform/stickspace.json`) | a new space with all its groups. Groups added to the file later appear on sync; removed ones disappear |
| **File** | a group file (`platform/groups/grafana.json`) | one group, added to a space you already have |

There is no "one inline group out of a space file": if you do not want a group from an imported space, **Hide**
it (a local choice, nothing is pushed). Hidden groups stay hidden when the file is synced again.

---

## Example 1: everything in the space file

```
infra-links/                     ← the GitLab repository
├── README.md
└── stickspace.json              ← binding path: "stickspace.json"
```

File: [`all-in-one/stickspace.json`](all-in-one/stickspace.json)

```json
{
  "version": 2,
  "name": "Platform team",
  "groups": [
    { "id": "…", "name": "Clusters",    "entities": [ … ] },
    { "id": "…", "name": "Grafana",     "entities": [ … ] },
    { "id": "…", "name": "Jira & docs", "entities": [ … ] }
  ]
}
```

Best for a small space: one file to read, review and copy. Two people editing *different* groups usually merge
cleanly because they touch different parts of the file.

---

## Example 2: big groups in their own files

```
infra-links/
└── platform/
    ├── stickspace.json          ← binding path: "platform/stickspace.json"
    └── groups/
        ├── clusters.json        ← group "Clusters"
        └── grafana.json         ← group "Grafana"
```

Files: [`split/stickspace.json`](split/stickspace.json), [`split/groups/`](split/groups/)

`stickspace.json`: the group order, plus one group ("Jira & docs") that is still inline:

```json
{
  "version": 2,
  "name": "Platform team",
  "groups": [
    { "file": "groups/clusters.json" },
    { "file": "groups/grafana.json" },
    { "id": "…", "name": "Jira & docs", "entities": [ … ] }
  ]
}
```

`groups/grafana.json`: one group, with its own `id` and `name`:

```json
{
  "version": 2,
  "id": "…",
  "name": "Grafana",
  "entities": [
    { "id": "…", "type": "link", "title": "Cluster overview",
      "url": "https://grafana.example.com/d/k8s-overview?var-env=prod", "tags": ["prod"] }
  ]
}
```

* The group's `id` (inline or in its file) is what ties it to the group in your space. **File names can be
  anything** and renaming a group never renames its file.
* Everyday edits (adding a link, a tag, a command) change only the group's own file, so people working on
  different groups never conflict. The space file changes only when a group is added, removed or reordered.
* Order is the order of the list: put new groups where you want them. No file-name prefixes needed.

In the app a group's menu will have **Keep in its own file**: it moves an inline group into a file next to the
space file (or back).

---

## One repository, several spaces

Every space has its own space file, so one repository can feed several spaces:

```
company-links/
├── platform/
│   ├── stickspace.json          ← space "Platform"
│   └── groups/ …
├── oncall/
│   ├── stickspace.json          ← space "On-call"
│   └── groups/ …
└── onboarding.json              ← space "Onboarding" (everything inline)
```

---

## What lives where

| Shared (in Git) | Yours only (never pushed) |
|---|---|
| space name, group list and order | custom groups (not in the space file) |
| group names, entities and their order | hidden, expanded, zoom, window position and width, pin, Single |
| entity type, text / url, title, tags | **Mask**: it only masks the display on your Mac |

Do not put secrets in a shared repository.

---

## The everyday flow

1. Someone adds a cluster. **Sync** in the space menu shows `Grafana: 1 update`; the background check (every
   few hours) may already have noticed.
2. You add the entity "Cluster overview · prod-us" with the tag `prod` in the app. The group is marked modified.
3. **Push**: the app creates the branch `stickspace/anna-2026-10-21` from `main`, commits only the changed file
   (`platform/groups/grafana.json`) and pushes it. On GitLab it also opens the merge request.
4. A teammate merges it. Everyone else gets the change on their next sync.

If the same entity was changed by two people, Sync asks per item: **Keep mine** or **Take theirs**.

What the diff of that push looks like:

```diff
--- a/platform/groups/grafana.json
+++ b/platform/groups/grafana.json
@@ -14,6 +14,16 @@
       ],
       "title" : "Cluster overview",
       "type" : "link",
       "url" : "https://grafana.example.com/d/k8s-overview?var-env=prod"
     },
+    {
+      "id" : "5d0c2e8e-7a45-4f0e-9d0b-0a6a4d9b7c11",
+      "tags" : [
+        "prod"
+      ],
+      "title" : "Cluster overview",
+      "type" : "link",
+      "url" : "https://grafana.example.com/d/k8s-overview?var-env=prod-us"
+    },
```

Files are written pretty-printed with sorted keys (exactly as in the example files here), so diffs stay this small.
