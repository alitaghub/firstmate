# Telegram captain channel

A private Telegram chat between the captain and firstmate.
Messages the captain sends from a phone become queued notes firstmate reads at its next check, and firstmate can push a notification back when something genuinely needs the captain.

It exists for one problem a status page cannot solve.
A page is pull: it shows everything, beautifully, when the captain remembers to open it.
Telegram is push: the phone buzzes.
That is the missing half when finished work or a one-word decision would otherwise wait an hour for the captain to reach a terminal.

The channel ships inert.
With no token and no allowlist, nothing is polled, nothing is sent, and no Telegram call is ever made.

## What an inbound message can and cannot do

An accepted message does exactly one thing: it becomes a captain inbox note.

It never merges a pull request, never answers a held captain decision, never starts a worker, and never runs anything from its own content.
Firstmate decides what the captain's words mean, with the backlog and the fleet state in front of it, exactly as it does for words typed at the terminal.
That is not a limitation to route around later: putting that judgment in a poller would move merge and decision authority out of the agent and into a text-matching script.

Firstmate reading a note that says "yes, merge that PR" and then merging is a different thing, and it stays available.
The distinction that matters is who decides.

## Who is allowed to talk to the bot

A Telegram bot is a public object.
Its username is searchable, its `t.me` link opens for anyone, and anyone who finds it can send it a message that arrives on this machine.

So the allowlist is not a convenience feature.
It is the reason this channel is safe to have at all: without it, anyone who found the bot could give instructions to an agent that runs commands on the captain's machine and opens pull requests under his GitHub account.

A message is accepted only when every one of these holds:

- it is a plain new `message`, not an edit, a channel post, a reaction, or any other update type;
- `message.from.id` is on the allowlist;
- `message.chat.id` is on the allowlist;
- it carries no `forward_*` field;
- it was not composed through another bot (`via_bot`);
- the sender is not a bot account;
- it has non-empty text.

Anything else is refused, counted, and named on the captured result.

Two of those deserve the reasoning spelled out.

**Why the chat id as well as the sender.**
In a private chat the two are the same number, and a stranger messaging the bot creates a *different* chat with a different chat id, so the sender check alone would already be enough.
Checking both keeps the rule correct if the chat shape ever changes: in a group or a channel every member posts into one shared chat id, and a chat-only check would let every member instruct firstmate.

**Why a forward is refused even from the captain.**
`from.id` is the captain, so the sender check passes, but the words were written by somebody else.
Forwarding a stranger's message must not launder it into an instruction.
To hand firstmate something someone else wrote, retype or paste it, which makes it the captain's own.

Ids are matched numerically and never by username.
A username can be released and claimed by somebody else; a numeric id is permanent, so renaming an account changes nothing here.

## The bot token

The token is not a password to the bot; it **is** the bot.
Anyone holding it can read every message queued for it and send messages as it.
It does not give access to the captain's Telegram account, his other chats, or his machine.

It lives as one key in the home's gitignored `.env`, the same place and the same shape as the Relay pairing token.
It is never printed, never echoed, and never passed to `curl` as a command-line argument, because every argument of every process on a machine is readable with `ps`.
It reaches `curl` through a config file on standard input instead, and it is redacted out of `curl`'s own diagnostics before anything is printed.

## Setup

Five minutes, and the captain does the token step himself so it never appears in a transcript.

1. **Create the bot** with Telegram's BotFather if there is not one already, and open a normal one-to-one chat with it.
   Not a channel and not a group: a private chat is the only shape where "who sent this" and "which conversation is this" are the same fact.

2. **Put the token in `.env`**, from a terminal, without pasting it into a conversation:

   ```bash
   cd ~/github/firstmate
   printf 'FM_TELEGRAM_TOKEN=%s\n' 'PASTE_TOKEN_HERE' >> .env
   chmod 600 .env
   ```

3. **Message the bot once** from Telegram - `hello` is enough.
   This is also required for outbound to work at all: Telegram blocks a bot from starting a conversation, so the bot cannot message the captain until the captain has messaged it.

4. **Find the numeric id.**
   In Telegram, open Settings and tap the account row; on most clients the numeric user id is shown there, and it is also what any account-info view reports.
   In a one-to-one private chat the user id and the chat id are the same number, which is what the allowlist needs.
   Read it from the captain's own account rather than from whatever last messaged the bot: the bot is public, so a stranger can have probed it in between, and one wrong number pasted here is the whole safety argument gone.

5. **Write the allowlist**, one numeric id per line, with an optional trailing comment:

   ```
   # ~/github/firstmate/config/telegram-allow
   987654321        # the captain
   ```

6. **Turn on Telegram Two-Step Verification** (Settings, then Privacy and Security).
   The captain's Telegram account is now a credential to his machine, so it deserves a password rather than SMS alone, and this closes the SIM-swap path.

7. **Check it**, then arm it:

   ```bash
   bin/fm-telegram.sh status
   bin/fm-procevent-telegram.sh arm
   ```

Both files are gitignored, and the presence of both is the opt-in.
With either missing the channel is inert.

## Turning it off, and revoking

| Speed | Action | Effect |
| --- | --- | --- |
| Seconds, locally | Delete the token line from `.env`, or delete `config/telegram-allow` | The poll stops within its current window and no new one is armed. The fastest local kill switch. |
| Seconds, from any Telegram client | BotFather `/token` to regenerate | The old token dies immediately and firstmate stops reading until the new one is pasted in. |
| Permanent | BotFather `/deletebot` | The bot is gone and its username is freed. |
| Also | Telegram Settings, Devices, terminate the lost session | Removes a stolen phone from the account. |

