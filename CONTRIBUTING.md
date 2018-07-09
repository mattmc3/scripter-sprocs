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

```bash
# Examples
bumpversion major
bumpversion minor
bumpversion patch
bumpversion patch --allow-dirty
```

## Submitting an issue / PR

If you believe that the SQL being generated is not up to snuff, please by all
means open an issue. A couple of things to keep in mind:

1. If there's a script_table.sql issue, please include the DDL to create an
   example table that shows the problem. That way, I can recreate it.
2. If you submit a PR, please follow the established coding conventions for
   this project. We all get opinionated about or SQL, and I am no different. It's
   not the 70s. There's no reason to SHOUTCASE our SQL anymore (if there ever
   really was).
