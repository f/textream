# Textream App Store submission drafts

This directory contains working copy for an initial Mac App Store submission. Nothing here proves that an app record, build, page, screenshot, price, region, or submission is live.

## Metadata

The English (U.S.) draft is in `metadata/en-US/`:

- `name.txt` — 8 characters; App Store limit 30.
- `subtitle.txt` — 29 characters; App Store limit 30.
- `description.txt` — long description; App Store limit 4,000 characters.
- `keywords.txt` — 88 characters; App Store limit 100 bytes.
- `promotional_text.txt` — 160 characters; App Store limit 170.
- `support_url.txt`, `privacy_url.txt`, and `marketing_url.txt` — public web destinations.
- `copyright.txt` — proposed rights-holder line.
- `review_notes.txt` — draft testing instructions for App Review.

The privacy and support URLs will be valid only after `docs/privacy.html` and `docs/support.html` are deployed to the canonical Textream site. Verify all three URLs in a signed-out browser before entering them in App Store Connect.

## Build-dependent statements

Before using this copy, verify the submitted archive itself:

- App Store builds do not run or expose the GitHub update checker.
- App Store builds do not expose an external donation or purchase link.
- No analytics, advertising, tracking, crash-reporting, account, or developer backend was added.
- Microphone, speech-recognition, and local-network purpose strings match actual behavior.
- Remote and Director modes remain optional and local-network-only.
- Review Notes steps work from a clean install with the permissions reset.

If any point changes, update the description, review notes, privacy policy, and App Privacy answers together.

## Account-holder decisions and attestations

The account holder must review and personally confirm the following in App Store Connect:

- final app name, subtitle, description, keywords, and SKU;
- the exact copyright owner name and the right to publish all app content;
- the App Privacy questionnaire in `app-privacy.md` against the uploaded binary;
- export-compliance answers, including whether the build uses exempt encryption only;
- age-rating questionnaire answers;
- price, availability regions, and release method;
- EU Digital Services Act trader status and any required public contact details;
- App Review contact name, email address, and phone number;
- all current developer agreements and tax or banking requirements;
- the final screenshots and any accessibility or product claims;
- the final **Submit for Review** action.

Do not replace these attestations with assumptions from source code or an earlier build.
