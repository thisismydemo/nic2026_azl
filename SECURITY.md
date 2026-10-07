# Security

This repository holds conference material and example automation. It contains no real tenant, subscription or credential, and none should ever be added.

## Reporting a problem

If you find a suspected vulnerability or a leaked secret, report it privately through this repository's **Security** tab (Report a vulnerability). Do not open a public issue that contains a secret, a token or a tenant identifier.

## Using the automation safely

- Run it first in a non-production subscription or a lab.
- Anything that changes state needs `-Execute`; destructive actions default to `-WhatIf`.
- Secret values never go in a file. Fields that need one hold `keyvault://<vault>/<secret>` references that are resolved in memory.
- Copy the example environment files, replace every value, and keep your copies out of source control (the `.gitignore` in this repository excludes them).
