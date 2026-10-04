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
| **Inbox** | Every event, grouped by day; filter by source and unread | Click to open. Right-click to mark read, snooze for a day, mute the item, or turn off that notification type. Summarize (reportee MRs) or get a Jira digest. |
| **Merge Requests** | Review requested / Mine / Assigned / Reportees (grouped by person) / To-dos. Rows show pipeline status, approvals, comments and linked Jira keys. "May be stuck" flags MRs open more than 3 days or red for more than 1 day. | Double-click to open. Right-click to summarize with AI, **approve** (asks first), **retry pipeline**, **comment**, or mute. To-dos: **mark done**. Click a Jira key for its AI digest. |
| **Pipelines** | Pipelines you triggered in the last 7 days, with failures from the last 24 hours first | Retry or open |
| **Jira** | Assigned to me, plus one tab per watched filter | ✨ AI digest; ➜ move the issue through its workflow or comment |
| **Work Brief** | Claude's morning brief: what needs you today, your team, FYI | Generate, Listen |
| **Team & Reports** | **Team health** metrics for each reportee, **Daily standup**, **Weekly report** | Refresh, AI read, Copy, Listen |
| **Web panels** | Any page you add, e.g. Jira dashboards, Grafana | Back, reload, open in browser |
| **World & Tech** | Personal news brief (see below) | — |
| **Settings** | Everything configurable, including **AI usage** | — |

## Notifications

| Category | Fires when | Urgent by default |
|---|---|---|
| Pipeline failed on my MR | The head pipeline of an MR you authored, are assigned to, or were asked to review turns red | ✅ |
| Pipeline I triggered failed | A pipeline you started, in a project you pushed to this week or pinned, fails | ✅ |
| Reportee opened an MR | A new MR from someone in Settings → Team | |
| Review requested / Mentioned | A new GitLab to-do of that kind | ✅ |
| Other GitLab to-dos | Assigned, approval required, unmergeable | |
| Jira assigned | An issue newly assigned to you | ✅ |
| Jira comment / mention | A new comment on your issues, or an @mention of you | mention ✅ |
| Filter: new / status change | Per watched filter, with its own toggles | |
| Major story | A big story matching your keywords: 3+ sources within 3 hours, or 600+ points on Hacker News | ✅ |
| Followed story update | A new article about a story you follow | |
| Brief / report ready | Scheduled AI output finished | always shown |

**Batching.**
- Urgent categories notify immediately; the rest arrive as one digest every 60 minutes (configurable).
- During a calendar event marked busy, everything waits until the meeting ends.
- The first sync after setup only records a baseline, so you don't get a burst of old alerts.

**Fallback banners.** If macOS blocks system notifications (unsigned builds), Everboard shows its own clickable banners in the top-right corner.

## AI features

All of these run the `claude` CLI on your Mac. See [AI & token usage](ai-and-usage.md) for exactly what each one sends.

| Feature | Where | When |
|---|---|---|
| Work brief | Work Brief | Weekdays 09:30 (configurable), or on demand |
| MR summary | MR right-click, notification action, ⌘↩ in the palette | On demand; optionally automatic for new reportee MRs |
| Jira digest | Jira ✨, linked keys, notification action | On demand |
| Daily standup | Team & Reports | On demand |
| Weekly report + team health | Team & Reports | Fridays 16:00 (configurable), or on demand |
| Team health AI read | Team & Reports → Team health | On demand |
| Meeting prep | ✨ next to a meeting | On demand |
| World & Tech brief | World & Tech | 08:30, optional 18:00, or on demand |
| Go deeper / Ask the news | World & Tech | On demand |
| Learning from feedback | World & Tech | After you send feedback |

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

It works from any app. Type to fuzzy-search:
- commands ("Write my standup", "Refresh now"…)
- MRs, Jira issues, pipelines
- unread events
- brief stories and news articles

| Key | Action |
|---|---|
| ↩ | Open |
| ⌘↩ | AI action (Summarize / Digest / Go deeper) |
| ↑↓ | Move |
| Esc | Close |

## Calendar

Everboard reads macOS Calendar. It finds Teams, Zoom, Meet and Webex links for the **Join** button. **Prep** collects MRs and Jira issues related to the attendees or the topic and asks Claude for context, talking points and questions.

## Read aloud

The briefs and reports have a **Listen** button that uses on-device voices. Choose the voice and speed in Settings → General. Better voices can be downloaded in System Settings → Accessibility → Spoken Content.

## AI usage dashboard

**Settings → AI usage** shows tokens and estimated cost for today and for the last 7, 30 or 90 days, as a daily chart and broken down by feature and by model. See [AI & token usage](ai-and-usage.md).
