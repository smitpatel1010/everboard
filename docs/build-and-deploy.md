# Build & deploy: how Everboard gets onto your Mac

There's no App Store and no installer. You build from source and copy the result into `~/Applications`. This page explains each step.

## What `make install` does

```
make install
  └─ scripts/build-app.sh release --install
       1. swift build -c release --product Everboard     → .build/release/Everboard (a plain Mach-O binary)
       2. assemble a bundle:
            build/Everboard.app/
              Contents/
                Info.plist          ← identity + behaviour (copied from Resources/)
                MacOS/Everboard     ← the binary from step 1
                Resources/AppIcon.icns, GRDB_GRDB.bundle
       3. codesign the bundle (see Signing)
       4. quit any running copy, copy to ~/Applications/Everboard.app
```

**Why a bundle?** macOS treats a folder ending in `.app` that has this layout as an application. Notifications, Calendar permission, login items and the Dock all key off the bundle's identifier in `Info.plist`. A bare binary can't get any of these.

### Info.plist keys that matter
| Key | Effect |
|---|---|
| `CFBundleIdentifier` = `local.everboard.mac` | The app's identity for permissions, notifications and preferences (`~/Library/Preferences/local.everboard.mac.plist`) |
| `LSUIElement` = true | No Dock icon by default, so it's a menu-bar app. The code switches to a regular app (Dock + ⌘Tab) while the dashboard window is open. |
| `NSCalendars…UsageDescription` | The text shown in the Calendar permission prompt |
| `LSMinimumSystemVersion` | 14.0 |

## Running

- `open ~/Applications/Everboard.app` (or double-click it) starts the app and shows the dashboard. Opening it again while it's running brings the dashboard back.
- **Login item:** on start, the app registers itself with `SMAppService.mainApp`, macOS's modern login-items API. When macOS launches it at login it stays in the menu bar without opening a window. You can toggle this in Settings → General, or in System Settings → General → Login Items.
- **Background behaviour:** polling continues whenever the app is running, including when the window is closed. On wake from sleep or a network change it refreshes immediately.

## Where things live

| What | Path |
|---|---|
| App | `~/Applications/Everboard.app` |
| Secrets | `<project folder>/secrets.env` (git-ignored, chmod 600; the path is compiled into the app) |
| Settings | `~/Library/Application Support/Everboard/config.json` |
| Database | `~/Library/Application Support/Everboard/everboard.sqlite` |
| News preferences | `~/Library/Application Support/Everboard/news-preferences.md` |
| Small UI prefs | `~/Library/Preferences/local.everboard.mac.plist` |
| Log | `~/Library/Logs/Everboard.log` |
| Claude scratch dir | `~/Library/Caches/Everboard/claude-work` |
| Web panel cookies | WebKit's default store for the app |

## Updating

```bash
git pull          # or edit code
make test
make install      # rebuilds, quits the running app, replaces it
open ~/Applications/Everboard.app
```
Your settings, data and secrets are kept, and the database migrates itself (`Store.swift` migrations).

## Signing

macOS will only deliver **system notifications** to properly signed apps. `build-app.sh` signs with the first one of these it finds:

1. `$EVERBOARD_SIGN_IDENTITY`, if set
2. a keychain identity called **Everboard Local**
3. an **Apple Development** identity (you get one from Xcode with any Apple ID)
4. otherwise **ad-hoc** (`codesign -s -`). The app works fully, but notifications fall back to Everboard's in-app banners.

### Create "Everboard Local" (one-time, about 1 minute)
1. Open **Keychain Access**.
2. Go to **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Fill in the form:
   - Name `Everboard Local`
   - Identity Type **Self Signed Root**
   - Certificate Type **Code Signing**
   
   Then click Create.
4. Run `make install`. The output should say `Signed with: Everboard Local`.
5. Launch the app and allow notifications. Check the result in Settings → Notifications.

A stable signature also means macOS keeps your permissions across rebuilds. If a self-signed certificate isn't enough on your macOS version, install Xcode and add your Apple ID in Xcode → Settings → Accounts to get an Apple Development certificate.

## Uninstalling

```bash
pkill -x Everboard
rm -rf ~/Applications/Everboard.app
rm -rf ~/Library/Application\ Support/Everboard ~/Library/Caches/Everboard ~/Library/Logs/Everboard.log
defaults delete local.everboard.mac
```
Also remove Everboard under System Settings → General → Login Items, if it's still listed.

## Developer builds

| Command | Purpose |
|---|---|
| `make build` | Debug compile only |
| `scripts/build-app.sh debug` | Debug `.app` in `build/` without installing |
| `open build/Everboard.app --args --demo` | Run with sample data in memory; your real data is untouched |
| `open -W build/Everboard.app --args --demo --snapshot /tmp/shots` | Render every screen to PNG, then quit |
| `make icon` | Regenerate `Resources/AppIcon.icns` from `scripts/make-icon.swift` |

## Why no Xcode project?

Everything builds with the Command Line Tools through SwiftPM. That keeps the repo small and diff-friendly, and it builds the same in CI. Tests use Swift Testing, which ships with the Command Line Tools; the Makefile adds the framework search paths that would otherwise come from Xcode.
