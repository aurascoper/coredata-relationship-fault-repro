# Core Data: programmatic-model to-one relationship returns nil after save+re-fetch

A 100-line standalone SPM project reproducing a Core Data faulting issue: a
to-one relationship from a child entity (`Mention`) to its parent (`Entity`)
returns `nil` when accessed via KVC after save and re-fetch, **even though
the foreign key is persisted in the SQLite store**.

The other to-one direction on the same child (`Mention.memory`) works fine,
and the to-many traversals from the two parents (`Memory.mentions` and
`Entity.mentions`) also work.

## Environment

```
swift --version
  swift-driver version: 1.148.6 Apple Swift version 6.3.1
  (swiftlang-6.3.1.1.2 clang-2100.0.123.102)
  Target: arm64-apple-macosx26.0

sw_vers
  ProductVersion: 26.4.1
  BuildVersion:   25E253

Hardware: Apple M4
```

Reproduces in both `swift run -c debug Repro` and `swift run -c release Repro`.

## Setup (programmatic model)

```
Memory  --(to-many "mentions")---->  Mention  --(to-one "entity")-->  Entity
                                          |
                                          +--(to-one "memory")------>  Memory
                                                                         ^
                                                                         |
                                                  Memory  --(to-many)----+
```

Both to-many relationships have proper `inverseRelationship` set; both to-one
relationships do too.

## Output

```
[memory.mentions] type=Optional<Any> ns=1 set=1
[fetch by memory==row + prefetch entity] count=1
  mention.entity raw=Optional<Any> asObj=nil name=nil
```

- `memory.mentions` (to-many) traversal: **works** — returns the inserted Mention.
- Direct fetch of mentions by `memory == <row>` predicate: **works** — returns 1 row.
- `mention.entity` (to-one) traversal on the fetched Mention: **broken** —
  returns nil even with `returnsObjectsAsFaults = false` and
  `relationshipKeyPathsForPrefetching = ["entity"]`.

The persisted SQLite row for the mention has a non-null `ZENTITY` foreign key
column pointing at the entity's `Z_PK`; you can confirm with `sqlite3 <store>
'SELECT * FROM ZMENTION;'` (the printed store path).

## Trigger isolation

- Renaming `Entity.mentions` to `Entity.appearances` (so the two to-many
  relationships no longer share a name): **bug still reproduces**.
- The bug is on the `mention.entity` traversal specifically; `mention.memory`
  works in the same model.

I suspect the issue is in how the programmatic model wires the inverse for the
*second* to-one relationship on the child entity, or how Core Data decides
which to-one to fault when the destination is reached from KVC. I haven't
isolated it further.

## Workaround we use in the parent project

Add a redundant `entityID: UUID` attribute on the child entity, set it
alongside the relationship, and look up the parent by that UUID via a separate
fetch. Reliable and ~2 lines of extra code per write/read site, but it bypasses
the relationship rather than fixing it.

## Run

```sh
swift run Repro
# or
swift run -c release Repro
```

Both modes show the same broken `mention.entity` access.
