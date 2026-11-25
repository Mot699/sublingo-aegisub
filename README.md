# SubLingo Translate for Aegisub

An Aegisub automation script that translates dialogue lines with [sublingo.cc](https://sublingo.cc/tools/aegisub-translate-plugin?ref=github) (AI translation), without leaving Aegisub.

- Keeps override tags (`{\an8}`, `{\i1}` …), `\N` line breaks, styles and timing.
- Translate selected lines or every dialogue line.
- Four output modes: replace (keep the original as a comment), replace, or bilingual with the original or the translation on top.
- 30 target languages in the menu.
- Free for 2,000 lines a day, no account. Heavier use takes a sublingo credit pack.

## Install

1. Download [`sublingo-translate.lua`](sublingo-translate.lua).
2. Copy it into Aegisub's `automation/autoload` folder:
   - Windows: `%APPDATA%\Aegisub\automation\autoload\`
   - macOS: `~/Library/Application Support/Aegisub/automation/autoload/`
   - Linux: `~/.aegisub/automation/autoload/`
3. Restart Aegisub, or use **Automation → Rescan Autoload Dir**.

## Use

**Automation → SubLingo: Translate subtitles**, pick the target language, scope and mode, then OK.

The script calls `curl`, which ships with Windows 10+, macOS and most Linux distributions.

## Privacy

The dialogue text of the lines you translate is sent to `https://sublingo.cc/api/translate`. Nothing else in the file (styles, timing, file name) is sent.

## Status

Version 1.0.0. It has been tested against the live API with a simulated Aegisub environment; please [open an issue](../../issues) if something breaks in your Aegisub build, with your OS and Aegisub version.

Disclosure: this script is made by the people who run sublingo.cc.

## License

MIT
