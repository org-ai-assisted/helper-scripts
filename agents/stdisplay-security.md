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

Not defended (inherent limitation, documented not fixed): low-contrast or
matching foreground/background COLOR (e.g. `ESC[30;40m`, `ESC[38;5;0;48;5;0m`,
`ESC[38;2;0;0;0;48;2;0;0;0m`) can hide text too. It is not reliably detectable
or preventable -- the viewer's real terminal background is unknown to the
sanitizer, so no color pair can be proven invisible (or proven safe). Blocking
color to chase contrast would break legitimate color without closing the gap. A
caller that must guarantee legibility of untrusted text disables SGR entirely
(`NO_COLOR` / `TERM=dumb`), which stdisplay honors.
