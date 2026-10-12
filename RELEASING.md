# Releasing BetterDock

Releases are built, signed, notarized and uploaded on the Mac mini (`ssh mini`). Run the scripts from
any checkout: they copy it to the Mini and run there. Outputs go to
`/Volumes/DevVault/Dev/betterdock-release/out/<version>/`. Steps that need the keychain (signing,
notarization, appcast signing) run inside the Mini's logged-in GUI session through a one-shot
LaunchAgent (`release/mini-gui-run.sh`) that removes itself afterwards, so someone must be logged in
at the Mini's screen.

## Prerequisites (once)

1. **Developer ID certificate on the Mini.** At developer.apple.com > Certificates, create a
   *Developer ID Application* certificate, and install it with its private key in the Mini's login
   keychain (in the GUI session). Check it in Terminal on the Mini's screen:
   `security find-identity -v -p codesigning` lists `Developer ID Application: … (TEAMID)`.
   The scripts find the identity themselves.
2. **Notary credentials.** In Terminal on the Mini's screen (not over ssh), with an app-specific
   password from appleid.apple.com:
   ```bash
   xcrun notarytool store-credentials betterdock-notary --apple-id <apple-id> --team-id <TEAMID>
   ```
3. **Sparkle update key.** Already created: the private EdDSA key is in the Mini's login keychain
   (account `betterdock`) and its public key is committed in `packaging/sparkle-public-key.txt`.
   `release/sparkle-keys.sh` prints it again and never replaces an existing key. Back the private key
   up once into a password manager, from the Mini's screen:
   `packaging/vendor/Sparkle-2.10.0/bin/generate_keys --account betterdock -x ~/Desktop/betterdock-sparkle.key`,
   then delete that file. Without it, installed copies can never verify another update.

Sparkle is pinned to 2.10.0 and checksum-verified (`release/lib.sh`); `packaging/vendor/` is not committed.

## Release X.Y.Z

```bash
git push                                  # the release tag is created on the pushed HEAD
release/build-release.sh X.Y.Z            # universal app, Developer ID + hardened runtime, notarized and stapled app and DMG
release/make-appcast.sh X.Y.Z             # adds X.Y.Z to the published appcast, EdDSA-signed
release/publish.sh X.Y.Z [--tap]          # GitHub release vX.Y.Z with the DMG + appcast.xml, then the Homebrew cask
```

- Versions only go up: Sparkle compares `CFBundleVersion`, and `publish.sh` refuses to replace an
  existing release.
- The feed lives at `https://github.com/Bilal-Bjo/betterdock/releases/latest/download/appcast.xml`, so
  it always comes from the newest release. `make-appcast.sh` downloads the current feed and adds the new
  item, keeping older items with their own versioned download URLs.
- Every step stops with a message naming what is missing (certificate, notary profile, key, stapling).
  The build log of the signing job is saved next to the DMG as `sign-and-notarize.log`.
- Dry run without any Apple credentials: `release/build-release.sh X.Y.Z --unsigned` (ad-hoc signed app
  and `BetterDock-X.Y.Z-unsigned.dmg`), and `release/make-appcast.sh X.Y.Z --unsigned` for a test feed.

## Homebrew

The cask template is `packaging/homebrew/betterdock.rb`; `publish.sh` writes the filled-in cask to
`out/<version>/betterdock.rb`. To publish it through a tap, create the tap once:

```bash
gh repo create Bilal-Bjo/homebrew-tap --public --description "Homebrew tap for BetterDock"
```

Then `release/publish.sh X.Y.Z --tap` commits `Casks/betterdock.rb` there. Users install with
`brew install --cask bilal-bjo/tap/betterdock`; after that, Sparkle updates the app itself
(`auto_updates true`).
