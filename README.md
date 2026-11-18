# freevo-tv-lineup

The published lineup FREEVO TV reads for its channels, titles, and air times. Editing this file rotates the
guide; the TVs pick it up at launch and every 30 minutes, or immediately from Settings → Refresh lineup.

The app reads exactly one URL:

```
https://raw.githubusercontent.com/Charger1258/freevo-tv-lineup/main/lineup.json
```

Keep this repository **public** — the TVs fetch it without a token. (They fetch over HTTPS only, and a
private repo would need a token on every TV.)

## Rotating the guide

Edit the working copy in the Streaming Apps workspace, validate it, then push it here:

```powershell
# One-time setup: a clone to work from
git clone https://github.com/Charger1258/freevo-tv-lineup
# 1. Edit the working copy in the Streaming Apps workspace
code "C:\Users\Roni\Documents\Streaming Apps\Android\stream-firetv-next\channels\lineup\lineup.json"
# 2. Check it against the same rules the TV applies (exit code 1 means the TV would drop something)
& "C:\Users\Roni\Documents\Streaming Apps\Android\stream-firetv-next\channels\lineup\Validate-Lineup.ps1"
# 3. Publish from the clone
cd freevo-tv-lineup
copy "C:\Users\Roni\Documents\Streaming Apps\Android\stream-firetv-next\channels\lineup\lineup.json" lineup.json
git add lineup.json; git commit -m "Rotate the lineup"
git -c credential.helper= -c credential.helper="!gh auth git-credential" push   # plain git push hangs on GCM
```

A worked example of both controls — a five-title Comedy `wheel` plus *Knives Out* pinned at 5:00 PM ET — is
commit `bdbb664`. It was reverted once proven, so `main` carries the plain revision 1 lineup again.

Raise `revision` on every rotation. A pushed revision rebuilds planned hours from the next minute forward,
and whatever is already on air keeps running until it ends. Undo a bad rotation with `git revert`.
GitHub itself holds an old copy of the raw file for about five minutes.

The full schema — channels, `content`, `wheel`, pinned `schedule` blocks, timezones, and everything the TV
silently drops — is documented in
`Android/stream-firetv-next/channels/lineup/README.md` in the Streaming Apps workspace, which is also where
the editor copy and the validator live. This repository keeps a copy of the validator under
`.github/scripts/` so every push is checked automatically by `.github/workflows/validate.yml`.

To make a bad push impossible rather than merely red, require that check before it can land on `main`:

```powershell
'{"required_status_checks":{"strict":true,"contexts":["Validate lineup"]},"enforce_admins":true,"required_pull_request_reviews":null,"restrictions":null}' |
  gh api -X PUT repos/Charger1258/freevo-tv-lineup/branches/main/protection --input -
```
