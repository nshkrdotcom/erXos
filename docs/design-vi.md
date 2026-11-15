# vi, the screen editor

`vi` is the command shell's screen editor: an Erlang command that edits
one text file on the session's terminal, whichever master carries it,
`erx_term`'s window, a console line (the UART or the host link's
`console` line), an SSH channel or the web terminal. It behaves like
FreeBSD's nvi in the basics a user reaches for, and does no more in its
first version: "It does not need to be compatible and we don't need to
support the same edge cases, quirks, configs etc. Just needs to behave
similarly. Ok to do just do basics in the first version". The structure
is designed for Erlang, not translated from nvi.

Decisions every reader needs:

* **The screen is a value, and drawing is the difference of two
  screens.** The editor's state is one value; a pure function lays the
  visible part of it out as a screen, a tuple of rows of text that holds
  only characters that print; a second pure function turns the old screen
  and the new one into the bytes that change the terminal from one to
  the other. Nothing else writes to the terminal. A resize, a redraw on
  `^L`, a message, scrolling and the return from `fg` are therefore not
  cases of the drawing code: each produces a new screen, or forgets the
  old one, and the difference does the rest.
* **The text is a value, and undo keeps old values.** The buffer is a
  persistent tree of lines, so a change makes a new tree that shares every
  untouched part with the old one. Undo and redo move between whole
  earlier and later trees; no change records how to reverse itself.
* **Pending keys are the normal mode's state.** A normal-mode command is
  parsed from the keys typed since the last command, by one pure parser
  that answers a command, "more keys" or "no such command". There is no
  separate state for "waiting for a motion" or "waiting for a count".
