# Pronunciation Dictionary Guide

Podgen supports per-podcast pronunciation dictionaries via ElevenLabs PLS files.
Drop a `pronunciation.pls` file in `podcasts/<name>/` and it will be applied to all
TTS requests automatically.

## Quick start

1. Create `podcasts/<name>/pronunciation.pls` (see format below)
2. Run `podgen generate <name>` — the dictionary is uploaded on first run
3. Edit the PLS file anytime — changes are detected via SHA256 and re-uploaded

The dictionary ID and version are cached in `podcasts/<name>/pronunciation.yml`.
Delete this file to force a re-upload.

## PLS file format

PLS (Pronunciation Lexicon Specification) is a W3C XML standard. Each `<lexeme>`
maps a written word (grapheme) to either a pronunciation (phoneme) or a
replacement spelling (alias).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<lexicon version="1.0"
    xmlns="http://www.w3.org/2005/01/pronunciation-lexicon"
    alphabet="ipa" xml:lang="en-US">

  <lexeme>
    <grapheme>UTXO</grapheme>
    <alias>you tee ex oh</alias>
  </lexeme>

</lexicon>
```

## Rule types

### Alias rules (recommended)

Replace the written word with an alternative spelling that the TTS already
pronounces correctly. Works with **all ElevenLabs models** and **all languages**.

```xml
<lexeme>
  <grapheme>sats</grapheme>
  <alias>sahts</alias>
</lexeme>
```

Use aliases when:
- The word is an acronym that should be spelled out (UTXO, YJIT)
- The word has a non-obvious pronunciation (Schnorr, Kamal)
- The TTS stresses the wrong syllable (use a phonetic respelling)

### IPA phoneme rules

Specify exact pronunciation using IPA (International Phonetic Alphabet) symbols.
**Only works with:** `eleven_flash_v2`, `eleven_turbo_v2`, `eleven_monolingual_v1`.
Does **not** work with `eleven_multilingual_v2` (the default model).

```xml
<lexeme>
  <grapheme>Nostr</grapheme>
  <phoneme>ˈnɒstɹ̩</phoneme>
</lexeme>
```

## IPA quick reference

| Symbol | Sound | Example |
|--------|-------|---------|
| ˈ | primary stress (before syllable) | ˈbɪt.kɔɪn |
| ˌ | secondary stress | ˌlaɪt.nɪŋ |
| ː | long vowel | biːt |
| ə | schwa (unstressed "uh") | sətˈɒʃi |
| æ | "a" in "cat" | sæts |
| ɑː | "a" in "father" | sɑːts |
| ɔɪ | "oi" in "coin" | kɔɪn |
| ɪ | "i" in "bit" | bɪt |
| iː | "ee" in "see" | fiːs |
| ʃ | "sh" in "ship" | ʃnɔːr |
| tʃ | "ch" in "chip" | tʃeɪn |
| ŋ | "ng" in "ring" | maɪnɪŋ |
| θ | "th" in "think" | iːθ |
| ð | "th" in "this" | ðə |
| ʒ | "s" in "measure" | ʒɑːnrə |
| dʒ | "j" in "judge" | dʒɛm |
| ɹ | English "r" | ɹæktə |

Full IPA chart: https://www.internationalphoneticassociation.org/IPAcharts/IPA_chart_orig/chart.html

## Tips

- **Case-sensitive.** `Bitcoin` and `bitcoin` are separate entries — add both if needed.
- **Max 3 dictionaries** per TTS request (ElevenLabs limit). Podgen uses 1.
- **Alias over IPA** unless you're using a monolingual/turbo model. Aliases are
  simpler to write, easier to debug, and work across all models.
- **Test first.** Generate a short episode or use `scripts/test_tts_timestamps.rb`
  (modify the TEXT constant) to hear how a word sounds before and after adding a rule.
- **Compound terms.** For multi-word terms like "Lightning Network", add the
  full phrase as the grapheme — single-word matches also work within longer text.
- **Non-English podcasts.** Change `xml:lang` to match (e.g. `sl-SI` for Slovenian).
  Use alias rules only — IPA phonemes are English-only.
