# stdisplay

## Line-based vs whole-input processing

`stcat`/`stcatn`/`sttee` sanitize line-by-line (streaming, like their Unix
counterparts). `stsponge` sanitizes the whole input at once (sponge semantics).
These are equivalent because no allowed escape sequence can contain `\n` -- SGR
is composed solely of digits, semicolons, colons, and the `m` terminator. This
is inherent to the SGR spec, documented in the man page (`man/stdisplay.1.ronn`).

## Visual spoofing vs injection: the allow-list boundary

SGR (`ESC [ ... m`) is the only escape class stdisplay passes; every other class
-- OSC (incl. hyperlink and clipboard OSC 52), DCS, APC, PM, SOS, and non-SGR
CSI such as cursor moves and erase -- is neutralized. Pure SGR is render-only:
it cannot move the cursor, run a command, reach the clipboard, or make the
terminal reply. So the allow-list defends against escape-sequence INJECTION, not
against text merely styled to mislead.

Two SGR attributes are parameterless, unambiguous "hide" toggles, so they are
excluded despite being render-only:

- conceal (`8`): hides text outright.
- inverse (`7`): swaps foreground/background.

Their resets (`27`/`28`) stay -- they only reveal text.

Not defended (documented, not blocked): COLOR can hide text by rendering it on a
matching background. Two sub-cases differ in detectability:

- EXPLICIT same-encoding foreground+background (e.g. `ESC[38;5;5;48;5;5m`,
  `ESC[38;2;1;2;3;48;2;1;2;3m`, `ESC[30;40m`) IS reliably invisible AND, in
  principle, detectable by parsing -- both sides carry the same value, so it
  does not depend on the viewer's background.
- Foreground alone matching the viewer's CONFIGURED background, or a
  cross-encoding pair that coincides only under the terminal's (unknown) palette
  (e.g. `ESC[30m` foreground vs `ESC[48;5;0m` background), is NOT detectable
  here.

Still not blocked, deliberately: stripping only the detectable same-encoding
subset is a partial gate that gives false assurance while the undetectable
vectors above stay open; detecting even that subset needs a semantic SGR parser
(reordering, zero-padding, colon/semicolon, split sequences), not the clean
pure-regex allow-list; and it breaks legitimate fg==bg use. The robust guarantee
for untrusted text is to disable SGR entirely (`NO_COLOR` / `TERM=dumb`), which
stdisplay honors.

Kept despite a weaker spoof argument: blink (`5`) and strike (`9`) leave text
fully READABLE -- blink flickers it, strike only decorates it -- so they are not
the hide/swap class that `7`/`8` were. The "styling could editorialize a
verdict" concern applies equally to color, bold and italic; it is not specific
to these two codes, so they stay allowed.