* **The terminal is raw through the session's tty, and the shell puts it
  back.** `vi` sets the tty's `termios` through `erx_cmd:tty/2`, reads keys
  as a program does, and leaves the mode to the shell, which restores its
  own `termios` when a job ends or stops
  ([design-shell.md](design-shell.md#job-control)).
* **A file's bytes stay exact, and reach the screen only as text that
  prints.** The buffer keeps every byte of the file, invalid UTF-8 and
  control characters included, and writes them back unchanged. What the
  line escape of [design-live.md](design-live.md#attributed-text) would
  change is drawn as a visible form, so no byte of a file becomes a
  terminal control.

## Context

The command shell runs Erlang commands that follow FreeBSD's utilities
([design-shell.md](design-shell.md#commands)); `vi` is the first that
takes the whole screen. Its behavioural reference is nvi as FreeBSD 15.1
ships it in `contrib/nvi`, BSD-licensed, read for this design at tag
`release/15.1.0` (commit `96841ea08dcfa84b954a32dc5ae1a26c28966cf4`;
files and SHA-256 in [References](#references)). nvi's manual names what
a new user needs (`man/vi.1:167-318`, "FAST STARTUP"): `h j k l`, the
arrow keys, `/`, `a i o O`, escape, `yy p dd x`, `:w`, `:w file`, `:q`
and `:q!`. The first version takes that list, the motions and operators
that make it useful, undo, search and substitution.

The session's terminal is a tty owned by the session's terminal relay
([design-live.md](design-live.md#the-tty)). An Erlang command's terminal
stream is an open of that tty, as a program's is, so it reads and sets
the tty's `termios`, asks its size and reads keys as a program does
([design-shell.md](design-shell.md#interfaces)). That is the whole of
what `vi` asks of the system beyond files.

Toybox has a `vi` applet; the build leaves out every toybox applet whose
name an Erlang command of the system release declares
([design-shell.md](design-shell.md#commands)), so toybox's `vi` is never
built and `vi` names this command in the session and in every program's
`/bin`.

## Requirements

* **VI-R1.** The commands of [The first version](#the-first-version)
  behave as nvi's do: given the same file and the same keys, `vi` writes
  the same file, apart from the differences listed there.
* **VI-R2.** `vi` works on every master of a session's tty and follows
  the terminal's size as it changes.
* **VI-R3.** A file's bytes are untrusted. Any file within the bounds
  loads, displays and writes back byte-exact; no file makes `vi` crash,
  grow past its bounds or put a control on the terminal; a file beyond
  the bounds is refused with a message.
* **VI-R4.** However `vi` ends, by `:q`, a crash or the end of its job,
  the tty's `termios` is the shell's again.
* **VI-R5.** The editing logic is pure and tested on the host, its key
  parser exhaustively.

Non-goals of the first version: visual mode, macros and named buffers
(registers other than the one unnamed buffer), marks, more than one file
or window, tags, `:set` and `.exrc`, key maps and abbreviations,
recovery files, the ex scripting language and `:g`, filtering through
programs (`!`), `ex` as a line editor, and a search used as an operator's
motion (`d/re`).

## The first version

**Starting.** `vi` or `vi FILE`. Any other argument is a usage error.

**Normal mode.** A count before a command repeats or scales it, as in
nvi:

| Keys | Action |
| --- | --- |
| `h`, `l`, `j`, `k`, the arrow keys, Backspace, Space | left, right, down, up |
| `w`, `b`, `e` | next word start, previous word start, word end |
| `0`, `^`, `$` | line start, first non-blank, line end |
| `G`, `gg` | line N, or the last line for `G` and the first for `gg` |
| `^F`, `^B` | a screen forward, back |
| `i`, `a`, `I`, `A`, `o`, `O` | insert before, after, at the first non-blank, at the end, on a new line below, above |
| `x` | delete characters |
| `dd`, `yy`, `cc` | delete, yank, change lines |
| `d`, `y`, `c` with a motion | delete, yank, change the text the motion covers |
| `p`, `P` | put the unnamed buffer after, before |
| `u` | undo; again, redo |
| `.` | repeat the last change, or the last undo |
| `/RE`, `?RE`, `n`, `N` | search forward, back, again, again the other way |
| `:` | an ex command |
| `ZZ` | write if modified, and quit |
| `^G` | the file's status on the message line |
| `^L`, `^R` | redraw |
| `^Z` | stop the job |
| Escape, `^C` | cancel the command being typed |

A word is a run of letters, digits and underscores (`man/vi.1:539-540`),
and a run of other characters that are not blanks is a word too, which the
nvi oracle tests check ([Verification](#verification)). Any other key rings the
bell and does nothing, as nvi beeps at a command it does not have
(`man/vi.1:215-216`).

**Insert mode.** Text typed is inserted; Return splits the line;
Backspace erases the last character typed in this insert, `^W` the last
word and `^U` all of it; Escape ends the insert, and so does `^C`. An
insert's count repeats its text (`3ix` Escape inserts `xxx`). An arrow
key ends the insert and then moves, so the text typed so far is one
change.

**Ex commands.** An address is a line number, `.`, `$`, either followed
by `+N` or `-N`; a range is one address, two separated by `,`, or `%`.

| Command | Action |
| --- | --- |
| `:N` | go to line N |
| `:w`, `:w FILE`, `:w!` | write the file, or another; `!` overrides the checks below |
| `:q`, `:q!` | quit; `!` discards changes |
| `:wq`, `:x` | write, quit; `:x` writes only if modified |
| `:e FILE`, `:e!` | edit another file; `:e!` reloads the current one, discarding changes |
| `:f`, `:file` | the file's status, as `^G` shows it |
| `:[range]s/RE/TEXT/[g]` | substitute in each line of the range, the current line by default; `g` replaces every match, not only the first |

The ex line takes printable characters at its end, Backspace, `^W` and
`^U`; Return runs it; Backspace on an empty line, Escape and `^C` cancel
it. `:f` exists because console lines keep `^G` for their menu
([design-live.md](design-live.md#the-console)), so `^G` never reaches a
session there.

**Patterns** are POSIX basic regular expressions, nvi's default
(`man/vi.1:319-335`), translated to `re` by `erx_grep_re`, the translator
`grep` uses ([design-shell.md](design-shell.md#text-commands)), and
matched with grep's match limits. An empty pattern repeats the last one.
In `TEXT`, `&` is the match, `\1` to `\9` its groups, and a backslash
makes the next character itself. Searches wrap around the end of the
file, as nvi's `wrapscan`, on by default, does (`man/vi.1:2613-2614`),
and say `Search wrapped` when they do.

**Undo** follows nvi (`vi/v_undo.c:74-81`, `:117-126`). `u` undoes the
last change; a second `u` redoes it; `.` immediately after `u` undoes, or
redoes, one more change in the same direction, so `u.....` walks back
through the history. A new change drops what was undone. An insert, a
put with a count and a substitution over a range are each one change.

**Writing** follows nvi's checks and messages (`common/exf.c`):

* the file is written in place, opened for writing and truncated
  (`exf.c:830-831`), and every line is written with a newline after it,
  as nvi writes one after every line it writes (`ex/ex_write.c:332-337`);
* `:w FILE` naming an existing file other than the one being edited is
  refused with `FILE exists, not written; use ! to override`
  (`exf.c:779`);
* a file changed since `vi` read or last wrote it is refused with
  `FILE: file modified more recently than this copy; use ! to override`
  (`exf.c:821`), judged by its size and modification time;
* success says `FILE: N lines, M characters`, or `FILE: new file: N
  lines, M characters`, with `M` the bytes written, as nvi counts them
  (`exf.c:968`, `:974`; `ex_write.c:333-337`);
* `:q` and `:e` of a modified buffer are refused with `File modified
  since last complete write; write or use ! to override`, and `write or
  use :edit! to override` for `:e` (`exf.c:1328-1329`).

**The message line** is the screen's last row. It shows the ex line or
search being typed, the last message, and `Insert` at its right end
while inserting. A message longer than the row is cut at a character
boundary. `^G` and `:f` show `FILE: [Modified] line L of N --P%--`, with
`[Modified]` only when the buffer has changes and `[New file]` for a file
that does not exist yet.

**Differences from nvi**, each a choice for this version and each pinned
by a test:

* `gg` goes to the first line; nvi has no `g` command (`vi/v_cmd.c:403-404`)
  and uses `1G`, which works here too.
* Escape cancels an ex line; nvi runs it (`man/vi.1:706-709`). A half-typed
  `:w!` or `:e!` is never run by the key meant to leave it.
* `.` in a pattern matches one byte, since patterns run in `re`'s byte mode
  ([Patterns and invalid UTF-8](#patterns-and-invalid-utf-8)).
* The mode shows on the message line; nvi's `showmode` is off by default
  (`man/vi.1:2519-2522`), and `:set` is not offered to turn it on.
* A file over the bounds is refused ([Bounds](#bounds)); nvi edits a file
  of any size.
* nvi keeps a recovery file and preserves changes on a hang-up; `vi` does
  not, so a hang-up loses unwritten changes.

## What the code does today

No `vi` exists. `erx_cmd`
(`erlang/apps/erx_shell/src/erx_cmd.erl`) gives a command `read/1` and
`read_line/1` only over a pipe from a neighbouring Erlang stage, and
refuses every other input (`no_input/1`, lines 115-119); the shell's
runner hands every command a null standard input and the terminal's write
function as its standard output (`erx_shell_runner.erl:90`). `columns/1`
and `rows/1` read `COLUMNS` and `LINES` and then `io:columns/0` and
`io:rows/0` (lines 129-162). The terminal stream as a relay open,
`tty/2`, `watch/1`, the terminal form of `read/1`, the size report and
`stop/1` are the interfaces of [design-shell.md](design-shell.md#interfaces)
this design builds on.

## Overview

```text
 terminal master ── tty (terminal relay, erx_tty) ── vi's open
                                                       │
     {erx_cmd, ready} ─┐                               │
     {erx_cmd, winch} ─┼─> erx_cmd_vi: the loop  ──────┘ erx_cmd:write/2
     escape timer    ──┘     │          ▲
                             ▼          │ effects: files, bell, timer, stop, quit
                      erx_vi:step(Event, State) -> {State, [Effect]}
                             │
                      erx_vi_view:screen(State) -> Screen
                      erx_vi_screen:diff(Old, New) -> bytes
```

Modules, all in the `erx_shell` application:

* `erx_cmd_vi`, the command: it checks the terminal, makes it raw, reads
  the file, and runs the loop, which carries out effects and draws. It is
  the only module that does I/O.
* `erx_vi`, the core: the state and `step/2`, the one entry for every
  event.
* `erx_vi_text`, the buffer: the tree of lines and the edits on it.
* `erx_vi_keys`: bytes to keys, and keys to normal-mode commands.
* `erx_vi_ex`: the ex line's parser and its commands.
* `erx_vi_view`: the screen from the state.
* `erx_vi_screen`: the bytes that turn one screen into another.

## Invariants

| Invariant | Holds because | Violation looks like | Test |
| --- | --- | --- | --- |
| **VI1.** The terminal gets from `vi` only text that prints and `vi`'s own fixed sequences | only `erx_vi_screen:diff/2` produces terminal bytes, from screens whose rows `erx_vi_view` builds only of printable characters, visible forms and spaces | a file's ESC, C1 control or bidirectional override reaching the master | the output check below over the fuzz corpus; seeded: a view that copies a line's bytes raw |
| **VI2.** A file changes only by a write, and a write puts back the buffer's bytes exactly | `erx_vi_text` keeps lines as the file's bytes; only the write effect touches a file | a file's invalid UTF-8, NUL or CR changed by a round trip | load then `:w` over the corpus compares bytes; seeded: a load that decodes and re-encodes lines |
| **VI3.** `vi` never leaves the tty raw | the shell restores its own `termios` when a job ends or stops, whatever ended it | a prompt that echoes nothing after `vi` crashes | the QEMU case kills `vi` mid-edit; seeded: the shell's restore removed |
| **VI4.** `vi`'s memory is bounded | the bounds of [Bounds](#bounds), each checked before the change that would pass it | a stage killed at `max_heap_size` with unwritten changes | the bound tests; seeded: a put whose size is not checked |
| **VI5.** `step/2` is total and the cursor always names a place in the buffer | every command is a function from a valid state to a valid state; a refused one returns the state unchanged with a bell | a crash on a key, or a cursor past a line's end after `dd` | the exhaustive exploration; seeded: `x` on an empty line that leaves the column at 1 |
| **VI6.** Undo returns exactly an earlier buffer | history entries are earlier values of the buffer | `u` after `:s` leaving one line changed | the exploration's undo property; seeded: a change that edits a shared node in place |

## Data model

**The buffer.** `erx_vi_text` holds the file's lines as a balanced tree.
A leaf is a binary of up to 4 KiB of whole lines, each followed by its
newline, with its line count; an inner node holds the line and byte
counts of its two subtrees. Line N is found by descending on line counts,
in time logarithmic in the number of lines and linear in a leaf. An edit
rebuilds the leaves it touches and the path above them and shares the
rest. A leaf is copied out of the file's binary when it is built, so no
leaf keeps the whole file alive.

An empty file has no lines, as in nvi, and the buffer presents it as one
empty line that does not exist until text is put in it: a write of that
buffer writes nothing. This is one rule inside `erx_vi_text`; every
motion and command sees at least one line.

**Units.** Within a line, the cursor moves by **units**. A unit is a
valid UTF-8 sequence together with the zero-width characters that follow
it, or one byte that does not begin or continue a valid shortest UTF-8
sequence. Zero width is `erx_width`'s, the system's one width table
([design.md](design.md#decisions)), and a character the line escape
changes is never zero width, since it is drawn as a visible form. So a
combining accent moves with its base, and a stray byte is a unit of its
own.

**The state** of `erx_vi` is one record:

* the buffer, its file name, the file's size and modification time when
  read or last written, and whether the buffer is modified;
* the cursor, a line and a unit index, and the wanted column that `j` and
  `k` keep, `$` setting it to the line's end;
* the top of the window, a line and a screen row within that line, so a
  line longer than the screen scrolls by rows like any other;
* the mode: `normal`, with the pending keys; `insert`, with the text
  typed and where the insert started; or `prompt`, with its kind (`:`,
  `/` or `?`) and the line typed so far;
* the key decoder's unfinished bytes;
* the unnamed buffer: lines or characters, and their text;
* the history: earlier states of the buffer and cursor, and the undone
  ones, with the direction of the last `u`;
* the last change, as a command value, for `.`;
* the last pattern and direction, for `n` and `N`;
* the message, and the terminal's size.

**A screen** is a tuple of rows, each a binary of what the row shows,
with its width in columns, and the cursor's row and column. A row holds
only characters that print, spaces and visible forms.

## The core

`erx_vi:step(Event, State)` returns the next state and a list of
effects. Events:

* `{bytes, Bytes}`: what one read of the terminal returned;
* `escape_timeout`: the end of the wait after a lone Escape;
* `{size, Rows, Columns}`: the terminal's size, at the start, after a
  resize and after `fg`;
* `{written, Result}` and `{loaded, Name, Result}`: what a write or read
  effect did.

Effects: `bell`; `{timer, Ms}` and `cancel_timer`;
`{write, Name, Bytes, Guard}` and `{read, Name}`; `stop`; `quit`. The
loop draws once after the events of one read, so a paste of 4 KiB
redraws once.

**Keys.** `erx_vi_keys:decode(Bytes, Pending)` turns bytes into keys:
each UTF-8 character, each control character, and each sequence the
terminals send for the arrows, Home, End, Delete, Page Up and Page Down,
in their `CSI` and `ESC O` forms
([design-display.md](design-display.md#the-terminal-emulator)). An
Escape that may begin a sequence waits: the core asks for a 100 ms timer,
nvi's default `escapetime` of one tenth of a second
(`man/vi.1:2335-2340`), and the Escape is a key on `escape_timeout` or on
a byte that cannot continue a sequence. An unknown sequence is one
unknown key, which rings the bell. Invalid UTF-8 typed is one unknown key
per byte.

**Normal mode.** `erx_vi_keys:parse(Keys)` reads the pending keys as
`[count] [operator [count]] motion` or a command of its own, and answers
`{command, Command, Rest}`, `more` or `{refused, Rest}`. A count holds at
most nine digits, and two counts multiply, so `2d3w` deletes six words
(`man/vi.1:548-551`). A command is a value, such as
`#{op => delete, count => 3, motion => word_end}`; `erx_vi` applies it.
`d`, `c` and `y` doubled act on lines (`dd`, `cc`, `yy`), as a repeated
operator does in nvi (`man/vi.1:536-538`). Escape and `^C`
with keys pending drop them. A motion is a function from the buffer and
cursor to a place and a kind, by character or by line, and an operator
acts on the text between the cursor and that place, as nvi's motions and
operators do. `j`, `k`, `G`, `gg` and `^F`/`^B` are line motions, so
`dj` deletes two lines.

**Changes and `.`.** Every change is a command value, with the text an
insert typed recorded in it when the insert ends. `.` applies the last
change again at the cursor, with its own count if one is typed. After
`u`, `.` repeats the undo instead, as in nvi.

**Undo.** Before each change the core pushes the buffer and cursor onto
the history. `u` swaps the current buffer with the top of the history, or
of the undone list when its direction is forward. Because the buffer is a
persistent tree, an entry costs only the leaves its change replaced.

**Prompts.** `:`, `/` and `?` start a prompt; the prompt's line is edited
by the keys above; Return hands it to `erx_vi_ex` or to the search. A
search moves the cursor to the next match in the direction asked,
wrapping, or says `Pattern not found`. A pattern `erx_grep_re` refuses
shows the refusal's message.

**Ex.** `erx_vi_ex:parse(Line)` returns a range and a command, or a
message. The commands are pure functions of the state, except that `:w`,
`:wq`, `:x`, `ZZ` and `:e` return effects and finish when the result
arrives: `{write, Name, Bytes, Guard}` with `Guard` `{unchanged, Stat}`
for the file being edited, `absent` for another name, or `none` under
`!`; the loop checks the guard against the file's state just before
writing and returns `{written, {error, changed}}` or
`{written, {error, exists}}` when it fails. `:q` after a write that
fails does not quit.

**Substitution** runs the compiled pattern over each line of the range,
building each new line from the pieces of the old and the replacement
text. A replacement holding a newline is not offered; `\` before Return
cannot be typed into the prompt. A substitution that would pass a bound
changes nothing and says so.

## Drawing

`erx_vi_view:screen(State)` lays out rows from the top of the window
down, wrapping each line at the terminal's width, as nvi does with
`leftright` off, its default (`man/vi.1:2385-2388`). A unit's cells are:

* a tab: spaces to the next multiple of 8 columns, nvi's `tabstop`
  (`man/vi.1:2535-2536`);
* a C0 control or DEL: `^` and a character, `^A` or `^?`, as nvi shows
  them (`common/key.c:271-280`);
* any other character, or byte, that the line escape changes: the line
  escape's token, `<U+202E>` or `<0xC0>`, from `erx_text:escape_line/1`
  ([design-live.md](design-live.md#attributed-text)), where nvi shows
  `‮` (`key.c:300-305`);
* otherwise the character itself, `erx_width` columns wide.

The line escape decides what is not shown as itself, from the one table
of `abi/terminal.txt`, so `vi`, the console and every other display
agree on which characters are controls. A visible form is made of ASCII
characters that print, each one column, so it may wrap within a token;
a width-2 character that does not fit at a row's end starts the next
row. Rows past the end of the buffer show `~`. The window's top moves
the least that keeps the cursor's row on the screen.

The last row is the message line. A screen of fewer than 2 rows or 2
columns shows nothing new and waits for a resize; keys still act. A
terminal larger than 256 rows or 1,024 columns is laid out in its top
256 rows and left 1,024 columns, the rest left blank, which bounds the
screen value.

**The bytes.** `erx_vi_screen:diff(Old, New)` writes, for each row that
differs, the cursor's move to the row's start, the row's text and erase
to the end of the line; then the cursor's move to its place. It hides
the cursor around the rows and shows it after. Forgetting the old screen
draws everything: the loop starts with a blank screen of the terminal's
size, and `^L`, a resize and the return from `fg` each clear the
terminal and forget the old screen. The sequences are a fixed set that
every master's terminal understands without terminfo, all in `erx_vt`'s
table ([design-display.md](design-display.md#the-sequences)): `CSI ?
1049 h` and `l` to enter and leave the alternate screen, `CSI row ; col
H`, `CSI K`, `CSI 2 J`, `CSI ? 25 l` and `h`, and BEL for the bell.

## The command at the edge

`erx_cmd_vi:run/2`:

1. Refuses unless standard input and standard output are both the
   terminal (`erx_cmd:isatty/2`), with `vi: not a terminal` and status
   1. A redirected stream, a command domain and the system shell each
   answer `enotty` from `tty/2`
   ([design-shell.md](design-shell.md#interfaces)), so `vi` runs in a
   session's own domain, at its terminal.
2. Reads the file, if one is named, through the session's namespace
   (`erx_cmd:path/2` and `file:open/2`, as `cat` does), at most the file
   bound plus one byte. A file that does not exist is a new file. A file
   over a bound, a directory or a read that fails ends `vi` with
   `vi: FILE: reason` on standard error and status 1, before the screen
   is touched.
3. Reads the `termios` with `tty(Ctx, tcgetattr)`, sets it raw with
   `{tcsetattr, Raw}` (`ICANON`, `ECHO`, `ISIG`, `IEXTEN`, `ICRNL`,
   `IXON` and `OPOST` clear, `VMIN` 1 and `VTIME` 0, as `cfmakeraw` sets
   them), opts in to size reports with `erx_cmd:catch_events([winch])`
   and asks `tty(Ctx, winsize)`.
4. Enters the alternate screen and runs the loop inside `try ... after`,
   whose `after` leaves the alternate screen, so a crash leaves the main
   screen as it was. It does not restore the `termios`: the shell does
   when the job ends (VI3).

**The loop** is one `receive`:

* `{erx_cmd, ready}`: `erx_cmd:read/1` takes the waiting bytes, at most
  4 KiB, which the core gets as `{bytes, Bytes}`; the loop then asks
  `erx_cmd:watch/1` for the next report;
* `{erx_cmd, winch}`: `erx_cmd:requested(winch)` drops reports that
  arrived meanwhile, `tty(Ctx, winsize)` gives the size, and the core gets
  `{size, Rows, Columns}`;
* the escape timer's message: `escape_timeout`.

After each event the loop carries out the effects in order and draws the
new screen with `erx_cmd:write/2`. A write to the terminal waits while
the tty is stopped, as any writer's does
([design-live.md](design-live.md#the-tty)).

**`^Z`.** With `ISIG` clear, `^Z` is a key. The core returns `stop`;
the loop leaves the alternate screen, moves the cursor to the last row,
and calls `erx_cmd:stop/1`, which returns once the job is continued by
`fg` or `bg` ([design-shell.md](design-shell.md#job-control)). The shell
keeps `vi`'s raw `termios` for `fg` and restores it then. The loop
re-enters the alternate screen, asks the size, since a size report goes
only to the foreground job, and draws everything.

## Bounds

`vi` runs as one Erlang stage within the command shell's default
`max_heap_size` of 4 MiB, binaries included
([design-shell.md](design-shell.md#the-language)). The bounds keep it
within that:

| What | Bound | Beyond it |
| --- | --- | --- |
| a file read | 1 MiB | refused at the start with `file too large`; at `:e`, the message and the buffer kept |
| a line | 64 KiB, the bound of `erx_cmd:read_line/1` | a file holding one is refused as above; an insert, put, join or substitution that would make one changes nothing and says `line too long` |
| the buffer | 2 MiB | a change that would pass it changes nothing and says `file too large` |
| the history | the leaves it alone holds, at most 1 MiB | the oldest entries are dropped, and `u` past them says `No more changes to undo` |
| a count | nine digits | the tenth digit rings the bell; a count past the text stops at its end |
| an ex line or pattern | 4 KiB | further keys ring the bell |
| a read of the terminal | 4 KiB | the rest waits in the tty |
| a pattern's match | grep's match limits | the search or substitution stops with `pattern too complex` and changes nothing |
| the screen laid out | 256 rows by 1,024 columns | the rest of the terminal stays blank |

Every check is made before the change is applied, from the sizes the
tree keeps, so a refused change leaves the state as it was and nothing
grows past a bound first. The 64 KiB line bound also bounds the work of
laying out the cursor's line, which is linear in its length.

## Patterns and invalid UTF-8

`erx_grep_re` compiles in byte mode, so a pattern matches any line,
valid UTF-8 or not, and never fails on its subject. A literal non-ASCII
character in a pattern matches its bytes; `.` matches one byte, so it
matches part of a multi-byte character, a documented difference. A
search moves the cursor to the unit that holds the match's first byte.

## Concurrency and failure

`vi` is one process. Keys, size reports and the escape timer arrive as
messages to its one `receive`, so no state is shared and no event can
interleave with another's handling. A file read or write runs in the
loop and blocks it; a slow file server delays `vi`, and the keys typed
meanwhile wait in the tty.

| Failure | What remains | What the user sees |
| --- | --- | --- |
| a write fails, wholly or part way | the file as far as written; the buffer, still marked modified | the error on the message line; `:wq` does not quit |
| `vi` crashes | the file as last written | the main screen back, the shell's prompt with the tty cooked, the crash as the stage's status |
| the job is killed or the session hangs up | the file as last written | unwritten changes are lost |
| the stage passes `max_heap_size` | as a crash | as a crash; the bounds make this a bug |
| the tty is stopped (a session detached) | everything | `vi` waits in its write and goes on when connected |
| a substitution runs long | everything | no key interrupts it, since `^C` is a key and is read after it; the bounds limit it to the match limits over at most 2 MiB |

## Security

`vi` runs in the session's own domain with the session's authority, as
any command the user types does (SH1 of
[design-shell.md](design-shell.md#invariants)), and touches only the
files the user names through the session's namespace. A file is
untrusted input: it is bounded before it is held (VI4), kept as bytes
(VI2), and shown only through printable forms (VI1). File names on the
message line go through the line escape, as the names `ls` prints at a
terminal do ([design-live.md](design-live.md#attributed-text)). Keys
come from the session's own terminal and are bounded per read and per
command. Patterns pass through `erx_grep_re`'s bounds and grep's match
limits. The key decoder, the ex parser and the path from file bytes to
screen rows each have a fuzz target.

## Verification

**Host tests of the core** (`erx_vi_*`, no I/O):

* **The key parser, exhaustively:** every key string of up to five keys
  over an alphabet of the first version's command keys, a digit other
  than `0`, Escape and one key no command uses. Each string parses to
  commands and `more` with nothing left over, every complete command is
  in the command table, every proper prefix of a command answers `more`,
  and a string with Escape ends with nothing pending. Seeded: `d` made a
  command of its own, which leaves `dw` parsing as two commands.
* **The editor, explored:** every sequence of up to four commands from a
  set covering each mode change, motion, operator, put, undo and `.`,
  over buffers of zero, one and three lines that include an empty line, a
  tab, a wide character, a combining mark and a stray byte. After each
  step the cursor names a place in the buffer; `u` after a change gives
  the buffer before it, and `u` twice gives the buffer after it. Seeded:
  `x` at the end of a line that leaves the cursor past it; a history entry
  that shares a leaf edited in place.
* **nvi as the oracle:** a corpus of key scripts, each a file and the keys
  of an editing session ending in `:wq`, runs in nvi on the FreeBSD 15.1
  oracle guest, on a pseudo-terminal driven by the harness as the
  `Ctrl-T` oracle test drives one
  ([design-shell.md](design-shell.md#verification-and-testing)), and in
  `vi` on the host through `erx_vi` alone. The written files compare byte
  for byte; each difference is a listed difference with its test or a
  bug. Scripts cover every command of the first version, counts, undo
  with `.`, wrapping searches and substitution with `&` and groups.
  Seeded: `p` of lines that puts them above the cursor's line, where
  nvi appends them after it (`man/vi.1:275-276`).
* **Drawing against the terminal emulator:** for screens produced by
  random editing sequences, feeding `erx_vt` the bytes of
  `diff(Old, New)` on a grid that shows `Old` gives a grid that shows
  `New`, with the cursor where the screen puts it. Seeded: a diff that
  leaves out the erase to the end of the line, which leaves old text
  behind on a row that shrank.
* **The output check:** over the fuzz corpus of file bytes, including
  every C0 and C1 control, ESC and CSI sequences, OSC 8 strings,
  bidirectional overrides and invalid UTF-8, the bytes `vi` writes parse
  as text that prints and the fixed sequence set, with nothing else.
  Seeded: a view that copies one line's bytes unchanged.
* **Round trip:** loading and writing each corpus file, with no edit,
  gives its bytes, with a newline added only where the last line had
  none. Seeded: a load through `unicode:characters_to_binary/1`.
* **Bounds:** a 1 MiB file plus one byte, a 64 KiB line plus one byte, a
  put with a count that would pass 2 MiB, and a history past 1 MiB, each
  with its message and the state unchanged. Seeded: the put's check
  removed, which the stage's heap limit then ends.
* **Write guards:** `:w` of a file another writer changed is refused, and
  `:w!` writes; `:w` to an existing other name is refused. Seeded: the
  guard compared on size alone, with a same-size change.
* **Fuzz targets:** `erx_vi_keys:decode/2`, `erx_vi_ex:parse/1`, and the
  load-and-layout path from file bytes to a screen, each checking VI1 and
  the screen's shape.

**QEMU test** (track S's suite, on a session over the host link's
`console` line): `vi /tmp/f` from the session, keys typed by the
harness, `:wq`, then `cat /tmp/f` shows the edit; the harness's console
reports a new size and the next screen fits it; `^Z` gives the prompt
with the tty cooked (`stty` shows `icanon`), `fg` redraws and editing
goes on; `vi` killed by a seeded fault leaves the prompt working. Seeded:
the shell's restore of its `termios` removed, which leaves the prompt
without echo.

## Performance

Each event redraws by comparing the new screen with the old, row by row.
At 80 by 24 that is about 2 KB of work and, for a full redraw, about 2 KB
of output. A one-line scroll changes every row, so on a console line at
115,200 bit/s it rewrites the screen, about 170 ms (unmeasured). Scrolling
with the terminal's own scroll commands when the new screen is the old
one shifted would send one row instead; that waits for a measurement on
the [performance watch list](todo-performance.md).

## Open decisions

* **A larger file bound.** The default stage heap of 4 MiB holds files up
  to 1 MiB. A larger bound needs a command to declare a larger
  `max_heap_size`, which [design-shell.md](design-shell.md#the-language)
  does not offer. Recommendation: keep 1 MiB in the first version, and add
  a per-command heap declaration to `erx_cmd` when a user meets the bound.
* **`vi` from a program or under `within`.** A command domain's streams
  are copied bytes, so `tty/2` answers `enotty` there and `vi` refuses:
  `xargs vi` and `within /etc -- vi rc.conf` do not work.
  Recommendation: accept it for the first version; a narrowed editor
  needs a tty open that crosses to the command domain, a design of its
  own.

## References

* FreeBSD 15.1, `contrib/nvi`, tag `release/15.1.0`, commit
  `96841ea08dcfa84b954a32dc5ae1a26c28966cf4`, fetched from
  `raw.githubusercontent.com/freebsd/freebsd-src`, read as data:
  * `man/vi.1`, SHA-256
    `a1a3fd05f21132b350f99b95a999f000eee3fca3c1155f3b72cfb42cce21feea`;
  * `vi/v_cmd.c`, SHA-256
    `1e33e325b91228923a9be64e2fd9f62e06597c2a5b5783865e72846b8e20bdfb`;
  * `vi/v_undo.c`, SHA-256
    `e8c8602cf28a06ee4757a9dfa987fec8f3e24cd672779ca9b4321ca487f31313`;
  * `common/exf.c`, SHA-256
    `fba181c37bd44e0dbf15fe44de7ba5ef8e5075093080dc581b0e27df4b7fb28c`;
  * `common/key.c`, SHA-256
    `2c2616c8aac1ca2d6ef39ea710d205c478ba596fa812cc0c6ef4fd4206e359a8`;
  * `ex/ex_write.c`, SHA-256
    `b0adc1490e0b18c91d3f348919a294a6a4be80befc837906e30eae1f745a8742`.
* [design-shell.md](design-shell.md): Erlang commands, `erx_cmd`, job
  control and the size report.
* [design-live.md](design-live.md): the tty, the line discipline and the
  line escape.
* [design-display.md](design-display.md): `erx_vt`, its sequences and
  the width table.
