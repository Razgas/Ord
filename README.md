# Ord

A small, quiet dictionary for macOS, made for people learning a language. Choose the language you're learning and your own language in Settings; 44 languages are included. Danish ⇄ English has a specially tuned prompt.

Type, select, point at or say a word, and Ord shows what it means: the translation, a second meaning, how the word is built, its base form and a memory trick. Sentences you write in the language you're learning are checked and corrected.

- **Gemini** writes the explanation, in your own language, and decides by itself which way to translate.
- **Google**, **Bing** and **DeepL** (with your own free key) give short second opinions underneath.
- **Wiktionary** and the macOS **Dictionary** add meanings for single words.
- Every service can be turned on or off in Settings.
- Words and short sentences are **read aloud** with Google's natural voices.

## Ways to look something up

| | |
|---|---|
| ⌥D | Translate the selected text in any app |
| ⌥S | Drag a box around text on screen (works on images and PDFs) |
| ⌥⇧S | Translate a screen area in place: the text is replaced by its translation, like Google Lens. Space shows the original, ⌘C copies the picture, ⌘S saves it |
| ⌥A | Say a word or sentence, in Danish or English |
| Three-finger click | Translate the word under the pointer, no need to select it |
| Menu bar icon | Type something |
| `ord://translate?text=…`, `ord://image` | From scripts, Shortcuts or other apps |

Every shortcut can be changed in Settings: click it and press the new keys. Open Settings by right-clicking the menu bar icon.

## Install

Requires macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). The full Xcode is not needed.

```sh
git clone https://github.com/Razgas/Ord.git
cd Ord
./build.sh --install    # builds and copies Ord.app to ~/Applications
```

On first launch Ord asks for:

- **a Gemini API key**: free at [Google AI Studio](https://aistudio.google.com/apikey). It is stored only on your Mac.
- **Accessibility**: for reading the selected text and the word under the pointer.
- **Microphone and Speech Recognition**: for ⌥A.
- **Screen Recording**: for ⌥S.

`./build.sh` signs the app ad hoc. macOS then asks for permissions again after every rebuild. To avoid that, sign with your own certificate:

```sh
SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./build.sh --install
```

## How it works

| File | What it does |
|---|---|
| `Translator.swift` | Gemini (streamed) and the lookup session, history |
| `Services.swift` | Google, Bing, DeepL, Wiktionary and the macOS Dictionary |
| `ScreenSelect.swift` | The screen-area picker for ⌥S and ⌥⇧S |
| `ImageTranslate.swift` | ⌥⇧S: reads, translates and redraws the text of a screenshot, and the window that shows it |
| `Languages.swift` | The supported languages and how each service names them |
| `Prompt.swift` | The instructions Gemini follows, with fixed answer layouts |
| `Shortcuts.swift` | Shortcut recording and storage |
| `Markdown.swift`, `Views.swift` | Turn those layouts into native SwiftUI rows |
| `Panel.swift` | The Spotlight-style window, which never steals focus from the app you are in |
| `Input.swift` | Shortcuts, selection and screenshot text (Vision) |
| `Touch.swift` | Three-finger click; reads the finger count from the trackpad |
| `Voice.swift` | ⌥A speech recognition, Danish and English at once |

The three-finger click uses Apple's private MultitouchSupport framework, the same one used by apps like BetterTouchTool.

## Privacy and services

Ord has no server and collects nothing. Your API keys, settings and history stay in your Mac's preferences. The text you look up is sent to the services you have turned on in Settings:

- **Gemini** and **DeepL** through their official APIs, with your own keys.
- **Google Translate**, **Bing Translator** and Google's read-aloud voices through the free endpoints their websites use. These are not official APIs, so they can stop working or be rate-limited at any time. Each can be turned off in Settings.
- **Wiktionary** definitions are © Wiktionary contributors, under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

## License

MIT
