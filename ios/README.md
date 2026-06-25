# VelvetVoice — native iPhone app

A true **hands-free two-way voice** companion for iPhone. Unlike the web version,
this uses Apple's native **`SFSpeechRecognizer`** (speech-to-text that actually
works on iOS) and **`AVSpeechSynthesizer`** (spoken replies), with the audio
session set up for **Bluetooth** headsets/car. You speak, it thinks, it talks
back, then listens again — looped, no buttons.

Replies come from **OpenRouter** using your own API key and one of three
tested-working uncensored models (Lunaris 8B, Mistral Nemo, MythoMax L2 13B).

---

## What you need
- This Mac (Xcode 26 is already installed ✅)
- Your iPhone + a USB-C/Lightning cable (or same Wi-Fi for wireless)
- A **free** Apple ID (good enough to run on your own phone; the app re-signs
  every 7 days. A paid $99/yr Apple Developer account removes that limit.)
- Your OpenRouter API key

## Install it on your iPhone (one time, ~10 min)
1. **Open the project:** double-click `ios/VelvetVoice.xcodeproj` (or run
   `open ios/VelvetVoice.xcodeproj`).
2. **Add your Apple ID** in Xcode ▸ Settings ▸ Accounts ▸ **+** ▸ Apple ID.
3. Click the **VelvetVoice** target ▸ **Signing & Capabilities**:
   - Check **Automatically manage signing**
   - **Team:** pick your name (Personal Team)
   - If it complains the bundle ID is taken, change **Bundle Identifier** to
     something unique, e.g. `com.yourname.velvetvoice`.
4. **Plug in your iPhone.** Pick it from the device menu at the top of Xcode
   (next to the scheme). Unlock the phone and tap **Trust** if asked.
5. Press **▶︎ Run** (⌘R). It builds and installs to your phone.
6. First launch only — the phone blocks untrusted developers. On the iPhone:
   **Settings ▸ General ▸ VPN & Device Management ▸** tap your Apple ID ▸ **Trust**.
   Then tap the app icon again.

## Use it
1. Pair your **Bluetooth** (AirPods / car / speaker) in iOS **Settings ▸ Bluetooth** first.
2. Open VelvetVoice, paste your **OpenRouter key**, tap **Save**.
3. Pick a model (Lunaris 8B is the reliable default).
4. Tap **START VOICE CHAT** and allow **Microphone** + **Speech Recognition**.
5. Just talk. Pause ~1 second and it sends; the reply plays through your
   Bluetooth, then it listens again. Tap **STOP** to end.
   (You can also type in the box at the bottom anytime.)

## Notes
- Your API key is stored only on the device (UserDefaults). It is never in the
  code or the repo.
- Want to regenerate the Xcode project from `project.yml`:
  `cd ios && xcodegen generate`.
- Background audio mode is enabled so it keeps going with the screen locked
  (handy in the car).
