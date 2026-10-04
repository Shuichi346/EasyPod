# EasyPod UI image generation prompts

Generated with the built-in `image_gen` tool on 2026-10-04 (Asia/Tokyo). These are visual concepts; no application code has been implemented.

The current approval candidate is `easypod-ui-v5.png`, based on the user-provided visual reference. Earlier versions are retained for reference and are not implementation targets.

## v1 — original layout

```text
Use case: ui-mockup
Asset type: one approval-ready high fidelity native macOS application UI mockup, NOT a website, NOT code.
Create a realistic, production-quality interface with clear hierarchy, strong typography, purposeful spacing and restrained macOS 26 native materials. This is a simple Swift / SwiftUI podcast recording app named "EasyPod". The intended user records a podcast using a microphone, configures audio quality including bitrate, and sees local Japanese transcription while recording using the already installed NVIDIA NeMo-Speech.cpp Nemotron 3.5 model. This generation is a visual concept for user approval only.
Target dimensions: 1440 x 1024 landscape. Render exactly ONE fully visible app window, front-on, occupying nearly the entire image. Neutral unobtrusive surround only, no Mac device hardware, no perspective, no desk, no browser chrome, no explanatory headings outside the app. Keep all UI sharp and readable with realistic macOS desktop density.
Art direction: elegant, simple, quiet, polished native Mac app in LIGHT APPEARANCE for this preview, system San Francisco-style typography with appropriate Japanese glyphs. Off-white content, faint translucent sidebar and toolbar, dark charcoal primary text, cool gray secondary text, a muted teal audio waveform and input level, a restrained red recording indicator / stop button. System separators, generous whitespace, minimal rounded surfaces. Avoid nested cards, excessive borders, colorful gradients, sci-fi, opaque glass on every panel, dashboards, or complex DAW controls. The actual app will follow system light/dark mode, this single preview is light.
Layout: a compact flat left sidebar approximately 220 px, a broad primary recording workspace approximately 710 px, and a persistent right transcript column approximately 390 px, separated by hairline vertical dividers. Native window traffic lights at top left. Toolbar says "EasyPod", includes a small sidebar toggle and an unobtrusive gear button labeled "設定". No tabs advertising extra features.
Left sidebar: small heading "録音", a native row action "+ 新しい録音", and three flat recording list rows with one title and one secondary time line each. Current selected row "日曜日のポッドキャスト", subtitle "今日 · 録音中". Previous rows "週末のメモ" and "第1回 はじめまして", with secondary dates "10月3日 · 18:42" and "10月2日 · 24:15". Selected row uses the normal soft system selection highlight, not an individual card. Bottom understated text "すべてこのMacに保存".
Primary recording workspace: top-left editable session title "日曜日のポッドキャスト", small subtitle "2026年10月4日". Below it a concise microphone selector labeled "入力" and value "USBマイク" with a chevron. Centered recording focus: tiny red dot followed by "録音中", then a LARGE monospaced timer "00:12:34", then a clean teal live audio waveform on the base surface spanning most of this workspace. Under waveform, a slim readable input level meter and small label "入力レベル".
Below, one prominent red stop button with white square icon and exact label "録音を停止", and one secondary gray pause button labeled "一時停止". Buttons clearly distinct and comfortably clickable, not touch oversized.
Bottom of primary workspace: very subtle horizontal divider, a small concise audio quality summary "AAC · 192 kbps · 48 kHz · モノラル" and a small settings gear/link "音質設定". This summary makes bitrate discoverable, detailed quality controls live in the separate Settings window and are not shown here.
Right transcript column: heading "文字起こし" with a small, quiet green status dot and text "実行中". Text is airy, left aligned, at least 16 px equivalent and within comfortable line length. Three timestamped transcript paragraphs (timestamps tiny gray, body comfortably readable):
"00:11:48"
"今日は、日常の小さな発見について話していきます。"
"00:12:05"
"気軽に録音できると、思いついたことをその場で残せますね。"
"00:12:27"
"この番組では、そんな瞬間を少しずつ集めていきたいと思います。"
Below paragraphs, a small pale live interim line "話している内容を文字起こし中…". Bottom of transcript column a subtle footer "Nemotron 3.5" and "このMacで処理". No translation, speaker diarization, AI summary, multi-track editing, cloud accounts, publishing, paid plans, or extra features.
Text: render the quoted Japanese strings accurately and verbatim. Never add gibberish pseudo text. Do not show model file paths or developer technical details in the product flow.
Freshness: current date in Japan is 2026-10-04; all dates in mock data must be compatible with this date.
Output: exactly one refined coherent UI image, no multi-concept collage, no annotations, no watermark.
```

## v2 — icon transport and WAV export

