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
  persistent tree of the file's bytes in chunks, which counts the
  newlines in each, so a change makes a new tree that shares every
  untouched chunk with the old one. Every change is one operation, the
  replacement of a range of bytes. Undo and redo move between whole
  earlier and later trees; no change records how to reverse itself.
* **One budget holds everything `vi` keeps.** The buffer, the history,
  the unnamed buffer and the text `.` repeats are charged to one budget of
  held text, and every change is checked against it before it is made, so
  editing never brings the stage to its heap limit.
* **Pending keys are the normal mode's state.** A normal-mode command is
  parsed from the keys typed since the last command, by one pure parser
  that answers a command, "more keys" or "no such command". There is no
  separate state for "waiting for a motion" or "waiting for a count".
* **The terminal is raw through the session's tty, and `vi` puts it
  back.** `vi` sets the tty's `termios` through `erx_cmd:tty/2`, reads keys
  as a program does, and sets back the `termios` it found when it returns
  or fails, so the next command of the same line starts cooked; the shell
  restores its own `termios` when a job ends or stops, which covers a
  `vi` that is killed
  ([design-shell.md](design-shell.md#job-control)).
* **A file's bytes stay exact, and reach the screen only as text that
  prints.** The buffer keeps every byte of the file, invalid UTF-8,
  control characters and a missing final newline included, and writes
  them back unchanged. What the line escape of
  [design-live.md](design-live.md#attributed-text) would change is drawn
  as a visible form, so no byte of a file becomes a terminal control, and
  every file name `vi` prints, on its message line or on standard error,
  goes through the line escape too.

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
  behave like nvi's in ordinary editing: for each script of the oracle
  corpus, a file and the keys of an editing session, `vi` writes the same
  file as nvi, apart from the differences listed there. nvi's exact
  messages, its rare edge cases and its quirks are not obligations; a
  difference the corpus finds is fixed or listed.
* **VI-R2.** `vi` works on every master of a session's tty and follows
  the terminal's size as it changes.
* **VI-R3.** A file's bytes are untrusted. Any file within the bounds
  loads, displays and writes back byte-exact; no file makes `vi` crash,
  grow past its bounds or put a control on the terminal; a file beyond
  the bounds is refused with a message.
* **VI-R4.** However `vi` ends, by `:q`, a crash or the end of its job,
  the tty's `termios` is the shell's again. When `vi` returns or fails, a
  command after it on the same line starts with the `termios` `vi` found,
  and the main screen is back; when it is killed, the alternate screen
  stays until the operator runs `reset`, as on UNIX
  ([design-live.md](design-live.md#the-tty)).
* **VI-R5.** The editing logic is pure and tested on the host, its key
  parser exhaustively.
* **VI-R6.** `vi` changes the terminal's modes and draws only while its
  job is in the foreground.

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
  (`exf.c:830-831`), and gets the buffer's bytes; a last line that had no
  newline is written without one, where nvi writes a newline after every
  line (`ex/ex_write.c:332-337`);
* `:w FILE` naming an existing file other than the one being edited is
  refused with `FILE exists, not written; use ! to override`
  (`exf.c:779`);
* a file changed since `vi` read or last wrote it is refused with
  `FILE: file modified more recently than this copy; use ! to override`
  (`exf.c:821`), judged as nvi judges it, by the file's identity and
  modification time (`exf.c:807-820`), with its size added
  ([The command at the edge](#the-command-at-the-edge) says what this
  catches);
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
* A file whose last line has no newline is written without one; nvi adds
  it. A file `vi` creates, or an empty one it fills, ends in a newline, as
  in nvi.

## What the code does today

No `vi` exists. `erx_cmd`
(`erlang/apps/erx_shell/src/erx_cmd.erl`) gives a command `read/1` and
`read_line/1` only over a pipe from a neighbouring Erlang stage, and
refuses every other input (`no_input/1`); the shell's
runner hands every command a null standard input and the terminal's write
function as its standard output (`erx_shell_runner.erl:90`). `columns/1`
and `rows/1` read `COLUMNS` and `LINES` and then, when a standard stream
is the terminal, the size the terminal holds. `catch_events/1`,
`requested/1`, the shell's delivery of `{erx_cmd, winch}` and `stop/1`
exist. The terminal stream as a relay open, `tty/2`, `watch/1`, `read/2` and
the terminal form of `read/1`, which need the session's terminal relay and
its line discipline `erx_tty`, are the interfaces of [design-shell.md](design-shell.md#interfaces)
this design builds on.

## Overview

```text
 terminal master ── tty (terminal relay, erx_tty) ── vi's open
                                                       │
  {ready, Open, _, _} ─┐                               │
     {erx_cmd, winch} ─┤                               │
     escape timer    ──┼─> erx_cmd_vi: the loop  ──────┘ erx_cmd:write/2
     match helper    ──┘     │          ▲
                             ▼          │ effects: files, matching, bell,
                                        │          timer, stop, quit
                      erx_vi:step(Event, State) -> {State, [Effect]}
                             │
                      erx_vi_view:screen(State) -> Screen
                      erx_vi_screen:diff(Old, New) -> bytes
```

Modules, all in the `erx_shell` application:

* `erx_cmd_vi`, the command: it checks the terminal, makes it raw, reads
  the file, and runs the loop, which carries out effects and draws. It is
  the only module that does I/O, and the only one that starts a process,
  the match helper of a search or substitution.
* `erx_vi`, the core: the state and `step/2`, the one entry for every
  event.
* `erx_vi_text`, the buffer: the tree of chunks, its one edit and the
  held-text budget.
* `erx_vi_keys`: bytes to keys, and keys to normal-mode commands.
* `erx_vi_ex`: the ex line's parser and its commands.
* `erx_vi_view`: the screen from the state.
* `erx_vi_screen`: the bytes that turn one screen into another.

## Invariants

| Invariant | Holds because | Violation looks like | Test |
| --- | --- | --- | --- |
| **VI1.** The terminal gets from `vi` only text that prints and `vi`'s own fixed sequences | only `erx_vi_screen:diff/2` produces terminal bytes, from screens whose rows `erx_vi_view` builds only of printable characters, visible forms and spaces | a file's ESC, C1 control or bidirectional override reaching the master | the output check below over the fuzz corpus; seeded: a view that copies a line's bytes raw |
| **VI2.** A file changes only by a write, and a write puts back the buffer's bytes exactly | `erx_vi_text` keeps the file's bytes, a missing final newline included, and changes them only by replacing a range; only the write effect touches a file | a file's invalid UTF-8, NUL, CR or missing final newline changed by a round trip | load then `:w` over the corpus compares bytes; seeded: a load that decodes and re-encodes lines, and a write that adds a final newline |
| **VI3.** `vi` never leaves the tty raw | `vi` sets back the `termios` it found when it returns or fails, and the shell restores its own when a job ends or stops, whatever ended it | a prompt that echoes nothing after `vi` is killed; `cat` after `vi f;` on one line reading in raw mode | the QEMU cases kill `vi` mid-edit and run `vi f; cat`; seeded: the shell's restore removed, and `vi`'s own restore removed |
| **VI4.** `vi`'s memory is bounded | everything `vi` keeps is charged to the held-text budget, and every change is charged before it is made ([Bounds](#bounds)) | a stage killed at `max_heap_size` with unwritten changes | the worst-case shapes under the declared heap; seeded: a put whose size is not charged |
| **VI5.** `step/2` is total and the cursor always names a place in the buffer | every command is a function from a valid state to a valid state; a refused one returns the state unchanged with a bell | a crash on a key, or a cursor past a line's end after `dd` | the exhaustive exploration; seeded: `x` on an empty line that leaves the column at 1 |
| **VI6.** Undo returns exactly an earlier buffer | history entries are earlier values of the buffer | `u` after `:s` leaving one line changed | the exploration's undo property; seeded: a change that edits a shared node in place |
| **VI7.** `vi` changes the terminal's modes and draws only in the foreground | it sets its raw `termios` before it draws everything, at the start and after `stop/1` returns, and `tty/2`'s `tcsetattr` from a job not in the foreground stops the job until `fg` ([design-shell.md](design-shell.md#interfaces)) | `vi &`, or `bg` after `^Z`, drawing over the prompt | the QEMU cases `vi f &` and `^Z` then `bg`; seeded: a `tcsetattr` that goes through in the background |

## Data model

**The buffer.** `erx_vi_text` holds the file's bytes as a balanced tree
of **chunks**. A chunk is a binary of 2 to 4 KiB of the file's bytes,
with the number of newlines in it; only a buffer smaller than 2 KiB has a
shorter chunk, its only one. A chunk is cut anywhere, so a line may run
across chunks, and a line of any length within the bounds has a place.
An inner node holds the byte and newline counts of its two subtrees.

The buffer has one edit, `replace(From, To, Bytes)`: the bytes from
offset `From` up to `To` become `Bytes`. Every change, an insert, a
delete, a put, a join or a substitution, is a list of such replacements
made in one step. A replacement takes the bytes of the chunks it touches,
splices `Bytes` in, takes in a neighbouring chunk when the result is
under 2 KiB, and cuts the result into the fewest chunks of at most
4 KiB, whose sizes differ by at most one byte, so each is 2 KiB or more; it rebuilds the path
above them and shares every other chunk. Every chunk is a fresh binary,
cut by `binary:copy/1`, so no chunk keeps a larger binary, the read
buffer of a file or a line of the old text, alive.

**Lines.** Line N starts after the N-1th newline, found by descending on
newline counts, and runs to its own newline or to the end of the buffer;
gathering it reads the chunks it spans. A buffer that does not end in a
newline has a last line without one, and line edits keep that: deleting
or adding a last line moves the missing newline with it, so `dd` on `b`
of `a`, newline, `b` leaves `a` with no newline, and a write gives the
file back as it came when nothing touched its end.
An empty buffer, a new or empty file, shows one empty line; the first
text put in it is followed by a newline, so a file `vi` creates ends in
one, as nvi's do. This is one rule inside `erx_vi_text`; every motion and
command sees at least one line.

**Units.** Within a line, the cursor moves by **units**. A unit is a
valid UTF-8 sequence together with the zero-width characters that follow
it, or one byte that does not begin or continue a valid shortest UTF-8
sequence. Zero width is `erx_width`'s, the system's one width table
([design.md](design.md#decisions)), and a character the line escape
changes is never zero width, since it is drawn as a visible form. So a
combining accent moves with its base, and a stray byte is a unit of its
own.

**The state** of `erx_vi` is one record:

* the buffer, its file name, the file's identity, size and modification
  time when read or last written, and whether the buffer is modified;
* the held-text charge ([Bounds](#bounds));
* the cursor, a line and a unit index, and the wanted column that `j` and
  `k` keep, `$` setting it to the line's end;
* the top of the window, a line and a screen row within that line, so a
  line longer than the screen scrolls by rows like any other;
* the mode: `normal`, with the pending keys; `insert`, with the text
  typed and where the insert started; `prompt`, with its kind (`:`,
  `/` or `?`) and the line typed so far; or `matching`, while a search or
  substitution runs, with the keys typed meanwhile;
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

* `{bytes, Bytes}`: what one read of the terminal returned, possibly
  nothing;
* `escape_timeout`: the end of the wait after a lone Escape;
* `{size, Rows, Columns}`: the terminal's size, at the start, after a
  resize and after the job is continued;
* `{written, Result}` and `{loaded, Name, Result}`: what a write or read
  effect did;
* `{matched, Result}`: what a search or substitution found or built.

Effects: `bell`; `{timer, Ms}` and `cancel_timer`;
`{write, Name, Chunks, Guard}` and `{read, Name, Room}`;
`{match, Request}` and `cancel_match`; `stop`; `quit`. The loop draws
once after the events of one read, so a paste of 4 KiB redraws once.

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
with keys pending drop them.

**Motions and ranges.** A motion is a function from the buffer, the
cursor and a count to a destination and a **range**: the bytes an
operator acts on, `{From, To}` with `To` excluded, or a run of whole
lines. A moving command goes to the destination; an operator takes the
range as it is and never looks at the motion again, so every rule about
what an operator covers lives in the motion:

| Motion | Destination | Range under an operator |
| --- | --- | --- |
| `h`, `b`, `0`, `^` | back by units, to a word start, to the line start, to the first non-blank | from the destination up to the cursor, the cursor's unit excluded |
| `l`, Space | forward by units, at most to the line's last unit | from the cursor up to the destination, excluded; at the line's end, through its last unit, so `x` and `dl` there delete it |
| `w` | the next word start, on a later line if need be | from the cursor up to the destination, excluded; when the destination is on a later line, only to the end of the cursor's line, so `dw` on a line's last word joins nothing |
| `e` | the end of the word, or of the next one | from the cursor through the destination's unit |
| `$` | the line's last unit, `count - 1` lines down | from the cursor through the end of that line, its newline excluded |
| `j`, `k`, `G`, `gg`, `^F`, `^B` | a line | every line from the cursor's to the destination's, both included |

`cw` on a non-blank acts as `ce`, so it changes the word and keeps the
blank after it, as vi users expect. Pinned examples, each a host test
and an oracle script: on `one two three` with the cursor on `o`, `dw`
leaves `two three`, `de` leaves ` two three`, `d$` leaves an empty line,
`2dw` leaves `three`, and `dl` leaves `ne two three`; on `one` followed by
`two` on the next line, `dw` leaves an empty line and `two`, and `dj`
deletes both lines. A difference from nvi the oracle finds in these is a
bug in the table.

**Changes and `.`.** Every change is a command value, with the text an
insert typed recorded in it when the insert ends. `.` applies the last
change again at the cursor, with its own count if one is typed. After
`u`, `.` repeats the undo instead, as in nvi.

**Undo.** Before each change the core pushes the buffer and cursor onto
the history. `u` swaps the current buffer with the top of the history, or
of the undone list when its direction is forward. Because the buffer is a
persistent tree, an entry holds only the chunks its change replaced; its
charge ([Bounds](#bounds)) counts them and the inner nodes rebuilt.

**Prompts.** `:`, `/` and `?` start a prompt; the prompt's line is edited
by the keys above; Return hands it to `erx_vi_ex` or to the search. A
pattern `erx_grep_re` refuses shows the refusal's message.

**Searching and substituting** are the work that can run long, so the core
asks for it as the effect `{match, Request}` instead of doing it in
`step/2`: the request holds the buffer, the compiled pattern, where to
start and, for a substitution, the range and the replacement. The loop
runs it in a match helper ([The command at the edge](#the-command-at-the-edge)),
and the core is in `matching` mode until `{matched, Result}` arrives. A
search's result is a place or `not_found`: the cursor moves to the next
match in the direction asked, wrapping, or the message says `Pattern not
found`. A substitution's result is the list of replacements for its
change, with their charge, or a refusal; the buffer the core holds is the
one before the substitution until the core applies that list in one step,
so a cancelled or refused substitution changes nothing. In `matching`
mode `^C` gives `cancel_match` and drops the keys typed meanwhile, as an
interrupt flushes input, and returns to normal mode; any other key is kept
in the state, up to 4 KiB, and handled once the result arrives.

**Substitution** builds each new line from the pieces of the old and the
replacement text, adding each new line's bytes to a running total and
stopping with `file too large` as soon as the total would pass the room
the held-text budget has left. A replacement holding a newline is not
offered; `\` before Return cannot be typed into the prompt.

**Ex.** `erx_vi_ex:parse(Line)` returns a range and a command, or a
message. The commands are pure functions of the state, except that `:w`,
`:wq`, `:x`, `ZZ` and `:e` return effects and finish when the result
arrives. `{write, Name, Chunks, Guard}` carries the buffer's chunks, which
the loop writes as one I/O list, so writing copies nothing; `Guard` is
`{unchanged, Identity, Size, Mtime}` for the file being edited, `absent`
for another name, or `none` under `!`. The loop checks the guard as
[The command at the edge](#the-command-at-the-edge) says and answers
`{written, {error, changed}}` or `{written, {error, exists}}` when it
fails. `:q` after a write that fails does not quit. `:e` is allowed only
when the buffer is written or `!` discards it, so the core drops the
buffer and the history before the read, and `{read, Name, Room}` gives
the loop the room the unnamed buffer leaves in the budget; a read that
fails leaves an empty buffer with no file name, on which `:w` without a
name says `No current filename`.

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
terminal larger than 256 rows or 512 columns is laid out in its top
256 rows and left 512 columns, the rest left blank, which bounds the
screen value: a row holds at most 4 bytes a column, so a screen is at
most 512 KiB.

**The bytes.** `erx_vi_screen:diff(Old, New)` writes, for each row that
differs, the cursor's move to the row's start, the row's text and, when
the text is narrower than the screen, erase to the end of the line; then
the cursor's move to its place. A row that fills the width gets no erase,
because the terminal leaves its cursor on the last column with the wrap
pending, where `CSI K` would erase the row's last character; the next
cursor move clears the pending wrap. It hides
the cursor around the rows and shows it after. Forgetting the old screen
draws everything: the loop starts with a blank screen of the terminal's
size, and `^L`, a resize and the return from `fg` each clear the
terminal and forget the old screen. The sequences are a fixed set that
every master's terminal understands without terminfo, all in `erx_vt`'s
table ([design-display.md](design-display.md#the-sequences)): `CSI ?
1049 h` and `l` to enter and leave the alternate screen, `CSI row ; col
H`, `CSI K`, `CSI 2 J`, `CSI ? 25 l` and `h`, and BEL for the bell.

## The command at the edge

`erx_cmd_vi` declares `-erx_heap(16)`, so its stage runs with a
`max_heap_size` of 16 MiB ([design-shell.md](design-shell.md#pipelines)).
`erx_cmd_vi:run/2`:

1. Refuses unless standard input and standard output are both the
   terminal (`erx_cmd:isatty/2`), with `vi: not a terminal` and status
   1. A redirected stream, a command domain and the system shell each
   answer `enotty` from `tty/2`
   ([design-shell.md](design-shell.md#interfaces)), so `vi` runs in a
   session's own domain, at its terminal. Since a pipeline's stage has
   the terminal as its standard input only at the pipeline's start and as
   its standard output only at its end, `vi` is the only stage of its
   pipeline, and so the only reader of the terminal in its job.
2. Reads the file, if one is named, through the session's namespace with
   `file:open/2`, the name made absolute against the working directory
   and otherwise passed as typed, so the namespace resolves its `.`, `..`
   and links as [design-files.md](design-files.md#resolving-a-path)
   says. It reads in pieces of 4 KiB, each cut into the buffer's chunks
   as it arrives, so no binary of the whole file is ever held, and stops
   with `file too large` at the file bound. A file that does not exist is
   a new file. A file over the bound, a directory or a read that fails
   ends `vi` with `vi: FILE: reason` on standard error and status 1,
   before the terminal is touched, `FILE` written through the line escape
   (`erx_text:escape_line/1`), as every file name `vi` prints is.
3. Reads the `termios` with `tty(Ctx, tcgetattr)` and keeps it as the
   one to put back; computes `Raw` from it (`ICANON`, `ECHO`, `ISIG`,
   `IEXTEN`, `ICRNL`, `IXON` and `OPOST` clear, `VMIN` 1 and `VTIME` 0,
   as `cfmakeraw` sets them); opts in to size reports with
   `erx_cmd:catch_events([winch])`; and arms the first ready report with
   `erx_cmd:watch/1`, keeping the open's reference `Open` it returns.
4. Runs the rest inside `try ... after`. It **takes the terminal**: sets
   `Raw` with `tty(Ctx, {tcsetattr, Raw})`, which in a job that is not in
   the foreground stops the job and returns only once `fg` has brought it
   back (VI7), then enters the alternate screen, asks `tty(Ctx, winsize)`
   and draws everything. Then it runs the loop. The `after` leaves the
   alternate screen and sets back the kept `termios`, so a `:q`, an error
   and a crash all leave the tty as `vi` found it, and the next command
   of the line starts cooked (VI3). A kill runs no `after`; the shell's
   restore at the job's end covers the `termios` then, and the alternate
   screen stays until `reset`.

**The loop** is one `receive`:

* the ready report `{ready, Open, _, _}`, matched with `Open` bound:
  `erx_cmd:read/2` on it makes one read, which, after the
  report, never waits: it returns the waiting bytes, at most 4 KiB, or
  nothing when another reader of the job took them first or a signal
  came since the report
  ([design-shell.md](design-shell.md#interfaces)); the core gets
  `{bytes, Bytes}`, and the loop arms the next report with
  `erx_cmd:watch/1`;
* `{erx_cmd, winch}`: `erx_cmd:requested(winch)` drops reports that
  arrived meanwhile, `tty(Ctx, winsize)` gives the size, and the core gets
  `{size, Rows, Columns}`;
* the escape timer's message: `escape_timeout`;
* the match helper's result, which the core gets as `{matched, Result}`.

After each event the loop carries out the effects in order and draws the
new screen with `erx_cmd:write/2`. A write to the terminal waits while
the tty is stopped, as any writer's does
([design-live.md](design-live.md#the-tty)).

**The match helper.** `{match, Request}` starts one process of `vi`'s job,
which `vi` monitors, so its heap limit ends it alone, and which runs the search or substitution over the
request's buffer and sends its result. The buffer is a value, so the
helper reads it without copying a chunk's bytes, and the buffer `vi`
holds stays the one before the operation. The helper runs under a
`max_heap_size` of the room the held-text budget has left plus 2 MiB for
its copy of the tree's nodes, and each match under grep's match limits.
`cancel_match` kills it and drops its result if one is already queued, so
`^C` ends a search or substitution however long one match takes. At most
one helper runs.

**Writing.** The write effect carries out its guard on the file itself:

* `absent` opens the name with `exclusive`, so the file is made by this
  open or the write fails with `exists`; no other writer can make the
  name between a check and the open.
* `{unchanged, Identity, Size, Mtime}` reads the path's information
  first: a file that is gone is made as `absent` makes one, as nvi
  writes a file that has disappeared as a new one (`exf.c:807-808`).
  Otherwise it opens the file for reading and writing, which does not
  truncate it, reads the opened file's own information
  (`file:read_file_info/2` on the open file,
  [design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote)), and
  only when its identity (the `major_device` and `inode` that stand for
  the tree and the qid path) and its size and modification time are
  those `vi` recorded does it truncate the file through the open file and
  write. Otherwise it fails with `changed`.
* `none` opens the name for writing, truncating it.

The guard is checked on the file that is then written, so a file
replaced under the name after the check is not written over. What it
cannot see is a change that keeps the file's size and falls in the same
second as the recorded time, since the time it reads has whole seconds
([design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote)), and
a change made after the check, while `vi` writes, as with nvi, which
ignores that race (`exf.c:796-801`). A file deleted between the path's
check and the open is made empty by the open and then refused as
changed.

**`^Z`.** With `ISIG` clear, `^Z` is a key. The core returns `stop`;
the loop leaves the alternate screen, moves the cursor to the last row,
sets back the kept `termios`, and calls `erx_cmd:stop/1`, which returns
once the job is continued by `fg` or `bg`
([design-shell.md](design-shell.md#job-control)). It then takes the
terminal again as at the start: the `tcsetattr` waits for the
foreground, so after `bg` `vi` stops again, as a FreeBSD program that
sets its terminal in the background does, and draws nothing over the
prompt; once in the foreground it asks the size, since a size report
goes only to the foreground job, and draws everything.

## Bounds

`vi` runs as one Erlang stage whose command declares a heap of 16 MiB,
binaries included ([design-shell.md](design-shell.md#pipelines)). What it
keeps is split into parts, each with its own bound, that add up to less
than that:

| Part | Bound |
| --- | --- |
| held text | 10 MiB, the budget below |
| the old and new screens | 1 MiB, two screens of at most 512 KiB ([Drawing](#drawing)) |
| the process's other terms, and the copy garbage collection makes of them | 2 MiB: the state's fixed parts, the prompt and pending keys of at most 4 KiB each, the compiled pattern, and the tree's nodes, which the held-text charge also counts |
| the match helper, while one runs | 2 MiB for its copy of the tree's nodes; what it builds is charged as held text |

That is 15 MiB for `vi` and its helper together, within the 16 MiB the
shell admits the stage at; `vi`'s own process keeps at most 13 MiB under
its limit of 16 MiB, and the worst-case test below measures it there.

**Held text** is one budget that every byte `vi` keeps is charged to:

* the buffer: each chunk's bytes and 128 bytes for its node;
* each history entry: 256 bytes, the bytes of the chunks its change
  replaced and of those it made, and 128 bytes for each chunk and each
  inner node it rebuilt. Undo and redo swap which side of a change the
  buffer holds, so the entry pays for both, and every chunk a retained
  version holds that the buffer does not is paid for by some entry;
* the unnamed buffer, a copy of the text yanked or deleted, cut with
  `binary:copy/1` so it keeps no chunk alive, and 256 bytes;
* the text `.` repeats, its bytes.

A change computes its charge from the sizes the tree keeps before it is
made. When the charge does not fit, the oldest history entries are
dropped until it does, and `u` past them says `No more changes to undo`;
when it still does not fit with no history left, the change is refused
with `file too large` and the state is as it was. A substitution, whose
size is known only as it is built, counts as it goes and stops at the
room left. So a history of many small changes is bounded by its entries'
fixed charge, and a buffer of many short lines costs no more than any
other buffer of its bytes, since chunks are cut by bytes, not by lines.

The other bounds:

| What | Bound | Beyond it |
| --- | --- | --- |
| a file read | 8 MiB, and no more than the held-text budget has room for beside the unnamed buffer; a file of 8 MiB, with its chunks' nodes, leaves about 1.5 MiB for changes and their history | refused at the start with `file too large`; at `:e`, the message and an empty buffer with no name |
| a line | 64 KiB, the bound of `erx_cmd:read_line/1` | a file holding one is refused as above; an insert, put, join or substitution that would make one changes nothing and says `line too long` |
| a count | nine digits | the tenth digit rings the bell; a count past the text stops at its end |
| an ex line or pattern | 4 KiB | further keys ring the bell |
| a read of the terminal | 4 KiB | the rest waits in the tty |
| keys typed while matching | 4 KiB | further keys wait in the tty |
| a pattern's match | grep's match limits, for each match | the search or substitution stops with `pattern too complex` and changes nothing |
| the screen laid out | 256 rows by 512 columns | the rest of the terminal stays blank |

The 64 KiB line bound also bounds the work of laying out the cursor's
line, which is linear in its length.

## Patterns and invalid UTF-8

`erx_grep_re` compiles in byte mode, so a pattern matches any line,
valid UTF-8 or not, and never fails on its subject. A literal non-ASCII
character in a pattern matches its bytes; `.` matches one byte, so it
matches part of a multi-byte character, a documented difference. A
search moves the cursor to the unit that holds the match's first byte.

## Concurrency and failure

`vi` is one process, and at most one match helper. Keys, size reports,
the escape timer and the helper's result arrive as messages to `vi`'s one
`receive`, so no state is shared and no event can interleave with
another's handling; the helper only reads a buffer that is a value and
sends one result, which `vi` drops if it has cancelled the helper. A file
read or write runs in the loop and blocks it; a slow file server delays
`vi`, and the keys typed meanwhile wait in the tty.

| Failure | What remains | What the user sees |
| --- | --- | --- |
| a write fails, wholly or part way | the file as far as written; the buffer, still marked modified | the error on the message line; `:wq` does not quit |
| `vi` fails with an exception | the file as last written | the main screen back, the shell's prompt editing as before, the error as the stage's status |
| the job is killed or the session hangs up | the file as last written | unwritten changes are lost; the alternate screen stays until `reset` |
| the stage passes `max_heap_size` | as a kill | as a kill; the bounds make this a bug. A command after `vi` on the same line starts with `vi`'s raw `termios`, since only the end of the job restores it after a kill |
| the match helper passes its heap limit | the buffer before the operation | the operation's error on the message line; the bounds make this a bug |
| the tty is stopped (a session detached) | everything | `vi` waits in its write and goes on when connected |
| a search or substitution runs long | everything | `^C` cancels it and the buffer is as it was |

## Security

`vi` runs in the session's own domain with the session's authority, as
any command the user types does (SH1 of
[design-shell.md](design-shell.md#invariants)), and touches only the
files the user names through the session's namespace. A file is
untrusted input: it is bounded before it is held (VI4), kept as bytes
(VI2), and shown only through printable forms (VI1). Every file name
`vi` prints, on the message line or in a diagnostic on standard error,
goes through the line escape, as the names `ls` prints at a terminal do
([design-live.md](design-live.md#attributed-text)); `vi` does not hand a
name to `erx_cmd:report/3`, which writes its subject as it is. Keys
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
  that shares a chunk edited in place.
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
* **Motions and ranges:** the pinned examples of
  [Motions and ranges](#motions-and-ranges), each with `d`, `c` and `y`.
  Seeded: `w`'s range not stopped at the line's end, which joins the
  lines in the `dw` example.
* **Drawing against the terminal emulator:** for screens produced by
  random editing sequences, among them rows that fill the width with
  narrow characters and with a width-2 character in the last two
  columns, feeding `erx_vt` the bytes of `diff(Old, New)` on a grid that
  shows `Old` gives a grid that shows `New`, with the cursor where the
  screen puts it. Seeded: a diff that leaves out the erase after a row
  that shrank, which leaves old text behind; and a diff that erases after
  a full row, which loses its last character.
* **The output check:** over the fuzz corpus of file bytes, including
  every C0 and C1 control, ESC and CSI sequences, OSC 8 strings,
  bidirectional overrides and invalid UTF-8, the bytes `vi` writes parse
  as text that prints and the fixed sequence set, with nothing else; the
  same holds for the message line and for what `vi` writes to standard
  error, over file names drawn from that corpus, for a file that loads,
  one over the bound, a directory and a name the namespace refuses.
  Seeded: a view that copies one line's bytes unchanged; a startup
  diagnostic that writes the name raw.
* **Round trip:** loading and writing each corpus file, with no edit,
  gives its bytes exactly, a last line without a newline included; a new
  file with one line typed is written ending in a newline. Seeded: a load
  through `unicode:characters_to_binary/1`; a write that adds a missing
  final newline.
* **The buffer:** a line of 64 KiB, which spans chunks, loads, moves and
  edits; after random replacements every chunk but a lone one holds 2 to
  4 KiB, and the newline counts agree with the bytes. Seeded: a
  replacement that leaves a chunk under 2 KiB beside a neighbour.
* **Bounds, measured:** the stage runs under `max_heap_size` of exactly
  16 MiB with `include_shared_binaries`, as the shell sets it, through the
  worst cases the budget allows: an 8 MiB file of one-byte lines and one
  of a single long-line pattern, filled to the held-text budget by puts;
  a history of the most entries the budget admits, from single-character
  changes; an unnamed buffer of the most the budget admits; a
  substitution over every line that runs out of room; both screens laid
  out at 256 rows by 512 columns of 4-byte characters; and a match helper
  at its limit; each followed by a full garbage collection. The stage
  lives, each refused change says its message and leaves the state as it
  was, and the largest heap seen is recorded. A file one byte over the
  bound and a line of 64 KiB plus one byte are refused. Seeded: the
  history entry's fixed charge set to 0, which the heap limit then ends.
* **Write guards:** `:w` of a file another writer changed, in size or in
  its second, or replaced by another file of the same size and time, is
  refused, and `:w!` writes; `:w` to an existing other name is refused,
  and so is one whose name another writer makes between the core's
  request and the open. A file deleted since it was read is written as a
  new file. Seeded: the guard compared by the path's information before
  the open, which writes over the replacement; the `absent` guard as a
  check before a plain open, which writes over the late file.
* **Matching:** a search for a pattern that fails slowly on every line
  of a large buffer is cancelled by `^C` within a tenth of a second of the
  key and leaves the cursor where it was; a global substitution
  cancelled part way leaves the buffer as it was, and `u` then undoes the
  change before it. Seeded: a match run in the loop itself, which reads
  the `^C` only after the search ends.
* **Fuzz targets:** `erx_vi_keys:decode/2`, `erx_vi_ex:parse/1`, and the
  load-and-layout path from file bytes to a screen, each checking VI1 and
  the screen's shape.

**QEMU tests** (track S's suite, on a session over the host link's
`console` line):

* `vi /tmp/f` from the session, keys typed by the harness, `:wq`, then
  `cat /tmp/f` shows the edit; the harness's console reports a new size
  and the next screen fits it.
* `vi /tmp/f; cat` on one line: after `:q`, `cat` echoes and edits a typed
  line, and `Ctrl-D` ends it. Seeded: `vi`'s own restore removed, which
  leaves `cat` reading raw keys.
* `^Z` gives the prompt, which echoes and edits a typed line with its own
  line editing; `stty -a` run next shows the cooked setting every job
  starts with; `fg` redraws and editing goes on.
* `^Z` then `bg`: the job is reported stopped again and nothing is drawn
  over the prompt; `fg` redraws. `vi /tmp/f &` likewise is reported
  stopped before it draws. Seeded: a `tcsetattr` that goes through in the
  background, which draws over the prompt.
* `vi` killed by a seeded fault leaves the prompt echoing and editing.
  Seeded: the shell's restore of its `termios` removed, which leaves the
  prompt without echo.

## Performance

Each event redraws by comparing the new screen with the old, row by row.
At 80 by 24 that is about 2 KB of work and, for a full redraw, about 2 KB
of output. A one-line scroll changes every row, so on a console line at
115,200 bit/s it rewrites the screen, about 170 ms (unmeasured). Scrolling
with the terminal's own scroll commands when the new screen is the old
one shifted would send one row instead; that waits for a measurement on
the [performance watch list](todo-performance.md).

## Open decisions

* **A `tcsetattr` from the background stops the job.** VI7 rests on
  `tty/2`'s `tcsetattr` waiting for the foreground, as FreeBSD's
  `TIOCSETA` from a background process group raises `SIGTTOU` and sleeps
  until the group is in the foreground (`sys/kern/tty.c:570-607`,
  `:421-496`); in the first tier a program's background `tcsetattr` goes
  through. Recommendation: take FreeBSD's rule for Erlang commands as
  [design-shell.md](design-shell.md#interfaces) states it. Without it,
  `vi &` and `bg` after `^Z` draw over the prompt, and the alternative is
  to record that as a limitation.
* **`vi` from a program or under `within`.** A command domain's streams
  are copied bytes, so `tty/2` answers `enotty` there and `vi` refuses:
  `xargs vi` and `within /etc -- vi rc.conf` do not work.
  Recommendation: accept it for the first version; a narrowed editor
  needs a tty open that crosses to the command domain, a design of its
  own.
* **A write guard that sees every change.** The guard misses a change
  that keeps the file's size and falls in the second `vi` recorded,
  because `#file_info{}` carries whole seconds. erXos's servers give
  every change to a file a new version
  ([design-files.md](design-files.md#identity-and-version)), which no
  Erlang call returns. Recommendation: keep nvi's check for the first
  version; when a lost edit is reported, return the version beside the
  file's information, a change to `prim_file`'s interface that
  [design-files.md](design-files.md) would own.

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
* FreeBSD 15.1, `sys/kern/tty.c` at the same commit, from the same
  place, read as data, SHA-256
  `c121ee2a658f28c708c7996b59acb9fb99474ccbc12d1241b33e717565c1d076`.
* [design-shell.md](design-shell.md): Erlang commands, `erx_cmd`, job
  control and the size report.
* [design-live.md](design-live.md): the tty, the line discipline and the
  line escape.
* [design-display.md](design-display.md): `erx_vt`, its sequences and
  the width table.
