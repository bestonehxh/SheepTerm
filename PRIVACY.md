# SheepTerm Privacy Policy

_Last updated: 9 October 2026_

SheepTerm is a terminal app for macOS (SSH, serial and local shell). It is
made by one developer and has no servers, accounts, analytics or advertising.

## What stays on your Mac

Hosts, groups, snippets, settings, session logs and command history are stored
in your own Mac's Application Support folder. Passwords are stored in your
macOS Keychain. None of this is sent to the developer.

## Sync with Google (optional, off by default)

If you choose **Sign in with Google** in Settings → Sync, SheepTerm:

- asks Google for access to **its own hidden app folder in your Google Drive**
  (`drive.appdata`) and your **email address** (to show which account is
  signed in). It cannot see, read or change any other file in your Drive;
- stores your hosts, groups, snippets, settings and saved passwords in that
  folder **encrypted on your Mac before upload** (AES-256-GCM), with a key that
  only your sync passphrase can unlock. Google stores the encrypted file; the
  developer never receives it and could not read it;
- keeps the Google sign-in token and the vault key in your Mac's Keychain.

Your sync passphrase never leaves your Mac. If you forget it, the synced data
cannot be recovered by anyone; you can reset sync and upload again from a Mac
that still has your data.

**Sign out** in Settings → Sync revokes SheepTerm's access to your Google
account. To delete the synced data, use **Reset Sync** before signing out, or
remove SheepTerm under *Manage apps* in your Google Drive settings
(drive.google.com → Settings → Manage apps → SheepTerm → Delete hidden app data).

SheepTerm's use of information received from Google APIs adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements.

## Network connections the app makes

- to the devices you connect to;
- to GitHub, to check for and download updates (can be turned off in Settings);
- to Google (accounts.google.com, oauth2.googleapis.com, www.googleapis.com),
  only after you sign in to Sync.

## Contact

Questions: open an issue at https://github.com/bestonehxh/SheepTerm/issues
