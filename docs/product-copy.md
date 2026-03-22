# Product Copy

This document standardizes the user-facing copy introduced in this pass. The goals are:

- use one primary phrase for each state
- keep HUD, status line, onboarding, and diagnostics aligned
- explain why tracking stopped or why attached mode fell back

## Tracking States

| State | UI Label | Status Line | Use Case |
| --- | --- | --- | --- |
| `tracking` | `Tracking` | `Tracking: {word}` or `Tracking your script` | Normal on-script advancement. |
| `uncertain` | `Checking Script` | `Heard you. Checking the script before moving.` | Speech was detected, but it is not yet safe to advance. |
| `aside` | `Aside` | `Aside active. Tracking is paused while you hold.` or `Aside mode is on. Tracking is paused.` | Manual aside mode or temporary ignore. |
| `lost` | `Off Script` | `Off script. Waiting to lock back on.` | Repeated misses have frozen advancement until the script is reacquired. |

## Attached Short Copy

These strings are intended for the HUD, `statusLine`, and attached diagnostics.

| Scenario | Copy |
| --- | --- |
| No target window selected | `No target window selected; using screen corner` |
| Accessibility not granted | `Accessibility off; using screen corner` |
| AX failed but Quartz is available | `Using visible window bounds (AX fallback)` |
| Accessibility is granted but the target window is unreadable | `Can't read selected window; using screen corner` |
| Target window lost | `Target window lost; back to screen corner` |
| User chose hidden fallback | `Target window unavailable; overlay hidden` |

## Attached Long Copy

These strings are intended for onboarding, diagnostics, and QA logging.

| Scenario | Copy |
| --- | --- |
| No target window selected | `Choose a target window to attach to. Until then, Textream will stay in the screen corner.` |
| Accessibility not granted | `Attached Overlay needs Accessibility access before it can follow another app window. Textream will stay in the screen corner until access is granted.` |
| AX attached successfully | `Attached using Accessibility geometry for {target}.` |
| Quartz fallback | `Accessibility geometry is unavailable for {target}. Textream is following the visible window bounds instead.` |
| Accessibility granted but target unreadable | `Accessibility is enabled, but macOS is not exposing usable geometry for {target}. Textream is staying in the screen corner.` |
| Target window lost | `The selected window is no longer available. Textream moved back to the screen corner.` |
| Hidden fallback | `The selected window is unavailable, so the overlay was hidden by the attached fallback setting.` |

## Onboarding Copy

| Location | Copy |
| --- | --- |
| Title | `Allow Accessibility for Attached Overlay` |
| Body | `Attached Overlay needs Accessibility access before it can follow another app window. Until access is granted, Textream will stay in the screen corner.` |
| Primary button | `Open System Settings` |
| Secondary button | `Continue with Fallback` |

## Launch Guide Copy

| Location | Copy |
| --- | --- |
| Title when not in attached mode | `Accessibility unlocks Attached Overlay` |
| Title when currently in attached mode | `Attached Overlay is using screen-corner fallback` |
| Body when not in attached mode | `If you want Textream to follow another app window, grant Accessibility before you use Attached Overlay. Until then, Textream will fall back to the screen corner instead of silently failing.` |
| Body when currently in attached mode | `Accessibility is still off, so Textream cannot lock onto other app windows yet. Attached Overlay will stay in the screen corner until you allow access.` |
| Secondary button | `Review Attached Setup` |
| Dismiss button | `Later` |

## Terminology Rules

- Use `screen corner` consistently instead of mixing it with `screen-corner fallback`.
- Use `Off Script` externally instead of exposing `Lost`.
- Use `Checking Script` externally instead of exposing `Uncertain`.
- The word `fallback` is acceptable in QA and diagnostics, but product-facing copy should prefer phrases such as `using screen corner` or `using visible window bounds`.
