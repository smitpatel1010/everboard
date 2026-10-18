# Everboard — macOS menu-bar dashboard for GitLab, Jira and news.
DEV := /Library/Developer/CommandLineTools/Library/Developer
# Swift Testing ships with the Command Line Tools but isn't on the default search paths.
TEST_FLAGS := -Xswiftc -F -Xswiftc $(DEV)/Frameworks -Xlinker -F -Xlinker $(DEV)/Frameworks \
              -Xlinker -rpath -Xlinker $(DEV)/Frameworks -Xlinker -rpath -Xlinker $(DEV)/usr/lib

.PHONY: build app install run test check cli icon leakcheck hooks clean

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

# Secrets / personal-details scan of everything that would be committed (add --history for all commits).
leakcheck:
	scripts/leakcheck.sh

# Run leakcheck before every commit in this clone.
hooks:
	@printf '#!/bin/sh\nexec scripts/leakcheck.sh\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
	@echo "Installed .git/hooks/pre-commit"

clean:
	rm -rf .build build
