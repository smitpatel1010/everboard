# Everboard — macOS menu-bar dashboard for GitLab, Jira and news.
DEV := /Library/Developer/CommandLineTools/Library/Developer
# Swift Testing ships with the Command Line Tools but isn't on the default search paths.
TEST_FLAGS := -Xswiftc -F -Xswiftc $(DEV)/Frameworks -Xlinker -F -Xlinker $(DEV)/Frameworks \
              -Xlinker -rpath -Xlinker $(DEV)/Frameworks -Xlinker -rpath -Xlinker $(DEV)/usr/lib

.PHONY: build app install run test check cli icon screenshots leakcheck hooks clean

build:
	swift build

app:
	scripts/build-app.sh release

install:
	scripts/build-app.sh release --install

run: install
	open ~/Applications/Everboard.app

test:
	swift test $(TEST_FLAGS)

cli:
	swift build -c release --product everboard-cli
	@echo "CLI at $$(swift build -c release --show-bin-path)/everboard-cli"

check: cli
	$$(swift build -c release --show-bin-path)/everboard-cli check

icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns

# README screenshots from demo data (never your real accounts), light and dark.
SHOTS := home mrs world reports workbrief palette-search menubar
screenshots:
	scripts/build-app.sh debug
	@for mode in light dark; do \
		rm -rf build/snapshots/$$mode; \
		build/Everboard.app/Contents/MacOS/Everboard --demo --snapshot build/snapshots/$$mode --appearance $$mode; \
		mkdir -p docs/screenshots/$$mode; \
		for s in $(SHOTS); do sips -Z 1600 build/snapshots/$$mode/$$s.png --out docs/screenshots/$$mode/$$s.png >/dev/null; done; \
	done
	@echo "Updated docs/screenshots/{light,dark}"

# Secrets / personal-details scan of everything that would be committed (add --history for all commits).
leakcheck:
	scripts/leakcheck.sh

# Run leakcheck before every commit in this clone.
hooks:
	@printf '#!/bin/sh\nexec scripts/leakcheck.sh\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
	@echo "Installed .git/hooks/pre-commit"

clean:
	rm -rf .build build
