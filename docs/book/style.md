# How to Write the Book

Every chapter of the book is written by an agent that has never seen
the other chapters. This guide makes those chapters read as one book.
It says how a chapter is built, how its sentences are written, how it
stays honest about what runs and what is only designed, and what the
writer checks before committing. The outline in [README.md](README.md) says *what* each
chapter covers; this guide says *how*.

The guide follows its own rules. Where it breaks one, fix the guide.

## Contents

1. [The reader](#the-reader)
2. [Voice](#voice)
3. [The shape of a chapter](#the-shape-of-a-chapter)
4. [Sections and paragraphs](#sections-and-paragraphs)
5. [Background for newcomers](#background-for-newcomers)
6. [Sentences](#sentences)
7. [Words](#words)
8. [Explaining a design](#explaining-a-design)
9. [Honesty: built and designed](#honesty-built-and-designed)
10. [Code](#code)
11. [Figures and tables](#figures-and-tables)
12. [Mechanics](#mechanics)
13. [The writer's checklist](#the-writers-checklist)
14. [The newcomer review](#the-newcomer-review)
15. [What the guide draws on](#what-the-guide-draws-on)

## The reader

Write for one person. They know C. They have used UNIX and know a
little of how it works inside: processes, files, system calls. They
have read some Erlang, or none. They have never read about L4, Plan 9,
capabilities or OTP's internals.

Three consequences follow, and the rest of the guide spells them out.

* Start from what this reader knows, which is UNIX and usually
  FreeBSD, and move to what erXos does differently.
* Explain every term this reader does not know, where it first appears.
* Never make this reader feel slow. No "obviously", no "as is well
  known", no "simply".

The expert reader is served by the same text. An expert skims a
definition in two seconds. A newcomer who meets an undefined term stops
reading.

## Voice

The book speaks in the calm third person of the FreeBSD book. The
system and its parts are the actors: the kernel checks, the driver
asks, the supervisor restarts. The book uses the present tense.

**No "we".** Reason: many agents write the book over many sessions,
so a "we" would pretend to a single author who remembers deciding
things. It also invites drafting history ("we first tried X"). The
reader needs the reason a design is the way it is, not the story of
who chose it.

**"You" only for the reader's own actions.** Use it where the reader
types a command or reads a file on a running system. Reason: an
instruction addressed to "the user" is longer and colder than one
addressed to the reader.

| Before | After |
| --- | --- |
| We decided to make every driver an Erlang process. | Every driver is an Erlang process under a supervisor. |
| The user may then inspect the process list by reading `/proc`. | Read `/proc` to see the process list. |

**Humor is rare and dry.** One light line in a chapter opening is
fine if it is true. Never joke in a definition, a status box, a
security statement or a heading. Reason: a reader cannot tell a joke
from a claim at a glance, and a wrong claim costs more than a flat
sentence.

**No marketing.** The book describes; it does not sell. A strength is
stated as a fact with its evidence, and the cost sits beside it.

## The shape of a chapter

A chapter goes from the problem to the design, in this order. The
FreeBSD book works this way: it says what a facility is, then how it
is built, then why.

1. **Status box.** The first thing under the title (see
   [Honesty](#honesty-built-and-designed)).
2. **The problem.** One to three paragraphs. What goes wrong without
   this subsystem, or what a user needs from it. Lead with a concrete
   situation, not a definition list.
3. **The familiar baseline.** How UNIX, usually FreeBSD, solves the
   same problem, in a paragraph. Reason: the reader already holds that
   model, and the difference is easier to learn than the whole.
4. **The short answer.** erXos's answer in two to four sentences.
   Armstrong's thesis does this: it gives a short answer early and
   refines it for the rest of the work. The reader then knows where the
   chapter is going.
5. **The map.** One or two sentences that name what the sections cover,
   in order. Not "In this chapter we will discuss".
6. **Concepts and terms.** The new ideas, each defined, each with an
   example.
7. **Structures.** The data and the parts that carry the concepts:
   which domain holds what, which process owns which state.
8. **Mechanism.** How the parts behave over time. Show one event from
   start to finish (OSTEP calls these timelines): a message arriving, a
   driver crashing, a page being mapped.
9. **Failure.** What happens when each part fails, and what the reader
   sees. erXos is built around failure, so every chapter has this.
10. **Design choices.** The alternatives that lost, and why (see
    [Explaining a design](#explaining-a-design)).
11. **Summary.** Five to ten sentences. Restate the claims, not the
    section titles. No new material.
12. **Where to read next.** The design documents and papers behind the
    chapter, each with one line on what it adds.

The last sentence of the chapter, before the summary, may point at
the problem the next chapter solves. It never ends on a summary of the
summary, or on praise.

The order is a default. Merge steps 6 and 7 when the structures *are*
the concepts. Never drop steps 1, 2, 9 or 11.

### The first sentence

The first sentence of a chapter, and of each section, makes the
reader want the second. Rewrite it until it does. Scott Adams's essay
"The Day You Became a Better Writer" makes this the first rule of
clear writing, and it holds for technical prose too: a reader decides
in one sentence whether the next page is worth reading.

A good first sentence states a surprising fact, a concrete problem or
a question the reader has. It does not announce the topic.

| Before | After |
| --- | --- |
| This chapter discusses memory management in erXos. | In erXos, no domain can take memory that another domain was promised. |
| Device drivers are an important part of any operating system. | A driver bug that writes one wrong address to a network card can let the card overwrite any page of memory. |
| This section describes capabilities. | A process in erXos cannot name a kernel object it was never handed. |

## Sections and paragraphs

**Each section answers one question.** Write the question down before
the section. The section's first paragraph answers it; the rest
explains and supports the answer. Reason: a reader who skims first
paragraphs should still learn the chapter.

**The heading names the answer's subject.** "12.4 How a driver reaches
DMA memory" is better than "12.4 DMA". A heading is a noun phrase or a
"how" or "why" phrase. It is never a sentence that makes a claim.

**One topic per paragraph.** The first sentence of the paragraph says
what the paragraph is about. Three to six sentences. A paragraph of
one sentence is allowed for emphasis, once or twice a chapter.

**Signpost sparingly.** The chapter's map does the main signposting.
A section ends where its question is answered. A transition sentence
names the next question only where the link is not obvious from the
headings.

**Lists for parallel things, prose for arguments.** Use a list for
three or more items of the same kind: the fields of a record, the
steps of a boot. Use prose when one idea follows from another, because
a list cannot say "because" or "so". A list's items share one grammar:
all nouns, or all full sentences.

## Background for newcomers

The book explains its background. A reader without much Erlang,
operating system or microkernel background must be able to follow
every chapter.

**Define every term where it first appears, in plain words.** The
definition is in the same sentence or the next. Set the term in bold
at its definition, once, and give it a line in the glossary
(Appendix A).

| Before | After |
| --- | --- |
| Each message passes through the funnel. | Each message from another domain passes through the **funnel**, the one function that decodes such messages and refuses any that is malformed. |
| Each domain pays for its memory from its budget. | Each domain pays for its memory from its **budget**, a fixed amount of memory set aside for it when it is created. A domain that has spent its budget is refused more. |

**A term used before its chapter gets a gloss and a link.** A
one-clause definition and a forward reference: a **budget** (a kernel
object that pays for memory; see chapter 9), with "chapter 9" linked
to its file. The full
treatment stays in its chapter.

**Concrete before abstract.** Show one example, then state the general
rule. OSTEP opens its process chapter with the programs a reader runs
on a laptop before it defines the process. Do the same.

| Before | After |
| --- | --- |
| Stale-reference safety is guaranteed via generation-tagged handle resolution. | A domain names a kernel object by a handle, a small number. When the object is destroyed, every handle to it answers `ERX_ESTALE` until its holder closes it. It never names whatever object comes next. |

**Explain before use: background boxes.** When a chapter needs an idea
from outside erXos (virtual memory, a capability, an Erlang link,
DMA), and the reader may not have it, put a background box before the
first use.

```markdown
> **Background: DMA.** A network card does not wait for the CPU to
> copy each packet. It writes the packet straight into memory, at an
> address the driver gave it. This is direct memory access, or DMA.
> The card does not check that the address is safe. ...
```

Rules for boxes:

* One idea per box, at most about 150 words.
* The first sentence says what the idea is for, the second defines it.
* An expert can skip the box and lose nothing from the main text.
* A box explains the general idea. What erXos does with it goes in the
  main text, after the box.
* An idea that several chapters need gets its box once, in the first
  chapter that needs it. Later chapters link to it.

**Analogies only where accurate, and say where they stop.** An
analogy imports the reader's whole model of the familiar thing.
Everything that does not carry over must be named.

| Before | After |
| --- | --- |
| A domain is basically a container. | A domain is like a UNIX process in one way: it has one address space, and a fault inside it does not reach another domain. It differs in what lives inside. Thousands of Erlang processes, each with its own mailbox, share that one space. |

Never call an erXos thing by the name of something it is not, even in
passing. A domain is not a container, a jail or a virtual machine. A
facet is not a socket. The repository's principle "UNIX look and
feel, honestly" applies to the book's words as it does to the
system's commands.

**Never imply the reader should know.** Cut "obviously", "clearly",
"of course", "as is well known", "simply", "just", "trivially" and
"it is easy to see". If it is obvious, the sentence does not need the
word. If it is not, the word insults the reader.

## Sentences

These rules come from Scott Adams's essay, Orwell's rules in
"Politics and the English Language", and the approach of Joseph
Williams's *Style: Lessons in Clarity and Grace*.

**Short sentences, one thought each.** Aim for an average under 20
words. Split any sentence over 30. Reason: a reader holds one thought
at a time, and a long sentence makes them hold several while waiting
for the verb.

| Before | After |
| --- | --- |
| When a driver crashes, which can happen because drivers handle untrusted input from devices that may be faulty, its supervisor, which is an ordinary OTP supervisor running in the same domain, restarts it, and the rest of the domain is not affected. | A driver handles input from a device that may be faulty, so it can crash. Its supervisor, an ordinary OTP supervisor in the same domain, then restarts it. The rest of the domain keeps running. |

**The actor is the subject, the action is the verb.** Name who does
the thing first, then what they do. "The boy hit the ball" is read
faster than "the ball was hit by the boy". In erXos the actors are
concrete: the kernel, a domain, the funnel, a driver, a supervisor.

| Before | After |
| --- | --- |
| Validation of the plan is performed prior to hardware access. | `erx_device_dma_check` checks the whole plan before the shim touches the device. |
| It is ensured that no domain creates kernel objects of its own. | The root service creates every kernel object, so no domain ever holds one it was not given. |

The passive is right when the actor is unknown or does not matter, or
when it keeps old information first (next rule). Otherwise use the
active.

**Turn nouns back into verbs.** "Termination", "invalidation",
"performs validation of" hide the action in a noun. Find the verb.

| Before | After |
| --- | --- |
| The termination of a domain results in the release of all memory charged to its budget. | When a domain ends, the memory charged to its budget goes back to the pool. |

**Old information before new.** Begin a sentence with what the reader
already has, from the last sentence or the section's topic. End it
with what is new. The new idea then becomes the old one that starts
the next sentence. Prose built this way reads as a chain.

| Before | After |
| --- | --- |
| Every message from another domain passes through the funnel. Malformed payloads are what the funnel refuses. The `{erx_origin, D, Msg}` wrapper is added by the funnel to what it accepts. | Every message from another domain passes through the funnel. The funnel decodes the payload and refuses it if it is malformed. What it accepts it wraps as `{erx_origin, D, Msg}`, and the wrapper tells the receiver which domain sent it. |

**The important word goes last.** The end of a sentence carries the
stress. Put the new term, the number, or the surprise there.

**Cut throat-clearing.** Delete the opening that says nothing: "It
should be noted that", "It is important to understand that", "In
order to", "The fact that", "Basically". Start with the claim.

**Cut intensifiers and hedges.** "Very", "really", "extremely",
"quite", "somewhat", "fairly", "rather", "arguably" add nothing or
weaken the claim. "He was happy" is stronger than "he was very
happy". If a claim needs a hedge because it is not certain, say what
is not known instead.

| Before | After |
| --- | --- |
| This is a very important property that quite significantly reduces the attack surface. | This property removes one class of attack: a process cannot reach an object it was never handed. |
| Context switches are probably fairly cheap. | The cost of a context switch on Fiasco is not measured; [todo-performance.md](../todo-performance.md) lists it. |

**Five sentences beat a hundred.** Adams's main point: a simple
argument persuades more readers than a brilliant long one. Make the
argument once, with one good example. Do not restate it in three
forms.

## Words

**Concrete over abstract.** Name the file, the call, the process, the
number. Adams puts it this way: in humor choose the vivid word, in
clear writing the concrete one.

| Before | After |
| --- | --- |
| erXos provides strong fault isolation. | A fault in the display domain ends the display domain. The storage domain and the shell keep running. |
| The system is configured declaratively. | One file, the system manifest, says which domain holds each device. A build check proves its security properties before the image is made. |

**Numbers and names over adjectives.** "Fast", "small", "large",
"lightweight", "efficient" say nothing until measured. Give the number
and its conditions (see [Honesty](#honesty-built-and-designed)), or
drop the adjective.

**Short, plain words.** Orwell's rules: never a long word where a short
one will do, never a jargon word where an everyday one exists. "Use",
not "utilize" or "leverage". "Start", not "instantiate", unless
instantiation is the technical act. "Check", not "validate", unless
the design document's term is "validate".

**No stacked jargon.** The repository's plain-language rule applies:
explain a technical term when it is needed, and never pile two
unexplained ones together.

| Before | After |
| --- | --- |
| Handle propagation is constrained to a strictly hierarchical delegation topology. | A handle reaches another domain in one way only: its holder passes it into a space the holder created. A domain cannot send a handle to a sibling. |

**One name per concept.** Use the name the design documents use, and
the glossary lists, every time. Do not vary it for elegance. A reader
who meets "domain", then "partition", then "compartment" assumes three
things. The names come from [design.md, The model](../design.md#the-model)
and the glossary of each design document.

**Words that do not go in the book.** Each has a reason.

| Word or phrase | Why |
| --- | --- |
| obviously, clearly, of course, simply, just, trivially, as is well known | insults a reader who did not know |
| very, really, extremely, quite, highly, incredibly | adds nothing |
| robust, powerful, seamless, cutting-edge, elegant, blazing | marketing; state the property instead |
| currently, now, at present, previously, recently, new (of a feature) | dates the text; the status box says what runs |
| will (for what the system does) | the book is in the present tense |
| leverage, utilize, facilitate, in order to | a short word does it |
| note that, it should be noted, it is important to | throat-clearing |
| etc., and so on | name the items, or say "for example" before a partial list |
| owner (meaning the person who decides) | the book states facts, not who decided them; "owner" for the process or domain that owns state is fine |

## Explaining a design

The book's value is the *why*. The design documents already say the
*what*.

**The reason sits next to the mechanism.** Every mechanism comes with
its reason in the same paragraph, usually the next sentence. Never
make the reader wait for a "rationale" section to learn why a thing
exists.

| Before | After |
| --- | --- |
| Every message from another domain arrives as `{erx_origin, D, Msg}`. | Every message from another domain arrives wrapped as `{erx_origin, D, Msg}`. The wrapper means a process cannot act on such a message by accident: only the code that owns the protocol unwraps it, after checking it. |

**Name the failure a mechanism prevents.** A rule is easier to
remember, and to believe, when the reader sees what goes wrong
without it.

| Before | After |
| --- | --- |
| No mapping is writable and executable at once. | No mapping is writable and executable at once. Without that rule, a bug that lets an attacker write into a program's memory would also let them run what they wrote. |

**Show the alternative and why it lost.** For each major choice, name
the first other design a reader would think of, as a design rather
than as another system's feature, give it its due, and say what it costs. The
reader learns more from the comparison than from the choice.

> The kernel could schedule every Erlang process as a kernel thread.
> Each would then get the kernel's full fairness and accounting. But a
> switch between two Erlang processes of one domain would become a
> kernel entry, and a busy domain runs many thousands of them. erXos
> splits the work instead: the kernel allocates CPU time to groups,
> and the runtime in each domain schedules its own processes within
> its group's grant.

**Describe erXos, credit in one line.** The book is about how erXos
works, not about where its parts came from or what was changed on the
way. Where an idea comes from another system (L4 and Fiasco, EROS,
Plan 9, FreeBSD, Erlang/OTP, musl or any other), name the source once,
in a clause, where the idea is introduced, and then describe erXos's
mechanism in its own terms. Do not tell what was lifted and what was
changed, do not keep comparing with the source, and leave out what
only an implementer needs: the pinned version a behaviour matches, the
oracle a test checks against, which upstream file a piece came from,
what was ported when. The book is not an implementation chronology.
Do not explain how erXos differs from FreeBSD, Linux or any other
system, either: the book's goal is to explain how erXos works, not
how it compares. Say what erXos has (state is a file under `/proc`),
not what it lacks next to another system ("there is no `sysctl`").
The story of each idea's origin, what erXos kept and what it
changed, belongs to the lineage appendix
([e-lineage.md](e-lineage.md)), and the background chapters may use
other systems to teach a concept.

| Before | After |
| --- | --- |
| erXos introduces budgets, a novel memory accounting scheme. | Every allocation is charged to a budget, after EROS's space banks, and what a domain spends is bounded by its own budget. |

Never call an idea new without checking the prior art. "erXos's take
on X" is safer than "erXos invents X".

**State the cost.** Every design trades something. Say what, in
plain words, next to the choice. A reader trusts a book that names its
costs.

**Explain "by construction" with the list it replaces.** erXos's core
claim is that properties hold because the wrong state cannot be
written. Show the reader the list of cases a conventional design must
remember, then the one mechanism that makes the list empty. Chapter 6
introduces the idea; chapter 2 prepares it, and later chapters point back to it
when they meet an instance. Use only mechanisms that hold by
construction in the system as it runs on Fiasco, built or designed:
the funnel that every message from another domain passes through, the
root service as the only creator of kernel objects, the ABI generated
from one file. A property that the design documents give only for a
different kernel is not erXos's, and the book does not claim it.

## Honesty: built and designed

The book describes erXos as it is today, and as it is designed to be
where the design is not yet built. It never presents design as
working code, and it never presents the project's schedule.

**Fiasco is the kernel.** erXos runs on Fiasco, the L4 microkernel,
behind erXos's kernel interface, `liberx`. The book says so plainly.
Fiasco is not "a stopgap", "the kernel for now" or one of two kernels,
and the book has no other kernel to compare it with. Where a property
is what Fiasco gives, say what Fiasco gives, as a property of the
system. Where the system lacks a protection a reader would expect, say
so plainly as a limitation of the system, not as a gap a future
kernel closes. A background box may explain a general idea, such as a
kernel that checks a generation on every capability lookup, as an
idea; it never promises that erXos becomes such a kernel.

**Two marks: Built and Designed.** **Built** means it works in the
tree today: README.md's
[Current status](../../README.md#current-status) and the code show it.
**Designed** means the design documents specify it and it is not
implemented. There are no other marks.

**Designed means designed on Fiasco.** The authority for what the
system's kernel does is [design-fiasco.md](../design-fiasco.md); the
other `design-*.md` documents are the authority for the rest. Where a
design document describes a feature only in a form that needs a
different kernel (grants the kernel enforces, budgets as kernel
accounts), describe what the system does
on Fiasco and leave the other form out.

**Every chapter has a status box.** It says what in the chapter is
built and what is designed, in those two words only. The writer
checks each mark against README.md's Current status and the tree
before writing. Copying the outline's marks is not enough.

```markdown
> **Status.** The kiosk's full-screen window and `/dev/draw` are
> Built. The desktop of overlapping windows is Designed.
```

**A sentence about something designed says so in its own sentence.**
Describe the design in the present tense, as the design. Then say
once, in a sentence of its own, that it is designed and not built. A
reader who skipped the box must not be misled.

| Before | After |
| --- | --- |
| A desktop of overlapping windows comes in a later release. | A desktop of overlapping windows runs on the same window system as the kiosk. The desktop is designed and not built. |
| No page is ever writable and executable at once. | No single mapping is writable and executable at once: Fiasco's map refuses such a mapping. A page can still be writable through one mapping and executable through another. |

**No schedule.** The book names no milestones (M5, M12), no releases
as a schedule (0.1, 0.2, "the first release", "the preview"), no
phases, tracks or work orders, and no "next", "later" or "planned
for". It gives no component a stopgap, release or permanent status,
no replacement plan and no parity gate. It cites no row of
design-fiasco.md's downsides table and does not link to that table. A
component the system uses, such as littlefs, LVGL, musl or OTP, is
described as the component the system uses and how it fits, not as
temporary.

**No superlatives without a measurement.** "The fastest", "the
smallest", "the first" need a citation or go.

**Every performance number carries its conditions:** host,
accelerator (TCG, HVF or native), QEMU version, compiler, flags,
workload and baseline, as the repository's "Latency is UX" rule
requires. Take the number from a recorded measurement, cite where it
is recorded, and name the `tools/erx bench` run that produced it.
Never compare TCG numbers with HVF or native ones.

| Before | After |
| --- | --- |
| Creating a domain is fast. | Creating a domain takes `<N>` ms on `<host>`, under HVF, QEMU `<version>`, `<compiler>` `-O2`, measured by `tools/erx bench <name>` (`<record>`). |

The angle brackets mark what the writer fills from the record. A
writer with no recorded number writes no number.

**Unknown is a result.** If something is not measured, not tested or
not decided, say so. Never fill the gap from memory or from what
"should" happen.

**No temporal marks.** No "now", "recently", "as of", "in the latest
version", "has been fixed". The status box carries what runs. The
book describes the system as it is and as it is designed.

## Code

> "Programs must be written for people to read, and only incidentally
> for machines to execute." (Abelson and Sussman, preface to *Structure
> and Interpretation of Computer Programs*)

The book shows code that a reader can find and read.

**Show code when the code is the clearest statement.** A function's
signature, a record's fields, the shape of a state machine's return
value, a short loop that is the whole idea. Do not show code to prove
the thing exists; a path does that.

**Real code, from the tree, with its path.** Put the path and the
function name on the line before the block. Do not cite line numbers;
they move with every edit. Never invent an API. A sketch that is not
in the tree is labelled "sketch" in the sentence before it, and stays
under ten lines.

````markdown
`erx_device_dma_check`, in
`otp/erts/emulator/nifs/erxos/erx_device_dma.h`, decides whether a
plan may run:

```c
bool	erx_device_dma_check(const erx_dma_context_t *context,
	    const erx_dma_state_t *before, const erx_dma_state_t *after,
	    const erx_dma_plan_t *plan);
```

It sees the queue's state before and after, and the plan between
them. It returns false for anything it cannot prove safe.
````

**Short.** At most about 25 lines. Cut what does not serve the point
and mark the cut with a comment in the language (`/* ... */`,
`%% ...`, `# ...`). Keep the code's own formatting otherwise.

**Say what to notice.** The sentence after the block names the one or
two things the reader should see. A block with no commentary is a
block the reader skips.

**Language tags on every block:** `c`, `erlang`, `ruby`, `sh`,
`text`. A shell session shows the prompt `$` for the reader's input
and the output without one. Output is copied from a real run, never
typed from memory. Reason: the tree's code and outputs are ASCII, and
a pasted block that is not breaks the reader's copy and paste.

**Kernel interface calls by their erXos names.** Write
`erx_space_create`, not the Fiasco call behind it, unless the passage
is about Fiasco. The book, like the system, keeps Fiasco behind the
kernel interface.

## Figures and tables

**A figure beats prose for:** the parts of a system and who talks to
whom; a message's path through several parts; a state machine; memory
layouts. Prose beats a figure for an argument.

**Use the figures the outline names.** Each chapter's outline lists
its figures (3.1, 3.2, ...). Keep those numbers.

**Mermaid where GitHub renders it**, as the outline's open decision on
figures recommends: `sequenceDiagram` for messages over time,
`stateDiagram-v2` for state machines, `flowchart` for parts and
links. A plain-text diagram in a `text` block otherwise.

Mermaid conventions:

* At most about 12 nodes. Split a bigger figure in two.
* Labels in ASCII, in the book's terms, short: `storage domain`, not
  `StorageDomainProc`.
* No colors or styles. GitHub's dark and light themes both render
  plain diagrams well, and color must not carry meaning.
* Arrows read left to right or top to bottom, in the order things
  happen.

**Every figure has a caption that says what to notice.** The caption
goes on the line after the figure, in italics: the number, a title,
and one sentence on the point.

```markdown
*Figure 12.2. A DMA plan's path. The plan reaches the device only
after `erx_device_dma_check` has passed it whole; nothing in the path
lets a step through on its own.*
```

**Refer to every figure in the text**, before it appears.

**Tables for comparisons.** A table is the right form for property
against mechanism, erXos against FreeBSD, or a status per feature.
Keep cells short; a cell that needs two sentences belongs in prose.

## Mechanics

**Files.** One chapter per file, `NN-name.md` in `docs/book/`, as the
outline's Conventions section says. GitHub Flavored Markdown.

**Headings.** The chapter title is `# Chapter N. Title`, in title case,
as in the outline. Sections are `## N.M Title`, subsections
`### N.M.K Title`, in sentence case. No deeper level. Reason: the
FreeBSD book numbers its sections so a reader can cite them; a fourth
level means the section should be split.

**Cross-references.**

* Another chapter: "chapter 12", linked to its file. Lowercase
  "chapter" and "section" inside a sentence.
* A design document: a relative link with its section anchor,
  `[design-device-dma.md, Calls, observations and plans](../design-device-dma.md#calls-observations-and-plans)`.
  The chapter explains; the design document decides. When they
  disagree, the design document is right and the chapter is fixed.
* The tree: a path in backticks, relative to the repository root.
* A paper or book: author, title and year in the text, full entry in
  "Where to read next".

**Glossary.** Each term set in bold at its definition gets a one-line
entry in Appendix A, with the chapter that defines it.

**Spelling and names.** American spelling ("license", "behavior").
"UNIX" in capitals. "erXos" with that capitalization, even at the start
of a sentence; rephrase if that reads badly. "Erlang/OTP" on first
mention, then "OTP" for the libraries and "ERTS" for the runtime
system.

**Architecture terms.** General chapters say "kernel mode" and "user
mode", as the design documents must. An architecture's own terms
appear only in passages about that architecture, explained at first
use.

**Punctuation.** Straight quotes. Commas, colons and parentheses, not
dashes; a dash that joins two thoughts usually hides two sentences.
Lines wrapped at about 72 columns, as the rest of `docs/`.

**Units.** Digits with units: `4 KiB`, `1 ms`, `100 MiB`. Binary
prefixes (KiB, MiB) for memory sizes.

## The writer's checklist

Run this before committing a chapter. Each check is concrete enough to
pass or fail.

1. **First sentence.** Read the first sentence of the chapter and of
   each section alone. Does each make you want the next? Rewrite the
   ones that announce a topic.
2. **Question per section.** Write each section's question in one line.
   Does the section's first paragraph answer it?
3. **Terms defined.** List every bold term. For each, find its first
   use: is it defined there or before? List every other technical term
   the chapter uses: is each defined here, glossed with a link, or
   defined in an earlier chapter?
4. **Built or designed.** For each present-tense sentence about what
   the system does, find the evidence: README.md's Current status, a
   test, a path in the tree (`git ls-files`). A claim with no evidence
   is either in the design documents, and says in its own sentence
   that it is designed and not built, or it goes.
5. **No schedule.** Search for milestones, releases, phases, stopgap
   status and FD rows, for example with
   `grep -n -E 'M[0-9]+|0\.[12]|Phase|stopgap|FD[0-9]+|downside|own kernel' FILE`.
   Is every property one the system has on Fiasco, built or designed?
6. **Reasons.** For each mechanism, is the reason in the same
   paragraph? For each major choice, is an alternative named?
7. **Code and paths.** Does every path exist? Does every code block
   match the tree? Is every block under about 25 lines, with a
   sentence after it saying what to notice?
8. **Numbers.** Does every number carry its conditions and its record?
9. **Banned words.** Search for the words in [Words](#words), for
   example with
   `grep -n -i -w -E 'obviously|clearly|simply|just|very|currently|will' FILE`,
   and fix each hit or justify it.
10. **Sentence length.** Split every sentence over 30 words.
11. **The cut pass.** Count the words (`wc -w`). Cut 10 to 20 percent
    without losing a fact: repeated points, throat-clearing,
    intensifiers, a second example where one was enough. Count again.
12. **Read aloud.** Read the chapter aloud, or at the pace of speech.
    Mark every place you stumble or run out of breath. Rewrite those.
13. **Links.** Every relative link and anchor resolves: `ruby
    tools/build_book.rb` builds the book and refuses any that does not,
    naming the file and line.
14. **Status box.** Does it agree with the sentences below it?

## The newcomer review

After the writer's checklist, a separate review agent reads the
chapter as the reader of [The reader](#the-reader): C and UNIX, little
Erlang, no microkernels. It reads the chapter alone, in order, without
the design documents, and reports:

* each term it met before it was defined;
* each sentence it had to read twice, quoted;
* each claim made without a reason;
* each step in an argument it could not follow, and what was missing;
* each analogy that misled it, and where;
* each place the text seemed to assume the reader already knew;
* the one thing it would remember from each section, which the writer
  compares with the section's question.

A second pass, by an Erlang programmer persona who knows little UNIX
internals, reports the same for the operating system background.

An accuracy review is separate. It checks the chapter against the
design documents and the tree, claim by claim, and checks the status
box. The newcomer reviewer does not check accuracy, and the accuracy
reviewer does not judge clarity. Reason: each review is better when it
has one job.

**When rules conflict.** Orwell ends his rules with this one, and it
holds here: "Break any of these rules sooner than say anything
outright barbarous." A rule that makes a passage worse yields. Clarity
and accuracy come first; the rules serve them.

## What the guide draws on

The guide's rules are distilled from these sources, in its own words
and with erXos's own examples. Sources marked *read* were read for
this guide from the free public pages listed, on 2026-11-19. For the
others, the guide draws on the widely described approach of the work,
not on its text.

| Source | Taken from it | Read |
| --- | --- | --- |
| McKusick, Neville-Neil and Watson, *The Design and Implementation of the FreeBSD Operating System*, 2nd ed., 2014; sample chapter 4, "Process Management" | definition first, then history, then structures and mechanism; the reason for a mechanism shown through a concrete case; numbered sections and cross-references; a calm third person | read: <https://www.informit.com/articles/article.aspx?p=2249436> (page 1 of 9) |
| Remzi and Andrea Arpaci-Dusseau, *Operating Systems: Three Easy Pieces*, version 1.20; preface and chapter 4, "The Abstraction: The Process" | the problem stated first; a concrete example before the definition; timelines of behavior; asides kept apart from the main line; real code; a chapter summary | read: <https://pages.cs.wisc.edu/~remzi/OSTEP/preface.pdf>, <https://pages.cs.wisc.edu/~remzi/OSTEP/cpu-intro.pdf> |
| Joe Armstrong, *Making reliable distributed systems in the presence of software errors*, 2003 | open with the central question; say what the work is not about; give the short answer first and refine it | read: <https://erlang.org/download/armstrong_thesis_2003.pdf> (chapter 1, section 2.3) |
| Abelson and Sussman, *Structure and Interpretation of Computer Programs*, preface to the first edition | code is written for people to read | read: <https://mitp-content-server.mit.edu/books/content/sectbyfn/books_pres_0/6515/sicp.zip/full-text/book/book-Z-H-7.html> |
| George Orwell, "Politics and the English Language", 1946 | the six rules: no stale figures, short words, cut words, active voice, no jargon, break a rule before writing badly | read: <https://www.orwellfoundation.com/the-orwell-foundation/orwell/essays-and-other-works/politics-and-the-english-language/> |
| Scott Adams, "The Day You Became a Better Writer" | simplicity persuades; cut extra words; a first sentence that makes the reader curious; short sentences; actor before action; the concrete word | read: the essay's text as supplied with the request for this guide |
| Joseph M. Williams, *Style: Lessons in Clarity and Grace* | characters as subjects and actions as verbs; old information before new; stress at the end of the sentence | not read |
| Strunk and White, *The Elements of Style* | omit needless words; the active voice; definite, specific, concrete language | not read (the public-domain 1918 text was unreachable on 2026-11-19) |
| Kernighan and Ritchie, *The C Programming Language* | complete, small, real examples; a tutorial before the reference | not read |
| W. Richard Stevens, *Advanced Programming in the UNIX Environment* and *TCP/IP Illustrated* | every interface shown by a real program and its real output; differences between systems stated plainly | not read |
| Andrew Tanenbaum, *Operating Systems: Design and Implementation* | concepts first, then the real source of a real system | not read |
| John Lions, *Lions' Commentary on UNIX* | commentary keyed to real source; here, by path and function rather than line | not read |
| Kernighan and Plauger, *The Elements of Programming Style* | rules as short maxims, each shown by a before and after; the form of this guide | not read |