Revoking stops firstmate *reading*.
It does not un-queue a message that already arrived, so after losing a phone, revoke and then check the pending notes with `bin/fm-inbox.sh list`.

## What outbound may carry

`bin/fm-telegram.sh notify` is a doorbell for the status page, not a second copy of it.

Two things call it automatically, and nothing else does:

- `escalate_flush` in `bin/fm-supervise-daemon.sh` pushes the same away-mode escalation digest it has just injected into the supervisor pane - never a second summary that could drift from it. It fires only while away mode is active, only after the escalation has landed, and a failed or unconfigured channel is logged and swallowed, so the terminal escalation is never blocked or delayed by Telegram.
- `tell_the_captain_it_was_refused` in `bin/fm-procevent-telegram.sh` sends one sentence when an inbound message is refused, and only to a sender already on the allowlist - see [When a message is refused](#when-a-message-is-refused) below.

So disabling the daemon push does not silence the bot; a refused forward still produces a reply.

One digest is held back from the phone and the phone only: the hourly pause re-surface (`paused <age>s (awaiting external, ...)`), which restates a wait nobody has changed. It still reaches the supervisor pane exactly as before. The `captain-held` line the same re-surface arm produces is a decision that needs him, so it does buzz.

Send only what `AGENTS.md` section 9 already says must reach the captain immediately: work ready for review with its link, a finished investigation, a decision that needs him, a real blocker, anything destructive or irreversible, a needed credential.
Never routine progress, empty polls, elapsed time, or no-change updates.
A phone buzz is more expensive than a line of terminal text, and a channel that cries wolf gets muted - at which point it is worse than not having one.

The away-mode wedge alarm can reach the same channel with no new mechanism, because `config/wedge-alarm` accepts a `command:` directive:

```
command:/home/you/github/firstmate/bin/fm-telegram.sh notify -
```

See [`wedge-alarm.md`](wedge-alarm.md) for that file's own contract.

## How reading works, and what it costs

Firstmate reads by long polling: it makes an ordinary outgoing request that Telegram holds open until a message arrives or the window closes.
Nothing has to be reachable from the internet, which is why webhooks are not used - Telegram's servers would have to dial in to the captain's machine, and there is no public address for them to dial.

The poll runs as a registered process-event source, so the blocking call never holds a conversational turn, and the runner's one-owner-per-source rule keeps two firstmate homes sharing a store from both polling the same bot token - the state Telegram answers with `409 Conflict`.

**A message is never lost to a crash, but it can be delivered twice.**
The read position moves only after a note is safely on disk.
The other order would confirm the message to Telegram, which then drops it, and a crash at that moment would lose the captain's instruction outright.
So the channel chooses a possible duplicate over a possible loss, and then removes the duplicate: every queued message leaves a receipt, and a replay skips anything that already has one.

**Two failure classes, two different answers.** The line is *will this fix itself*, not *did the request get an answer*.

*Unreachable* - re-arms and keeps polling, silently, because a brief outage must not take the channel down while the captain is away:

- no answer at all: no wifi, no DNS, a VPN restart, a laptop waking up;
- `429 Too Many Requests`, which says in its own body how long to wait;
- any `5xx`, which is Telegram's edge failing;
- a body that is not Bot API JSON at all, which is an edge gateway page wearing the wrong clothes.

*Refused* - stops and raises a wake, because re-polling burns the same failure in a loop until somebody changes something:

- `401 Unauthorized`: the token was rejected or revoked;
- `409 Conflict`: a second reader is polling the same bot.

**The one hard limit: Telegram keeps an unconfirmed message for 24 hours.**
If the machine is off for longer than that, messages older than a day are gone from Telegram's side and cannot be recovered.

**Bot chats are not end-to-end encrypted.**
They are cloud chats and Telegram's servers can read them.
Use this channel for instructions and decisions, not for pasting secrets, credentials, or private code.

## When a message is refused

A refused message is never read and never becomes a note - that is the check working.
If the sender is already on the allowlist, the bot replies with one sentence saying why, so a forward that was quietly dropped does not leave the captain waiting for an answer that is never coming.
If the sender is *not* on the allowlist, nothing goes out at all: no reply, no connection. A bot that answers an unknown sender confirms to whoever probed it that it exists, which would turn the allowlist into a probe amplifier.
The reply always goes to the allowlisted chat, never to the chat the refused message arrived on.

## An unlocked phone

Stated plainly: anyone holding the captain's unlocked phone has his Telegram, and can send a message that passes every check above.
No allowlist can tell them apart.
That is the same exposure as someone holding his unlocked laptop with a firstmate session open, and it is the honest price of a phone channel.

What limits the damage is that a message only ever becomes a queued note.
Firstmate still escalates anything destructive, irreversible, or security-sensitive before doing it.

## Where each piece lives

- `bin/fm-telegram-lib.sh` - credential handling, transport, and the accept/reject check. The security boundary.
- `bin/fm-procevent-telegram.sh` - the long poll, and turning accepted updates into notes.
- `bin/fm-telegram.sh` - `notify` and `status`.
- `tests/fm-telegram.test.sh` - the accept case and every rejection above, against fixture updates.

Each script's header and `--help` own its exact flags and mechanics.
[`configuration.md`](configuration.md#telegram-captain-channel-env--configtelegram-allow) owns the two configuration files.
