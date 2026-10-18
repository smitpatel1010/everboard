# Getting started

## 1. Prerequisites

| Need | Why | How |
|---|---|---|
| macOS 14 Sonoma or later | SwiftUI APIs used by the app | — |
| Xcode Command Line Tools | Swift compiler and macOS SDK | `xcode-select --install` (full Xcode works too) |
| `claude` CLI *(optional)* | All AI features | Install Claude Code and run `claude` once to sign in |
| GitLab, GitHub and/or Jira Cloud tokens *(optional)* | Work data | See below |

Without any tokens, the World & Tech news brief still works. You can also browse sample data with `--demo`.

## 2. Tokens (`secrets.env`)

```bash
cp secrets.env.example secrets.env
chmod 600 secrets.env
open -e secrets.env
```

- **GitLab.** In your avatar menu, go to **Preferences → Access tokens**. Create a token with the `read_api` scope, or `api` if you want the in-app actions (approve, retry pipeline, comment, mark to-do done). Set `GITLAB_URL` to `https://gitlab.com` or your company's GitLab. It must be HTTPS.
- **Jira Cloud.** Create a token at <https://id.atlassian.com/manage-profile/security/api-tokens>, then set `JIRA_URL=https://<site>.atlassian.net` and `JIRA_EMAIL`. Some organisations disable API tokens; if Jira returns 401/403, ask your admin.
- **GitHub.** Create a classic token at **Settings → Developer settings → Personal access tokens** with `repo` (or `public_repo` for public work only) and `notifications`. Set `GITHUB_URL=https://github.com`, or your GitHub Enterprise Server URL, and `GITHUB_TOKEN`. Fine-grained tokens work for pull requests and Actions, but GitHub doesn't let them read notifications, so the To-dos tab stays empty. Leave `GITHUB_URL` empty and the token only raises the rate limit for the trending-repos news source.
- **Only some groups or orgs.** `GITLAB_ORGS=platform,infra/tools` or `GITHUB_ORGS=my-org` keeps just those (and their subgroups). Handy when one token can see both work and personal projects.

### More than one account

Add as many accounts as you need by putting a name between the host and the setting:

```bash
GITLAB_URL=https://gitlab.com            # default GitLab account
GITLAB_TOKEN=...
GITLAB_WORK_URL=https://gitlab.example.com
GITLAB_WORK_TOKEN=...
GITHUB_URL=https://github.com
GITHUB_TOKEN=...
GITHUB_OSS_TOKEN=...                     # URL defaults to github.com
GITHUB_OSS_ORGS=my-oss-org
```

Each account is polled on its own and shows up with its own status chip ("GitLab · work"). Everything else (the Merge Requests and Pipelines screens, notifications, briefs, reports, search) combines all accounts. A reportee's GitLab username is used on every GitLab account, and their GitHub login on every GitHub account.

Everboard looks for the secrets file in this order and uses the first one that exists:

1. `$EVERBOARD_SECRETS`, if set (any path). Handy for the CLI; apps opened from Finder don't see your shell's variables.
2. `secrets.env` in the project folder the app was built from. That path is compiled in, so if you move the folder, run `make install` again.
3. `~/.config/everboard/secrets.env` (or `$XDG_CONFIG_HOME/everboard/secrets.env`). Use this to keep secrets out of the source tree entirely.

Settings → Accounts shows which file is in use. Any value missing from the file is also read from an environment variable of the same name.

## 3. Build and install

```bash
make install        # release build → ~/Applications/Everboard.app
open ~/Applications/Everboard.app
```

Opening the app shows the dashboard window, and a grid icon appears in the menu bar. Closing the window keeps Everboard running in the menu bar; use **Quit** in the menu to stop it. The app adds itself as a login item, which you can turn off in Settings → General.

## 4. First-run permissions

| Prompt | Effect if you allow | If you deny |
|---|---|---|
| Notifications | Native macOS banners | Everboard shows its own banners. Unsigned builds always use these; see [Build & deploy → Signing](build-and-deploy.md#signing). |
| Calendars | Next meeting in the menu bar, Join buttons, meeting prep, quiet notifications during meetings | Calendar features stay off |

Work meetings only show up if your work calendar is in macOS Calendar. To add it, go to System Settings → Internet Accounts → Microsoft Exchange/365 or Google.

## 5. Configure (Settings)

1. **Accounts:** check every account is listed, then click **Check connections** to confirm each one responds.
2. **Team:** paste your reportees' emails. Everboard looks up their GitLab usernames and GitHub logins; if a lookup fails, type the username yourself.
3. **Jira:** click **Load favourites**, then **Watch** the filters you care about. For each filter, choose whether new issues and/or status changes should notify you.
4. **Web panels:** add Jira dashboards or any other page. Sign in once inside the panel and it remembers you.
5. **Notifications:** choose which categories are urgent; everything else is batched.
6. **News:** set brief times and sources, and edit your preferences.

## 6. Check it's working

```bash
swift run everboard-cli check             # tokens, users, favourite filters, claude path
swift run everboard-cli poll --dry-run    # one fetch, printed, nothing saved
tail -f ~/Library/Logs/Everboard.log      # what the app is doing
```

If a self-hosted GitLab is behind a VPN, the menu shows "GitLab unreachable — VPN?" until you connect. After that it recovers on its own.
