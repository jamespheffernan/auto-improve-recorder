# ASR pseudo-reference benchmark

Date: 12 August 2026

## Verdict

Keep the current Auto Send Recorder Nemotron 3.5 Q8 streaming model as the default. It stayed close to the archived transcription behavior, finished every fixed input, preserved the archived no-text behavior on all 10 applicable items, and passed the existing p95 finalization gate of 100 ms. One clip took 125.64 ms to finalize, so the maximum did not stay below 100 ms.

This is a behavioral compatibility result. It is not an accuracy result. The archived text was produced by older models and then saved after AIR product processing. It was not checked by a person against the audio. A disagreement can mean that the current model is worse, that it is better, or that product normalization or dictionary state changed.

The result supports “no large general regression relative to archived behavior.” It does not support a word-error accuracy claim or a “fastest in the game” claim.

## Fixed comparison

The earlier audit did not contain a selected 110-file manifest. It only defined a future human-curation target. This run therefore froze a new deterministic pseudo-reference set:

- 100 records with a non-empty archived `rawTranscript`, sampled in proportion to the eligible archived-engine and duration-band groups.
- 10 records with an empty transcript or an explicit no-speech marker, kept as a separate drift slice.
- Selection seed: `auto-send-pseudoref-v1`.
- Selected-item canonical SHA-256: `8f6be6fba4ad9892227cb13804290619745b4c03afb2c9c3e0a2857a8d0fa8d9`.
- Total audio: 1,441.6 seconds.
- Current model: `nemotron-3.5-asr-streaming-0.6b-q8_0.gguf`.
- Current path: the installed C API, Metal backend, 16 kHz mono conversion, 80 ms streaming chunks, and the same spoken-number normalizer used by Auto Send Recorder.

The append-only Transcript Truth index recovered the prior engine for records whose final `record.json` had lost that field. The selected set contains 43 older 110M Parakeet items, 43 older Parakeet 0.6B Metal items, 17 Whisper items, one ONNX Parakeet item, one OpenAI Realtime item, and five unknown no-text items.

No `cleanedTranscript`, improved output, or `finalTranscript` value was used as speech truth. The archived `rawTranscript` is itself post-dictionary and post-spoken-number product output. Thus, some measured drift can be product-pipeline drift instead of model drift.

## Main results

| Measure | Current result against archived raw pseudo-reference |
| --- | ---: |
| Completed | 110 / 110 |
| Normalized word drift | 8.26% |
| Normalized character drift | 4.92% |
| Word precision / recall / F1 | 94.13% / 93.42% / 93.77% |
| Substitutions / deletions / insertions | 116 / 68 / 47 |
| Normalized exact match | 29 / 100 spoken items |
| Raw exact match | 15 / 100 spoken items |
| Case agreement on aligned words | 97.21% |
| Punctuation-sequence precision / recall / F1 | 87.01% / 66.01% / 75.07% |
| No-text items that stayed at zero words | 10 / 10 |
| Dictionary-backed technical terms available for scoring | 0 |

The fixed set did not contain a dictionary snapshot term that also occurred in its archived raw transcript. Thus, the run cannot measure technical-term retention. It also has no verified accent or noise labels.

The punctuation measure compares only the order of punctuation characters. It does not check the word boundary at which punctuation appears. It must not be read as positional punctuation accuracy.

Product normalization reduced normalized word drift from 8.80% before normalization to 8.26% after normalization. It also raised normalized exact agreement from 27% to 29%. This is the comparable product-path result because archived `rawTranscript` had already passed product normalization.

## Results by archived engine

| Archived engine slice | Spoken items | Normalized word drift |
| --- | ---: | ---: |
| Parakeet 0.6B Metal, resident and non-resident combined | 43 | 6.36% |
| Parakeet 110M Q4 CPU | 43 | 9.74% |
| Whisper small.en | 12 | 13.68% |

The one-item ONNX and OpenAI slices are too small for a useful comparison. Five unknown-engine records belong to the no-text slice. The current model agrees most closely with the older 0.6B Parakeet family. This is the most relevant historical comparison, but 6.36% is still drift from an older model output, not measured speech error.

## Results by clip length

| Duration band | Selected items | Normalized word drift | Finalization p95 | Model and audio-pipeline RTF p95 |
| --- | ---: | ---: | ---: | ---: |
| At most 5 seconds | 48 | 17.78% | 59.30 ms | 0.145 |
| Over 5 and at most 20 seconds | 41 | 8.13% | 64.15 ms | 0.122 |
| Over 20 and at most 30 seconds | 7 | 2.56% | 35.22 ms | 0.121 |
| Over 30 and at most 120 seconds | 14 | 8.07% | 57.91 ms | 0.115 |

Short utterances are the weak point. Fifteen of the 20 largest divergences are at most five seconds long. Several contain only one to three archived words, so one missed word gives 33% to 100% drift. Human review of those short clips is the highest-value next accuracy step.

## Speed and memory

The model and audio pipeline processed the full 1,441.6 seconds of audio in 154.99 seconds of wall time, for an aggregate real-time factor of 0.108. The per-clip real-time factor was 0.108 at p50, 0.137 at p95, and 0.152 at p99. This timer includes audio-file read, conversion, streaming feed, and finalization. It excludes product spoken-number normalization.

