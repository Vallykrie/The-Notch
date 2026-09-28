# Contributing to The Notch

Thanks for helping out! Bug reports, fixes and new agent integrations are all welcome.

## Before you start

- For anything bigger than a small fix, **open an issue first** so we can agree on the approach.
- Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and check [docs/ROADMAP.md](docs/ROADMAP.md)
  to see whether the work is already planned.

## Build

You need Xcode with the macOS 14 SDK, and Go 1.22+ for the hook tools.

```bash
xcodebuild -project "The Notch.xcodeproj" -scheme "The Notch" \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

To run a signed build from Xcode, set **Signing & Capabilities → Team** to your own team.
Please do not commit that change.

## Tests

```bash
bash tools/hook-harness/run-all.sh   # hook bridge: allow, deny, timeout, concurrency, bad input
bash tools/session-tests/run.sh      # session lifecycle
bash tools/trading-tests/run.sh      # crypto store
(cd tools/notch-hook && go test ./...)
```

## House rules

- **Original code only.** Do not paste code from other apps. Code from other projects must be
  under an MIT-compatible licence (MIT, BSD, Apache-2.0, ISC, Zlib) and be listed in
  `THIRD_PARTY_LICENSES`. GPL code cannot be accepted.
- **Hooks must fail open.** A bug in `notch-hook` must never block or break someone's agent.
- **Never clobber agent config.** Merge into `~/.claude/settings.json` and friends, back up
  first, stay idempotent. Tests must use a fake home directory, never the real one.
- **Motion lives in `Core/Theme.swift`.** Views never hardcode springs, durations or radii.
- **No personal data.** Use placeholder paths such as `/Users/you/code/project` in previews
  and tests.
- Update the relevant checkbox in `docs/ROADMAP.md` in the same PR as the code.

## Pull requests

Keep PRs focused, describe what you changed and how you tested it, and include a screenshot or
screen recording for anything visual. By submitting a PR you agree that your contribution is
licensed under the [MIT License](LICENSE).