```text
Use case: ui-mockup edit.
Edit the attached EasyPod native macOS UI concept. Preserve the entire existing visual design: the window dimensions and proportions, toolbar, left recording list, main title and date, microphone selector, large timer, teal waveform, input meter, and right Japanese live transcript column. Keep the same native macOS light appearance, typography, spacing, and restrained materials. This is a targeted refinement, not a redesign.
Make these exact changes:
1. Replace the two large text transport buttons at the bottom of the recording workspace with two compact, clearly recognizable ICON-ONLY circular macOS controls, centered beneath the input meter. Stop: a 64 px red circle containing a centered WHITE SOLID SQUARE stop icon. Pause: a 56 px light gray circle containing a centered charcoal TWO-VERTICAL-BARS pause icon. Leave a 24 px gap. REMOVE the persistent text labels "録音を停止" and "一時停止" entirely. Do not put those words below the buttons. They will have hover tooltips and accessibility labels in implementation, but no tooltip is visible in this screenshot.
2. In the upper-right window toolbar, add an ICON-ONLY export button using the familiar macOS square-and-up-arrow symbol, immediately to the LEFT of the existing settings gear. The export button is light gray / disabled while the active recording is in progress. The settings button should also be ICON-ONLY: retain its gear and remove the word "設定". No visible tooltip or labels in this screenshot.
3. Change the audio quality summary at the bottom of the recording workspace from AAC text to this exact text: "WAV · 24 bit · 48 kHz · モノラル". This app supports WAV export of the actual complete recorded audio; the export sheet is off-screen in this concept. AAC bitrate settings remain supported as an alternate export format in the actual app, but do not add another panel.
4. The bottom-right "音質設定" shortcut should also be ICON-ONLY, a small gear, with no persistent "音質設定" text.
Do not add any new panels, cards, explanatory legends, labels, save dialogs, additional screens, arrows, or annotations. Do not change or reword any other Japanese text. Preserve the three-column layout and all content outside the edited controls and audio quality summary. Current date in Japan is 2026-10-04. Output exactly ONE updated app mockup image, no watermark.
```

## v3 — VST3 / AU, selectable timing, default after recording

```text
Use case: ui-mockup edit.
Refine the attached EasyPod native macOS podcast recorder concept. Preserve its elegant light macOS visual style, three columns, Japanese recording list, title/date, microphone selector, large timer, teal waveform, input meter, right live Japanese transcription, and all ICON-ONLY transport and toolbar buttons from this attached image. The stop control MUST remain a red circle with white square, pause gray circle with two bars, without persistent text labels. Export is the square-and-up-arrow toolbar icon and Settings is a gear icon. Current date in Japan is 2026-10-04.
New product requirement: installed VST3 and AU audio EFFECT plug-ins can be applied either AFTER recording or DURING recording, selectable by the user. Default is AFTER recording. Original recorded audio is preserved. This screenshot shows the default AFTER-recording mode while recording, so no plugin is actually being applied to the live audio.
Add ONE compact, native-feeling "エフェクト" section within the CENTRAL recording workspace just BELOW the microphone selector and ABOVE the recording status/timer. Recompose vertical spacing inside the central workspace only as needed to fit elegantly; preserve all existing content and readable Japanese typography. Slightly reduce the timer/waveform vertical footprint if needed, never overlap or clip.
The effects section should have:
- a small header "エフェクト" at left;
- a native compact segmented control on the same header row, containing exactly "録音後" and "録音中", with "録音後" clearly selected;
- below, ONE flat, subtle empty-rack row, with a leading plus icon, exact text "VST3 / AU を追加", and a small right chevron. This is a discoverable action to select installed plugins. It is NOT a fake selected plugin and NOT a bulky dashboard card. No imaginary plugin brand names. No extra feature panels.
Keep the bottom audio summary exactly "WAV · 24 bit · 48 kHz · モノラル" and the nearby gear icon.
Ensure the recording controls remain comfortably centered, the interface has generous whitespace, and the effects UI doesn't compete with the main recording timer and transcript. One high fidelity, fully visible native app window, same proportions as the reference, no multi-screen collage, no device frame, no annotations, no watermark. Render exact Japanese strings accurately.
```

## v4 — arrangement of the user-provided reference

Source image: `user-reference-v4.png` (copied from `~/Desktop/M530FRN8.png`). The actual reference was attached to the image generation call.

