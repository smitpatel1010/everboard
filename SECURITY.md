# Security policy

Everboard holds API tokens for GitLab, Jira and GitHub and can send work data to the `claude` CLI, so security reports are taken seriously.

## Reporting a vulnerability

Please **don't open a public issue**. Use GitHub's private reporting instead: go to the repository's **Security** tab and choose **Report a vulnerability**.

Include what you found, how to reproduce it, and what an attacker could do with it. You should get a reply within a week. Once a fix is released, you'll be credited in the release notes unless you'd rather not be.

## Supported versions

Only the latest release on `main` gets security fixes.

## Scope

In scope, for example:

- tokens leaking to logs, the UI, notifications, the AI activity log or anywhere outside the secrets file
- tokens sent to a host other than the configured one, or over plain HTTP
- the AI privacy controls (redaction, pseudonymisation, masked terms) letting data through that they should block
- code execution through crafted GitLab/Jira/news content (HTML, markdown, links)

Out of scope: problems that need an attacker who already controls your user account, and issues in GitLab, Jira, GitHub or the `claude` CLI themselves.

See [docs/security.md](docs/security.md) for the threat model and existing safeguards.
