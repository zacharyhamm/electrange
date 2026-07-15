Electrange, an electric sheep for macOS.

A "desktop pet", based on the old "esheep.exe" for Windows. It was built by
tasking claude code (Opus 4.5) with porting functionality from
https://github.com/Adrianotiger/desktopPet over to macOS, and then lots of
iteration from there. It only supports the original eSheep animations (and only
a subset), and only walks around on the bottom of the screen, although it will
attempt to jump on your dock. Sometimes it will climb up the side of one of
your windows and walk along the top (as long as there's room for it to fit
below the top of the screen). If you have multiple displays it will wander
between them: walking across where their edges meet, dropping down to a lower
screen, or hopping up onto a slightly higher one. It makes me smile. There may
be more in the future.

Installation:

Currently you'll have to build it yourself with Xcode in order to run it. There
are no signed binary releases.

Chat provider keys can be entered in Electragne Settings. Gemini and
ollama.com API keys entered there are stored in the macOS Keychain. The
`GEMINI_API_KEY` and `OLLAMA_API_KEY` environment variables and the existing
key-file locations remain supported as fallbacks.

Google / Gmail and Calendar setup:

Electragne can connect multiple Google accounts and expose Gmail and Google
Calendar tools to its chat models. OAuth tokens and the OAuth
desktop client secret are stored in the macOS Keychain; the OAuth client ID is
stored locally in the app's preferences.

1. Create or select a project in the [Google Cloud Console](https://console.cloud.google.com/).
2. Configure the OAuth consent screen as **External** and **Testing**, then add
   every Google account you intend to connect as a test user.
3. Enable the **Gmail API** and **Google Calendar API** for the project.
4. Add the scopes `https://www.googleapis.com/auth/gmail.readonly` and
   `https://www.googleapis.com/auth/gmail.compose` to the consent screen.
   Also add `https://www.googleapis.com/auth/calendar.calendarlist.readonly`
   and `https://www.googleapis.com/auth/calendar.events`.
5. Under APIs & Services > Credentials, create an OAuth client with application
   type **Desktop app**.
6. Open Electragne Settings, paste the resulting client ID and client secret,
   and choose **Connect Account…**.

Accounts connected before Calendar support was added must use **Reconnect…**
once to approve the Calendar scopes.

The Gmail scopes are restricted Google scopes. The Testing configuration is
appropriate for personal use with explicitly listed test accounts. Public
distribution requires Google's OAuth verification process and the associated
privacy and data-handling disclosures.

A little screenshot:

![a screenshot showing the electric sheep in action](https://github.com/zacharyhamm/electrange/raw/main/screenshot.png)
