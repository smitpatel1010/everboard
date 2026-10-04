# Everboard

A macOS menu-bar app that puts your workday in one place:

- **GitLab:** your MRs, review requests, your reportees' MRs, pipelines and to-dos
- **Jira Cloud:** issues assigned to you and the saved filters you choose to watch
- **Notifications:** pipeline failures, new MRs from your team, mentions, Jira changes, with batching and quiet time during meetings
- **AI via the local `claude` CLI:**
  - a morning work brief
  - MR summaries and Jira digests
  - standups, weekly reports and team-health notes
  - meeting prep
- **World & Tech brief:** a personal news brief that learns from your 👍/👎
- **⌥Space command palette**, calendar integration, read-aloud, and a dashboard of your Claude token usage

It's native Swift/SwiftUI, uses about 40 MB of RAM, and stores all its data locally on your Mac.

> **Status:** personal project, works on macOS 14+ (tested on macOS 26). GitLab (gitlab.com or self-hosted) and Jira **Cloud** are supported. Jira Server/Data Center is not.

## Quick start

```bash
git clone <this repo> everboard && cd everboard
cp secrets.env.example secrets.env && chmod 600 secrets.env   # then fill in your values
make install                                                  # builds and installs ~/Applications/Everboard.app
open ~/Applications/Everboard.app
```

You need:
- macOS 14 or later, with the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is optional.
- Optionally, the [`claude` CLI](https://docs.claude.com/en/docs/claude-code), signed in, for the AI features. Everboard finds it automatically.
- Tokens for whichever services you use. Each is optional:

| Variable | What |
|---|---|
| `GITLAB_URL` | `https://gitlab.com` or your self-hosted GitLab (must be HTTPS) |
| `GITLAB_TOKEN` | Personal access token: `read_api` to view, `api` to approve, retry or comment |
| `JIRA_URL` | `https://<site>.atlassian.net` |
| `JIRA_EMAIL`, `JIRA_API_TOKEN` | Your Atlassian email and an [API token](https://id.atlassian.com/manage-profile/security/api-tokens) |
| `GITHUB_TOKEN` | Optional; raises rate limits for the "trending repos" news source |

These go in `secrets.env` at the project root. That file is git-ignored and kept at `chmod 600`. The same variables also work as environment variables when you run the CLI.

Then, in **Settings**:
1. **Team:** add your reportees' emails.
2. **Jira:** watch some filters.
3. **Web panels:** add your Jira dashboards.

## Documentation

All the docs are in [`docs/`](docs/README.md):

| Doc | Read it to… |
|---|---|
| [Getting started](docs/getting-started.md) | Install, configure and grant permissions |
| [Features guide](docs/features.md) | Learn what every screen, notification and AI feature does |
| [How it works](docs/architecture.md) | Follow the architecture, data flow and polling/diff engine |
| [Swift primer](docs/swift-primer.md) | Learn Swift, SwiftUI and SwiftPM using this codebase as examples |
| [Build & deploy](docs/build-and-deploy.md) | See how source becomes `Everboard.app` on your Mac, plus updating, signing and uninstalling |
| [AI & token usage](docs/ai-and-usage.md) | See how `claude` is called, what each feature sends, and the costs |
| [Security](docs/security.md) | Read the threat model, the safeguards, and where your data lives |
| [Extending](docs/extending.md) | Add a data source, a screen or a setting |
| [Troubleshooting](docs/troubleshooting.md) | Fix it when something doesn't work |

## Development

```bash
make test                                               # Swift Testing (no Xcode needed)
make build                                              # debug build
open build/Everboard.app --args --demo                  # sample data, no tokens needed
swift run everboard-cli check                           # verify tokens and connections
```

## License

MIT. See [LICENSE](LICENSE).
