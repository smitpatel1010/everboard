# AI & token usage

Everboard doesn't call any AI API directly. It runs the **`claude` CLI** (Claude Code) on your Mac, using whatever account `claude` is signed into: a Claude subscription or an API key.

## How a call works

`ClaudeCLIRunner` (`Sources/EverboardCore/AI/Claude.swift`) runs:

```
claude -p --output-format json --no-session-persistence --strict-mcp-config \
       --tools "<allowlist>" [--allowedTools …] [--model …] \
       --append-system-prompt "<task prompt> + untrusted-data guard" [--json-schema …]
```

- The **prompt goes in on stdin**. There's no shell, so nothing can be injected into a command line.
- It runs in an **empty scratch directory** (`~/Library/Caches/Everboard/claude-work`), so no project `CLAUDE.md` or files end up in the context.
- **No MCP servers** are loaded (`--strict-mcp-config`), and sessions aren't saved.
- **Tools:** none by default. A few news features get `WebSearch` / `WebFetch`, and the runner refuses anything else, so Bash, Edit, Write and Read can never be enabled.
- The child process gets a **cleaned environment**: Everboard's token variables are removed.
- The JSON reply provides the text, any structured output, the cost and the token usage.

The path to `claude` is auto-detected (`~/.local/bin`, Homebrew, `/usr/local/bin`, `$PATH`) or set in Settings → General. Leave the model blank to use the CLI's default, or set e.g. `sonnet` / `haiku` to trade quality for cost.

## What each feature sends

| Feature (`feature` label) | Input | Tools | Typical size |
|---|---|---|---|
| Work brief (`work.brief`) | Your open MRs, review queue, reportee MRs, to-dos, last 24 h of pipelines, assigned Jira issues, last 24 h of events (titles and statuses only) | none | 2–8k tokens in |
| MR summary (`mr.summary`) | MR title, description, diff (truncated at about 60 KB) | none | up to about 20k in |
| Jira digest (`jira.digest`) | Issue fields, description, up to 40 comments | none | 2–15k in |
| Daily standup (`report.standup`) | Your merged and reviewed MRs since the last workday, Jira issues you touched, open MRs | none | 1–4k in |
| Weekly report (`report.weekly`) | Merged and open MRs for you and each reportee over 7 days, Jira issues resolved | none | 3–15k in |
| Team health AI read (`team.commentary`) | The metrics table only | none | < 1k in |
| Meeting prep (`meeting.prep`) | Event title, time, attendees, notes, related MR/issue titles | none | 1–3k in |
| World & Tech brief (`news.brief`) | About 150 headlines with snippets, your preferences, recent feedback | `WebSearch` if gap check is on | 15–25k in |
| Go deeper (`news.deeper`) | One story and its source URLs | `WebFetch`, `WebSearch` | varies |
| Ask the news (`news.ask`) | Your question, today's brief, about 220 recent headlines | `WebSearch`, `WebFetch` if gap check is on | 15–25k in |
| Learning from feedback (`news.preferences`) | The preferences file and new feedback | none | < 2k |

Work data goes to Claude only through these features: a scheduled work brief, a weekly report, or a button you click. News prompts never contain work data.

Results are cached (`ai_cache` table), so opening the same MR summary or Jira digest again is free until the item changes.

## The usage dashboard

**Settings → AI usage** reads the `ai_usage` table. `RecordingClaudeRunner` writes one row per call (failures included) with:
- feature and model
- input, output, cache-read and cache-write tokens
- web searches
- estimated cost and duration

The dashboard shows:
- totals for today and for the last 7 / 30 / 90 days
- a tokens-per-day chart
- tables by feature and by model

**About cost.** It's the API-equivalent figure the CLI reports. On a Claude subscription you aren't billed per token; the number is still useful for seeing which features are heavy.

Typical costs seen in practice:
- A World & Tech brief with gap check costs about $0.30 (most of it is input and web search). With gap check off it's cheaper.
- Small calls (standup, AI read, preferences) cost a few cents each.

**To spend less:**
- Turn off **gap check** (Settings → News).
- Set the model to `sonnet` or `haiku`.
- Disable the evening news edition or **auto-summarize reportee MRs**.
- Keep the weekly report weekly.