Streaming finalization was 33.70 ms at p50, 59.30 ms at p95, 71.79 ms at p99, and 125.64 ms at maximum. Thus, the p95 result passed the 100 ms gate, but one clip exceeded 100 ms. These values measure the model flush after all audio chunks are fed. They do not include product spoken-number normalization, capture time, paste time, the safe 80 ms paste settlement, or application send time.

The child-process high-water reading was 2,353,266,688 bytes. It is a run-level child high-water value, not per-clip allocation data. It is consistent with the earlier short and 120-second resident-model observations, but it is not a new isolated memory profile.

## Largest divergence IDs

The private ignored evidence contains the old and new text. The durable table omits transcript content.

| Rank | Item | Band | Archived engine | Reference words | Edits | Word drift |
| ---: | --- | --- | --- | ---: | ---: | ---: |
| 1 | `D184415B-A101-479F-9994-39591C975A99` | short | Parakeet 110M | 3 | 3 | 100.0% |
| 2 | `52D63C37-0560-477A-817F-1CC96071E01D` | short | Parakeet 0.6B | 2 | 2 | 100.0% |
| 3 | `8B323AF8-4309-4110-9725-E65145F8555B` | short | Parakeet 0.6B | 2 | 2 | 100.0% |
| 4 | `A81DDF15-A86E-4604-A70E-A2301A7C0B67` | short | Parakeet 0.6B | 2 | 2 | 100.0% |
| 5 | `E411E5D5-E275-4017-9AEE-70A46FAD7048` | short | Parakeet 0.6B | 2 | 2 | 100.0% |
| 6 | `3D023B99-F937-49A4-BFBF-FD2FF55F4744` | short | ONNX Parakeet | 1 | 1 | 100.0% |
| 7 | `7D00229D-AF3D-4EE1-922A-CFD7EC021735` | short | Parakeet 0.6B | 1 | 1 | 100.0% |
| 8 | `95FB7AD1-499B-494D-BE2C-C627EDA3E8FE` | short | Parakeet 0.6B resident | 1 | 1 | 100.0% |
| 9 | `B24876C3-C73C-46A7-96A0-2ECB38EB69B0` | short | Parakeet 110M | 1 | 1 | 100.0% |
| 10 | `ED7B52BA-3706-44FA-B113-CF8128A6F26C` | short | Parakeet 0.6B | 1 | 1 | 100.0% |
| 11 | `70C7BD0D-7066-4116-B0C0-44A581FA9651` | short | Parakeet 110M | 3 | 2 | 66.7% |
| 12 | `A63E982B-5EAD-457C-886A-43EA70D8A93C` | short | Whisper | 10 | 5 | 50.0% |
| 13 | `28ABE984-977A-4F38-A3CF-D480C0C37789` | short | Parakeet 110M | 7 | 3 | 42.9% |
| 14 | `41AA50CA-979A-4A83-9A50-89641CCF5684` | short | Whisper | 8 | 3 | 37.5% |
| 15 | `9D6F07A5-28B9-40D2-ADAD-21E121A7C93C` | normal | Whisper | 26 | 7 | 26.9% |
| 16 | `E7CFAC2D-401C-4F17-9A51-5A16071487FC` | normal | Parakeet 0.6B | 15 | 4 | 26.7% |
| 17 | `AC25C320-6052-458E-9F4C-EB47E6E5BA32` | short | Parakeet 110M | 4 | 1 | 25.0% |
| 18 | `8B180C78-9438-429F-93D8-E013A15F0FE7` | long | Parakeet 110M | 51 | 12 | 23.5% |
| 19 | `F8827FC0-7BE9-4C11-9289-676650EA438B` | normal | Parakeet 0.6B | 17 | 4 | 23.5% |
| 20 | `0A9D2A76-C4AD-42E9-9C05-C742DB2F9AEC` | normal | Parakeet 110M | 13 | 3 | 23.1% |

## Repeatable commands

```bash
cd /Users/jamesheffernan/GitHub/auto-improve-recorder

python3 Bench/asr_pseudoref_benchmark.py prepare
shasum -a 256 -c .autoresearch/asr-pseudoref-benchmark/golden_checksums.txt
python3 Bench/asr_pseudoref_benchmark.py run --smoke
python3 Bench/asr_pseudoref_benchmark.py run
python3 Bench/asr_pseudoref_benchmark.py score
python3 -m unittest Bench/test_asr_pseudoref_benchmark.py
```

Ignored local evidence:

- `.autoresearch/asr-pseudoref-benchmark/input-manifest.json`
- `.autoresearch/asr-pseudoref-benchmark/golden_checksums.txt`
- `.autoresearch/asr-pseudoref-benchmark/full-current-output.json`
- `.autoresearch/asr-pseudoref-benchmark/per-clip.jsonl`
- `.autoresearch/asr-pseudoref-benchmark/summary.json`
- `.autoresearch/asr-pseudoref-benchmark/top-20-divergences-private.md`

The raw text remains in ignored local evidence. The durable report contains only record IDs and aggregate measurements.

## Recommendation

Keep the current ASR model. Do not change the default from this pseudo-reference result alone. First, listen to and correct the 15 short clips in the largest-divergence set. Then curate the remaining target references and run a true accuracy comparison against the current model and any challenger.

The installed older 0.6B and 110M files were not rerun as new candidates. They use the offline entry point, not Auto Send Recorder's live streaming path. Their actual archived outputs already provide the more relevant historical product baseline for this question.
