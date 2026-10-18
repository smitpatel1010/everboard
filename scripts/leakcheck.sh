#!/bin/bash
# Fails if anything that is (or would be) committed contains secrets or details about you or your employer.
# Usage: scripts/leakcheck.sh [--history]
#
# What it looks for:
#   - token formats (GitLab, GitHub, Atlassian, Anthropic, Slack, private keys) and personal home paths
#   - the hosts, email and email domain from your git-ignored secrets.env, and its token values
#   - every line of the git-ignored .leakcheck file: one case-insensitive literal per line
#     (company name, internal hostnames, project codenames, teammates' names...). '#' starts a comment.
# Files scanned: tracked files plus untracked ones that aren't ignored. --history also scans every
# commit's diff and author/committer emails. A line containing "leakcheck:allow" is skipped.
# Only file:line and a label are printed, never the matched text.
set -uo pipefail
cd "$(dirname "$0")/.."

HISTORY=0
[[ "${1:-}" == "--history" ]] && HISTORY=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FOUND=0

# label<TAB>mode(E=regex, F=literal)<TAB>pattern
PATTERNS="$TMP/patterns"
cat > "$PATTERNS" <<'EOF'
GitLab token	E	glpat-[A-Za-z0-9_-]{20,}
GitHub token	E	(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}
Atlassian token	E	ATATT3[A-Za-z0-9_=-]{40,}
Anthropic key	E	sk-ant-[A-Za-z0-9_-]{20,}
Slack token	E	xox[abposr]-[A-Za-z0-9-]{10,}
Private key	E	-----BEGIN ([A-Z]+ )?PRIVATE KEY-----
Home directory path	E	/Users/[A-Za-z0-9._-]+/
EOF

add_literal() { # label value — skip empty and trivially short values
    local v
    v="$(printf '%s' "$2" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ ${#v} -ge 4 ]] && printf '%s\tF\t%s\n' "$1" "$v" >> "$PATTERNS"
}

secrets_value() { # KEY → value from secrets.env, quotes and trailing comments stripped
    sed -nE "s/^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=[[:space:]]*//p" secrets.env | tail -1 |
        sed -E "s/[[:space:]]+#.*$//; s/^['\"]//; s/['\"]$//"
}

if [[ -f secrets.env ]]; then
    for key in GITLAB_URL JIRA_URL; do
        host="$(secrets_value "$key" | sed -E 's#^[a-z]+://##; s#[/:].*$##')"
        case "$host" in gitlab.com|github.com|*example*|"<"*|"") ;; *) add_literal "$key host (secrets.env)" "$host" ;; esac
        # Also the site/company label, e.g. "acme" from acme.atlassian.net or gitlab.acme.com.
        label="$(printf '%s' "$host" | awk -F. '{ if ($(NF-1)=="atlassian") print $1; else if (NF>=2) print $(NF-1) }')"
        case "$label" in gitlab|github|atlassian|example|"") ;; *) add_literal "$key site name (secrets.env)" "$label" ;; esac
    done
    email="$(secrets_value JIRA_EMAIL)"
    if [[ "$email" == *@* ]]; then
        add_literal "JIRA_EMAIL (secrets.env)" "$email"
        add_literal "JIRA_EMAIL local part (secrets.env)" "${email%@*}"
        domain="${email#*@}"
        case "$domain" in gmail.com|outlook.com|hotmail.com|icloud.com|me.com|yahoo.com|proton.me|protonmail.com|example.*) ;;
            *) add_literal "JIRA_EMAIL domain (secrets.env)" "$domain" ;; esac
    fi
    for key in GITLAB_TOKEN JIRA_API_TOKEN GITHUB_TOKEN; do
        add_literal "$key value (secrets.env)" "$(secrets_value "$key")"
    done
fi

if [[ -f .leakcheck ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        add_literal "term from .leakcheck" "$line"
    done < .leakcheck
fi

git ls-files -z -co --exclude-standard | while IFS= read -r -d '' f; do
    [[ -f "$f" ]] && printf '%s\0' "$f"
done > "$TMP/files"

report() { echo "  $1  [$2]"; FOUND=1; }

while IFS=$'\t' read -r label mode pattern; do
    [[ -z "$pattern" ]] && continue
    flags="-IE"; [[ "$mode" == F ]] && flags="-IiF"
    hits="$(xargs -0 grep -n $flags -e "$pattern" -- < "$TMP/files" 2>/dev/null | grep -v 'leakcheck:allow' | cut -d: -f1,2)"
    while IFS= read -r h; do [[ -n "$h" ]] && report "$h" "$label"; done <<< "$hits"

    if [[ $HISTORY == 1 ]]; then
        gflags="-E"; [[ "$mode" == F ]] && gflags="-iF"
        n="$(git log --all -p --no-color 2>/dev/null | grep -v 'leakcheck:allow' | grep -c $gflags -e "$pattern")"
        [[ "$n" -gt 0 ]] && report "git history ($n lines)" "$label"
        if [[ "$mode" == F ]] && git log --all --format='%an %ae %cn %ce' | grep -qiF -e "$pattern"; then
            report "git author/committer" "$label"
        fi
    fi
done < "$PATTERNS"

if [[ $FOUND == 1 ]]; then
    echo "leakcheck: found possible leaks (above). Remove them, or mark a deliberate line with 'leakcheck:allow'." >&2
    exit 1
fi
terms=$(grep -c $'\tF\t' "$PATTERNS")
echo "leakcheck: clean ($(tr -cd '\0' < "$TMP/files" | wc -c | tr -d ' ') files, $terms personal terms$([[ $HISTORY == 1 ]] && echo ', incl. history'))"
