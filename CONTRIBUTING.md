# Contributing to Everboard

Thanks for helping out. Bug reports, fixes, new data sources and doc improvements are all welcome.

## Set up

You need macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is optional.

```bash
make build                               # debug build
make test                                # Swift Testing, no Xcode needed
make app && open build/Everboard.app --args --demo   # sample data, no tokens needed
```

`--demo` fills every screen with made-up data, so you can work on the UI without a GitLab or Jira account. For the real thing, see [Getting started](docs/getting-started.md).

New to Swift? [docs/swift-primer.md](docs/swift-primer.md) walks through the language using this codebase. [docs/architecture.md](docs/architecture.md) and [docs/extending.md](docs/extending.md) explain where things go.

## Making a change

1. Open an issue first for anything bigger than a small fix, so we can agree on the approach.
2. Keep pull requests focused: one feature or fix per PR.
3. Add or update tests in `Tests/EverboardCoreTests` for logic in `EverboardCore`. Views in `EverboardMac` don't need tests, but a screenshot in the PR helps.
4. Match the style of the surrounding code. There's no formatter config; keep lines readable and comments short.
5. Update the docs in `docs/` when you change behaviour, settings or setup steps.
6. Run `make test` and `make leakcheck` before you push.

## Keep real data out

Everboard talks to people's work systems, so the repository must never contain anyone's real details.

- **Configuration comes from the environment.** Hosts, emails and tokens are read from `secrets.env` or environment variables (see [`secrets.env.example`](secrets.env.example)). Never hard-code an organisation's URL, name or account.
- **Use placeholder data** in tests, demo data and docs: `example.com`, `gitlab.example`, `acme`, `PROJ-123`, made-up names.
- **Run `make leakcheck`** (or `make hooks` once, to run it on every commit). It scans what you're about to commit for token formats, home-directory paths, the hosts and email from your own `secrets.env`, and any extra terms you list in a git-ignored `.leakcheck` file (your company name, internal hostnames, teammates' names).
- Screenshots in issues and PRs should use `--demo` data.

## Reporting bugs

Use the bug report template. Include your macOS version, how you installed Everboard, and the output of `swift run everboard-cli check` with tokens and hostnames removed.

Security problems: please follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
