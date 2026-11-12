# VR Video Streamer

Stream your desktop monitor, application windows, local video files, music files and online videos to VR video players.

**[Download the latest version](https://github.com/Kubi-Cle/VR-Video-Streamer/releases/latest)**

<img src="branding/screenshot-1.2.1.png" alt="The VR Video Streamer window" width="700">

## Features

- Stream a desktop monitor, application windows, local video files, music files, or online video
- Search YouTube and queue videos while you're streaming
- Mix sound from several programs and devices, each with its own volume, and mute them on your PC
- Find subtitles online, generate them with AI, or translate them into your language
- Share a Video Player Link through Cloudflare, with a live preview of what viewers see
- Control playback from your phone with a remote control link, or open links with a QR code
- Reconnects by itself if the link drops, and updates itself in one click

## Get started

Needs Windows 10 (version 2004 or newer) or Windows 11, 64-bit.

1. Download `VR-Video-Streamer-1.2.6.zip` from the link above and extract it.
2. Open `VR Video Streamer.exe`. It offers to download FFmpeg, the video tool it needs, on first run.
3. Select the video and sound you'd like to stream.
4. Press **Start streaming** and paste the Video Player Link into a video player in your VR game.

Windows may show a warning because the program isn't digitally signed. [`README.txt`](README.txt) has the full steps and troubleshooting.

### Linux

A Linux version is in the [`linux`](linux) folder. It runs from source: download this repository and run `linux/vr-video-streamer`. It needs Python 3, GTK 4 with libadwaita, GStreamer with PipeWire and its GTK 4 plugin (for the preview), PipeWire's `pw-record` and FFmpeg, which most desktops have or can install from their package manager. If YouTube asks to confirm you're not a bot, turn on **Use my browser's YouTube sign-in** on the YouTube tab. Like the Windows version, it downloads its other tools the first time it streams.

Only stream what you have the right to share. Viewers can see everything on the screen or window you stream, including passwords and notifications, and links pass through Cloudflare. Some countries and internet providers block or slow down Cloudflare links at times, so some viewers may have trouble watching.

Need help? Press **Copy problem report** in the program and paste it into a [new issue](https://github.com/Kubi-Cle/VR-Video-Streamer/issues).

## Licence

Free for noncommercial use under the [PolyForm Noncommercial License 1.0.0](LICENSE). Bundled and downloaded tools keep their own licences, listed in [`THIRD-PARTY-NOTICES.txt`](THIRD-PARTY-NOTICES.txt).
