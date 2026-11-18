# Features guide

## Menu bar

The grid icon shows:
- your **unread count**
- your **next meeting**, if it starts within the hour (e.g. `· in 12m: Standup`)
- a filled icon when a source is unhealthy, such as the VPN being down or a token having expired

Clicking the icon opens a popover with:
- a status chip for each source
- today's upcoming meetings, each with **Join** and ✨ **Prep** buttons
- the 8 latest events; click one to open it
- shortcuts to the Dashboard, Work brief, Reports and World & Tech, plus **Search ⌥Space**
- "N batched notifications — show now" when some are being held

## Dashboard window

Open it from the menu, from the Dock while it's open, by launching the app again, or with ⌥Space → "Open dashboard".

| Screen | What you see | Actions |
|---|---|---|
| **Home** (opens first) | Greeting with today's summary; tiles for reviews, your MRs, failed pipelines, Jira and unread; **Needs you** (red pipelines on your MRs, reviews oldest first, unread mentions, high-priority or due Jira issues, MRs ready to merge); today's meetings; your team's stuck MRs; Jira by status; the work brief; latest activity; the news headline; how much Claude was used today. All computed locally: Home never calls Claude itself. | Click a tile to jump to its screen. Click a row to open it; right-click to summarize or digest. Join or ✨ prep a meeting. |
| **Inbox** | Every event, grouped by day; filter by source and unread | Click to open. Right-click to mark read, snooze for a day, mute the item, or turn off that notification type. Summarize (reportee MRs) or get a Jira digest. |
| **Merge Requests** | Review requested / Mine / Assigned / Reportees (grouped by person) / To-dos. Draft MRs are hidden from Review requested (and from review counts on Home and the sidebar) unless you tick **Show drafts**. Rows show pipeline status, approvals, comments and linked Jira keys. "May be stuck" flags MRs open more than 3 days or red for more than 1 day. | Double-click to open. Right-click to summarize with AI, **approve** (asks first), **retry pipeline**, **comment**, or mute. To-dos: **mark done**. Click a Jira key for its AI digest. |
| **Pipelines** | Pipelines you triggered in the last 7 days, with failures from the last 24 hours first | Retry or open |
| **Jira** | Assigned to me, plus one tab per watched filter. Done issues (resolved, or in a Done-category status such as Closed or Archive) are hidden unless you tick **Show done**, which also lists issues assigned to you that finished in the last 30 days. Home, briefs and notifications only ever use open issues. | ✨ AI digest; ➜ move the issue through its workflow or comment |
| **Work Brief** | Claude's morning brief: what needs you today, your team, FYI | Generate, Listen |
| **Team & Reports** | **Radar** (each reportee's load, review waits, aging and red MRs, Jira movement, plus a digest), **Team health** metrics, **1:1 prep**, **Daily standup**, **Weekly report**. Everything here is a draft for you; nothing is sent to anyone. | Refresh, AI read, Copy, Save to notes, Listen |
| **Feeds** | One screen per custom source (Settings → Sources): items from your script's JSON, or notes from a markdown folder | Open, filter, run an agent, mute |
| **Agent Runs** | Every agent action you ran, newest first, with its output | Show output, stop, open the item or saved note, delete |
| **Web panels** | Any page you add, e.g. Jira dashboards, Grafana | Back, reload, open in browser |
| **World & Tech** | Personal news brief (see below) | — |
| **AI Activity** | Every Claude call: the exact prompt as it left your Mac (after masking), the instructions, and the reply, plus what was masked | Filter work/news, copy, clear the log |
| **Settings** | Everything configurable, including **AI privacy** and **AI usage** | — |

## Notifications

| Category | Fires when | Urgent by default |
|---|---|---|
| Pipeline failed on my MR | The head pipeline of an MR you authored, are assigned to, or were asked to review turns red | ✅ |
| Pipeline I triggered failed | A pipeline you started, in a project you pushed to this week or pinned, fails | ✅ |
| Reportee opened an MR | A new MR from someone in Settings → Team | |
| Review requested / Mentioned | A new GitLab to-do or GitHub notification of that kind | ✅ |
| Other to-dos and notifications | Assigned, approval required, unmergeable | |
| Jira assigned | An issue newly assigned to you | ✅ |
| Jira comment / mention | A new comment on your issues, or an @mention of you | mention ✅ |
| Filter: new / status change | Per watched filter, with its own toggles | |
| Major story | A big story matching your keywords: 3+ sources within 3 hours, or 600+ points on Hacker News | ✅ |
| Followed story update | A new article about a story you follow | |
| Brief / report ready | Scheduled AI output finished | always shown |
| Custom feed: new item / status change | Per custom source, with its own toggles | |

**Batching.**
- Urgent categories notify immediately; the rest arrive as one digest every 60 minutes (configurable).
- During a calendar event marked busy, everything waits until the meeting ends.
- The first sync after setup only records a baseline, so you don't get a burst of old alerts.

**Fallback banners.** If macOS blocks system notifications (unsigned builds), Everboard shows its own clickable banners in the top-right corner.

## AI features

All of these run the `claude` CLI on your Mac. See [AI & token usage](ai-and-usage.md) for exactly what each one sends, and **AI Activity** for what was actually sent.

MR references (`group/project!123`, and `!123` when it matches one known MR) and Jira keys from your projects are clickable in every AI result. **Copy** puts both plain text and HTML on the clipboard, so the links survive pasting into Teams, Outlook or Confluence.

| Feature | Where | When |
|---|---|---|
| Work brief | Work Brief | Weekdays 09:30 (configurable), or on demand |
| MR summary | MR right-click, notification action, ⌘↩ in the palette | On demand; optionally automatic for new reportee MRs |
| Jira digest | Jira ✨, linked keys, notification action | On demand |
| Daily standup | Team & Reports | On demand |
| Weekly report + team health | Team & Reports | Fridays 16:00 (configurable), or on demand |
| Team health AI read | Team & Reports → Team health | On demand |
| 1:1 prep | Team & Reports → 1:1 prep, or "1:1 prep" on the radar | On demand |
| Meeting prep | ✨ next to a meeting | On demand |
| World & Tech brief | World & Tech | 08:30, optional 18:00, or on demand |
| Go deeper / Ask the news | World & Tech | On demand |
| Learning from feedback | World & Tech | After you send feedback |

## Agent actions

Run your own CLI agent on any MR, PR, pipeline, Jira issue, to-do or feed item from its right-click menu (or the terminal button in the Pipelines and Jira tables). Each action is a command template you define in **Settings → Agents**, for example:

```sh
claude -p "/deep-review {url}"
cursor-agent -p "Review {sourceBranch} against {targetBranch}. Report only."
```

- **Placeholders** such as `{url}`, `{iid}`, `{projectPath}`, `{ref}`, `{jiraKey}`, `{sourceBranch}` and `{repoPath}` are filled from the item. Settings lists them all. `{repoPath}` comes from **Local repositories**, which maps a project (`group/app`, `owner/repo`, or just `app`) to your checkout.
- **Safe by construction.** Values reach the command as environment variables (`EVERBOARD_URL`, …), quoted to match where you wrote the placeholder, so an MR titled `$(rm -rf ~)` is passed as text and never executed. Your Everboard tokens are removed from the command's environment.
- **You stay in control.** Everboard shows the exact command and folder and asks before running, unless you turn that off for an action. Output streams into a sheet; you can stop the run at any time. Everboard never posts the output: **Copy** and **Comment…** (which opens the comment box pre-filled, for you to edit and post) are always your click.
- **History.** Every run is kept with its output under **Agent Runs** (30 days by default). Runs left over by a quit are marked cancelled.
- **Working folder.** Optional per action, e.g. `{repoPath}`. Without one the command runs in an empty scratch folder, so the agent doesn't pick up a random project.
- **Examples** in Settings → Agents → *Add an example* only read and report.

## Team radar and 1:1 prep

For managers with reportees in **Settings → Team**:

- **Radar** is computed locally from data Everboard already polls (no AI). For each person it shows open MRs/PRs, how many reviews are waiting on them, how long their ready MRs have waited without an approval, aging MRs (open longer than the threshold in Settings → Team, 3 days by default), red pipelines, and Jira issues assigned to them that moved in the last 7 days. Jira movement only covers issues in your assigned list and your watched filters. Expand a person to see the items; **Copy digest** gives a markdown summary with a **Needs attention** list.
- **1:1 prep** drafts wins to recognise, work in flight, where you can help and questions to ask, from the person's last two weeks of merged MRs/PRs, reviews they gave, what's open and Jira movement. If **Settings → Brain → Use my notes as AI context** is on, your own note about them is included (masked like every prompt).
- **Weekly report** stays a draft you copy; nothing is sent on a schedule. When a brain folder is set it's also saved to the week's note, with the team digest.

## Custom feeds

Add feeds in **Settings → Sources**, no code needed:

- **Command source.** Everboard runs your command on a timer (zsh, from your home folder) and reads JSON from its output: an array of items, or `{"items": [...]}`. Each item needs an `id` and `title`; `url`, `subtitle`, `status`, `author`, `createdAt`, `updatedAt` and `attrs` are optional. See [Extending](extending.md#add-a-feed-without-code) for the format.
- **Folder source.** Lists the markdown notes in a folder (for example a projects folder in your vault). Titles come from frontmatter `title`, the first `# heading`, or the file name; `status`, `url` and other frontmatter fields are kept. Optionally only notes with a given tag.

Each source appears under **Feeds** in the sidebar. It can notify on new items and on status changes, and supports agent actions and muting like every other item. Use **Test** in the editor to check a source before saving it.

## Brain folder

Point **Settings → Brain** at a folder of markdown notes, such as an Obsidian vault, and Everboard writes:

| What | Where | When |
|---|---|---|
| Work brief, standup draft, team digest, agent-run index | `Daily/<yyyy-MM-dd>.md` | When each is generated or saved |
| 1:1 prep | `People/<Name>.md` | When you draft it |
| Weekly report draft and team digest | `Weekly/<yyyy>-W<ww>.md` | When the report is generated |
| Each agent run, with command and output | `Everboard/Agent runs/<date> <action> <item>.md` | When the run finishes |

- Notes have YAML frontmatter (`date`, `tags`, …) and use `[[links]]` for people and days, so they show up in Obsidian's graph and backlinks.
- **Your writing is never overwritten.** In notes you may also edit (daily, people, weekly), Everboard only replaces its own section between `<!-- everboard:… -->` markers and leaves everything else alone. Agent-run notes are new files; a name clash gets " 2" instead of replacing anything.
- Folder names and the daily-note name format are configurable, to match an existing vault.
- **Reading back** is off by default. When on, the text *you* wrote in a person's note (Everboard's sections excluded) is added to their 1:1 prep prompt.

## World & Tech brief

- **Brief / Live feed / Following** switch, with tabs **All · World · AI · Tech · Your stack**.
  - **Brief:** Claude's ranked stories, each with a summary, "why it matters", topics and sources.
  - **Live feed:** everything collected in the last 36 hours, one row per story, refreshed every 30 minutes.
  - **Following:** stories you follow, each with its timeline of updates.
- **Teaching it your taste:**
  - 👍/👎 on any story or article.
  - Topic chips: "More about…" / "Less about…".
  - Free-text feedback ("skip crypto, more Swift").
  - Claude rewrites your preferences file from all of this; you can view and edit it in Settings → News.
- **Ask:** questions about the last 48 hours of news, answered with source links (web search as a fallback).
- **Listen:** reads the brief for the current tab aloud.
- **Sources:** 20+ RSS/Atom feeds, Hacker News and GitHub trending by default. Add or remove them in Settings → News.

## Command palette (⌥Space)

Press ⌥Space in any app. A floating search panel appears over what you're doing. It doesn't switch to Everboard, and it disappears when you click elsewhere.

**Empty box:** shows **Needs attention** (review requests, red pipelines on your MRs, unread items), **Recent** items you opened from the palette, today's **meetings** and **commands**.

**Typing:**
- **Fuzzy search** across commands, MRs/PRs (yours, review requests, your team's), to-dos, Jira issues, pipelines, inbox items, today's brief stories, live news and meetings. Matched letters are highlighted, and results are grouped and ranked.
- **Live search:** after 3+ characters, every GitLab/GitHub account and Jira are searched too (MRs/PRs by title, Jira by text), so you also find things Everboard isn't tracking. On github.com the search is limited to your `…_ORGS`, or to PRs involving you.
- **Direct jumps:** type a Jira key (`PAY-123`) to open or digest it immediately; paste a URL to open it.
- **Fallbacks:** "Ask the news: …", "Search Jira for …", "Search GitLab MRs / GitHub PRs for …" (one per account).

**Scopes.** Click a chip, press **Tab** / **⇧Tab** or **⌘1–⌘8**, or type a prefix:

| Prefix | Scope |
|---|---|
| `>` | Commands |
| `mr ` | Merge / pull requests (+ remote search) |
| `jira ` | Jira (+ Jira search) |
| `pl ` | Pipelines |
| `in ` | Inbox |
| `news ` | Brief stories + live news |
| `cal ` | Meetings |

**Preview pane.** On the right: details for the selected item (project, author, pipeline, approvals, branch, Jira status/priority/assignee, story summary, meeting attendees…) and its actions.

| Key | Action |
|---|---|
| ↩ | Primary action (open / join / run) |
| ⌘↩ | Secondary action (AI summary, digest, go deeper, retry, mark read…) |
| ⌘K | Action panel with every action, e.g. approve (asks first), retry pipeline, mark to-do done, **move a Jira issue** (its workflow loads live), follow a story, 👍/👎, mute, snooze, copy key/link |
| ⇧⌘C | Copy link |
| ↑↓ | Move |
| Esc | Close the action panel → clear the query → reset the scope → close |

## Calendar

Everboard reads macOS Calendar. It finds Teams, Zoom, Meet and Webex links for the **Join** button. **Prep** collects MRs and Jira issues related to the attendees or the topic and asks Claude for context, talking points and questions.

## Read aloud

The briefs and reports have a **Listen** button that uses on-device voices. Choose the voice and speed in Settings → General. Better voices can be downloaded in System Settings → Accessibility → Spoken Content.

## AI privacy

**Settings → AI privacy** controls what may leave your Mac:

- **Allow work features to send data to Claude.** Off refuses every work feature before anything is sent (and skips the scheduled brief and weekly report). News keeps working.
- **Include MR code diffs / Jira descriptions and comments / meeting notes.** With diffs off, MR summaries see file names and line counts only.
- **Masking**, done locally before sending: secrets (tokens, keys, passwords, private keys) become `[SECRET]`; emails, people's names and your own list of words become `[EMAIL-1]`, `[PERSON-1]`, `[TERM-1]`. Claude only sees the placeholders; Everboard puts the real values back into the reply on your Mac. A "Try it" box previews the masking.
- **Activity log**: how many days to keep the local copy of every prompt and reply (0 turns it off).

## AI usage dashboard

**Settings → AI usage** shows tokens and estimated cost for today and for the last 7, 30 or 90 days, as a daily chart and broken down by feature and by model. See [AI & token usage](ai-and-usage.md).
