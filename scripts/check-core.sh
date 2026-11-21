#!/bin/bash
# Fails if EverboardCore imports a UI framework. Core must stay testable and reusable (see AGENTS.md).
cd "$(dirname "$0")/.."
hits="$(grep -rnE '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(SwiftUI|AppKit|UIKit)\b' Sources/EverboardCore || true)"
if [ -n "$hits" ]; then
    echo "EverboardCore must not import SwiftUI, AppKit or UIKit:"
    echo "$hits"
    exit 1
fi