```text
Use case: ui-mockup.
Edit target / primary visual reference: the attached image M530FRN8.png, a native Mac podcast recording application.
Primary request: Adapt THIS specific design for "EasyPod", preserving its composition and visual character. This is a UI design concept for approval, not an implementation. Output exactly ONE revised high fidelity native macOS app mockup.
Target dimensions: match the reference's 1168 x 880 landscape aspect ratio. Full app window visible, same flat front-on view and quiet gray surround. No device mockup, no browser, no annotations, no multi-screen collage.
PRESERVE: understated macOS light appearance, thin separators, subtle window shadow, compact titlebar and traffic lights; narrow recording list at left, broad center waveform workspace, right transcription pane, and the FULL-WIDTH COLLAPSIBLE AUDIO SETTINGS BAR at the bottom. Preserve the CORAL RED waveform, its faded edges, the red circular stop button, white circular pause button, and compact monospaced timer to the RIGHT of the buttons. Do NOT revert to a large centered timer or teal waveform from another concept. Keep typography and density similar to the attached source. Keep generous whitespace in the recording workspace.
Changes:
1. Native titlebar centered app title is exactly "EasyPod". Add a small ICON-ONLY square-and-up-arrow export control at the far right, then a gear settings icon. Export is subtly disabled in this recording-in-progress example. No button text labels.
2. Localize visible UI into clean, accurate JAPANESE. Sidebar heading "録音" with the existing plus icon. Retain seven flat recording rows, one small waveform symbol per row and a trailing ellipsis, selected first row faint pink. Example titles: "エピソード12", "インタビュー", "週末のメモ", "はじめまして", "日々の発見", "制作の裏側", "質問と回答". Selected first row secondary text "10月4日 · 42:17"; other plausible dates are 10月3日, 10月2日, 10月1日, 9月30日, 9月29日, 9月28日. Today is 2026-10-04 in Japan, not 2024.
3. Keep the TOP input controls in the center, in the source's horizontal arrangement: label "入力デバイス" above dropdown "USBマイク", label "入力レベル" above green/yellow/red meter, label "モニター" above native toggle, OFF in this example. These use source-like compact native controls.
4. Add ONE very compact effects strip beneath this input row and ABOVE the waveform. Align within the central pane. Header/label "エフェクト", then a small native segmented choice "録音後" and "録音中", with "録音後" SELECTED. A flat plus action "VST3 / AU を追加" on the strip or immediately beneath it. Keep this section quiet and lightweight, not a large card. This is an EMPTY effects rack, no invented selected plugins. These plugins can be added, reordered, bypassed and have their editor opened in the eventual app. Default processing is AFTER recording. User can choose DURING recording before capture begins. Do not add a mixer or DAW tracks.
5. Preserve source's broad coral red waveform as the visual focal point. Under it, the reference's compact horizontal transport arrangement: a red circular button with WHITE SOLID SQUARE stop symbol, white subtle-bordered circle with DARK PAUSE BARS, monospaced timer "00:42:17" to their right, small caption "録音中…" below the timer. Stop and pause buttons MUST remain ICON ONLY, no persistent action text below or beside them. The functional status text "録音中…" is permitted.
6. Right pane heading "文字起こし", trailing ellipsis, quiet pill with green status dot and text "Nemotron 3.5 · ローカル". Use three readable Japanese paragraphs with natural line breaks and similar rhythm to the source, not a huge heading or timestamps:
"今日は、気軽にポッドキャストを始める方法について話していきます。"
"特別なスタジオがなくても、マイクと伝えたいことがあれば、自分の声を残せます。"
"録音したあとで音を整え、WAVとして書き出せるので、制作を自分のペースで進められます。"
Add a subtle red live cursor at the end of the final paragraph, like the reference.
7. Preserve the FULL-WIDTH BOTTOM SETTINGS area, titled "録音・書き出し設定", with a disclosure chevron on the left and a small reset arrow icon on the right. Four compact evenly spaced controls separated by faint vertical rules, in the same general style as the reference:
- "ビット深度" dropdown, value "24 bit".
- "サンプルレート" dropdown, value "48 kHz".
- "形式" segmented control "WAV" and "M4A", WAV selected.
- "チャンネル" segmented control "モノラル" and "ステレオ", モノラル selected.
Accuracy: For uncompressed WAV, show bit depth instead of a freely chosen 192 kbps field. The eventual app will switch that first quality control to bitrate when M4A/AAC is chosen, but do not add explanatory developer text into the image.
Constraints: all quoted Japanese labels accurate; no extra features, subscriptions, cloud login, AI summary, instrument MIDI, multitrack editor, fake plugin logos, giant cards, or added decorative artwork. Preserve the source image's native Mac visual language and layout. Just one polished arranged version.
```

## v5 — WAV bit depth selector

```text
Use case: ui-mockup edit.
Edit the attached latest EasyPod native macOS app mockup. Preserve ALL existing layout, window proportions, Japanese labels, recording sidebar, input controls, effects section, selected 録音後 mode, coral red waveform, ICON-ONLY stop/pause transport and timer, right transcription, and full-width bottom recording/export settings.
Make exactly ONE targeted UI change: show the bottom-left "ビット深度" native popup dropdown OPEN, with its menu opening UPWARD directly above the existing field, staying entirely inside the app/image. The compact native macOS popup menu must show these three options on separate rows, accurately:
"16 bit"
"24 bit"
"32 bit float"
Put the standard checkmark on "24 bit" because it remains the default current selection. Keep the field value "24 bit". 16 bit and 24 bit represent integer PCM WAV, 32 bit float represents IEEE float WAV. Do not add explanatory labels or technical paragraphs into the UI.
The dropdown menu should be just wide enough for the options, aligned to the existing bit-depth field, with subtle native material/border/shadow. Avoid obscuring the primary stop/pause controls or any transcript. Keep the other settings unchanged: 48 kHz, WAV selected, モノラル selected.
This is a local UI design refinement for user approval, not a working app screenshot. Exactly one polished high fidelity image, no extra screens, no new controls, no change of theme, no watermark. Current date Japan 2026-10-04.
```
