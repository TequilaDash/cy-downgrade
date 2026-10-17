# GitHub Issue Comment Templates

Use these as starting points for bug triage comments. Keep the wording cautious:
ask users to test or attach evidence, and avoid saying an issue is definitely
fixed until the reporter confirms it.

## Needs More Info

Label: `status:needs-info`

```markdown
Thanks for the report. I need a bit more evidence from the device around the time this happens.

Could you please reproduce it once, then attach:

- The Cyanide chain log: open Cyanide -> Log tab, or Cyanide Settings -> Share Log, and attach the latest `chain-*.log`.
- Any SpringBoard crash report from the same time: iOS Settings -> Privacy & Security -> Analytics & Improvements -> Analytics Data, then search `SpringBoard`. Attach the newest one from right after the event if it exists.
- Any kernel panic report from the same time: same Analytics Data screen, search `panic`, `panic-full`, or `panic-base`. Attach the newest matching file if one exists.

Also please list the exact tweaks enabled when it happens, and whether it still happens if you enable only one tweak at a time. The easiest way on-device is to use the search field in Analytics Data and search by name: `SpringBoard`, `Cyanide`, `panic`, or `panic-full`.
```

## Empty Or Thin Report

Label: `status:needs-info`

```markdown
Thanks for the report. I need more details before I can reproduce this one.

Could you please add:

- Device model, iOS/iPadOS version, Cyanide version, and install method.
- The exact tweak or setting you enabled.
- The steps you took right before it happened.
- The Cyanide chain log: open Cyanide -> Log tab, or Cyanide Settings -> Share Log, and attach the latest `chain-*.log`.
- Any related device report from iOS Settings -> Privacy & Security -> Analytics & Improvements -> Analytics Data. Useful search terms are `Cyanide`, `SpringBoard`, `panic`, and `panic-full`.
```

## Possible Kernel Panic Or Reboot

Label: `status:needs-info`

```markdown
Thanks for the report. Since this sounds like a reboot while applying tweaks, the device logs from that same time would be the most useful next evidence.

Could you please reproduce once if you can, then attach:

- The Cyanide chain log: open Cyanide -> Log tab, or Cyanide Settings -> Share Log, and attach the latest `chain-*.log`.
- Any kernel panic report from the same time: iOS Settings -> Privacy & Security -> Analytics & Improvements -> Analytics Data, then search `panic`, `panic-full`, or `panic-base`. Attach the newest matching file from right after the reboot if one exists.
- Any SpringBoard crash report from the same time: in Analytics Data, search `SpringBoard`.

Please also mention which single tweak triggers it first if you test them one at a time. That will help narrow whether this is shared SpringBoard injection state or a specific tweak path.
```

## New Build Needs Testing

Label: `status:needs-testing`

```markdown
I shipped `{version}` with a change targeting this code path.

Could you please install the new build and test the same steps again? Release: {release_url}

If it still happens, please reply with the latest Cyanide chain log from the Log tab or Settings -> Share Log, plus any matching device report from iOS Settings -> Privacy & Security -> Analytics & Improvements -> Analytics Data.
```

## iPad Launch Crash Needs Testing

Label: `status:needs-testing`

```markdown
I shipped `{version}` with a change targeting the iPad launch crash path around the installer queue popup/tab bar layout.

Could you please install the new build and test launching Cyanide normally on iPad, without using the Stage Manager/iPhone-size workaround? Release: {release_url}

If it still crashes, please attach the newest Cyanide/LiveContainer crash report from iOS Settings -> Privacy & Security -> Analytics & Improvements -> Analytics Data. The easiest search terms there are `Cyanide`, `LiveContainer`, and `JetsamEvent`.
```

## StatBar Needs Testing

Label: `status:needs-testing`

```markdown
I shipped `{version}` with a StatBar layout change for iPad landscape sizing/placement.

Could you please install the new build and test StatBar in portrait and landscape? Release: {release_url}

If it still rotates or places incorrectly, please reply with a screenshot and the StatBar options you had enabled.
```

## Themer Needs Testing

Label: `status:needs-testing`

```markdown
I shipped `{version}` with a Themer change targeting icons inside folders and explicit bundle-ID PNG preloading.

Could you please install the new build and test the same theme/apps again? Release: {release_url}

If icons still do not theme, please reply with the latest Cyanide chain log from the Log tab or Settings -> Share Log, plus a screenshot/list of the affected bundle IDs or theme folder filenames.
```

## iOS 17 Parked

Label: `status:parked-ios17`

```markdown
Thanks for the report. I am parking iOS 17-specific triage for now because I cannot test that version at the moment.

Please still attach any useful logs if you have them:

- Cyanide `chain-*.log` from the Log tab or Settings -> Share Log.
- Any matching device report from iOS Settings -> Privacy & Security -> Analytics & Improvements -> Analytics Data. Useful search terms are `Cyanide`, `SpringBoard`, `panic`, and `panic-full`.

I will come back to this once I can test iOS 17 again.
```

## Reporter Confirms Fixed

Close issue after commenting.

```markdown
Thanks for testing and confirming. I am going to close this one based on your result on `{version}`.
```

## Reporter Says Still Broken After Testing

Label: `status:investigating`

```markdown
Thanks for testing the new build. I will keep this open and move it back into investigation.

Could you please attach the latest Cyanide chain log from the failed run, plus any matching device report from Analytics Data around the same time? Useful search terms are `Cyanide`, `SpringBoard`, `panic`, and `panic-full`.
```
