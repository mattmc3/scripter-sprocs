# Contributing

Developer notes that don't belong in the README releated to contributing to this
project.

## A note on the use of global temp tables

An INSERT-EXEC cannot be nested, which means that whomever calls these procs
cannot use that technique if it's done inside the proc. So, when system tables
are queried across databases, global temp tables are used instead of INSERT-EXEC
of dynamic SQL to leave the caller of these procs full flexibility to do awesome
things.

## Bumpversion

This is how incrementing the version comments in the SQL files are managed. This
project uses semantic versioning.

### Install
`pip install bumpversion`

```
# Examples
bumpversion major
bumpversion minor
bumpversion patch
bumpversion patch --allow-dirty
```
