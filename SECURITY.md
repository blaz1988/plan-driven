# Security policy

`plan_driven` holds keys for an LLM provider, Cursor and GitHub, and merges pull requests into
your main branch, so its checks matter. If you find a way around them, we want to know.

## Supported versions

| Version | Supported |
| --- | :---: |
| 0.1.x | ✓ |

## Reporting a vulnerability

Please **don't** open a public issue. Email
[ivan.blazevic@rubycode.co](mailto:ivan.blazevic@rubycode.co) with:

- the gem version, and your Ruby and Rails versions;
- the steps that reproduce the problem;
- what it made possible.

You'll get a reply within three working days. Once a fix is released, we're happy to credit
you in the changelog.

## In scope

- A key written to disk, into the application, into documentation or into logs.
- A pull request merged without an approval, while a guard fails, or while CI is running.
- A phase skipped: tickets drafted from an unapproved plan, or agents started on unapproved
  tickets.
- Changes to the audit trail after the fact.
