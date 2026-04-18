---
name: email-response
description: How to handle inbound emails — decide whether to reply, compose the response, and send it back via the comms agent.
agents: cognitive
---

## Inbound Email Handling

When an inbound email arrives, you receive it as a scheduler-triggered cycle
with `<scheduler_context>` containing tags `email, inbound`. The email body
includes `Subject:`, `From:`, and the message text.

**This is someone writing to you. They expect a reply.**

### Decision: Should You Reply?

Reply to **all** inbound emails unless:
- It is automated/no-reply (mailing list, notification, bounce)
- It is spam or unsolicited marketing
- The sender is not on your allowed recipients list (you cannot reply anyway)

When in doubt, reply. Silence is worse than a brief acknowledgement.

### How to Reply

1. **Read the email carefully.** Understand what is being asked or said.

2. **Do any work needed first.** If the email asks you to research something,
   schedule something, or check something — do that before composing your reply.
   Use your tools. Don't reply with "I'll look into it" when you can look into
   it right now and reply with the answer.

3. **Compose your reply.** Write as yourself — clear, direct, helpful. Match
   the tone and formality of the sender. Keep it concise. Sign off naturally
   with your own name (the `agent_name` in your persona — your "first name"),
   not the framework name "Springdrift" (that's your "surname"). If you do
   not know your name, check the persona before sending.

4. **Send via agent_comms.** Delegate to the comms agent:
   ```
   agent_comms: Send a reply to <sender_email>.
   Subject: Re: <original_subject>
   Body: <your composed reply>
   ```

5. **If you cannot reply** (sender not on allowlist, comms disabled), note this
   in your response to the cognitive loop so the operator sees it in the chat UI.

### What NOT to Do

- Do not ignore inbound emails. They are not notifications — they are messages
  from people who chose to write to you.
- Do not reply with system internals, raw XML, cycle IDs, or tool output.
  Write like a person.
- Do not quote the entire original email back. Just respond to the content.
- Do not send multiple replies to the same email.
- Do not reply to your own outbound messages that bounced back.

### Thread Awareness

If the email is a reply in an existing thread (subject starts with "Re:"),
check your comms history for context. Use `check_inbox` or `read_message`
via the comms agent if you need to see the full thread before replying.

### Example

**Inbound:**
```
Subject: Re: Weekly research update
From: seamus@corvideon.ie

Can you add inflation data to next week's report?
```

**Your response:**
1. Note the request (memory_write if needed for next week's scheduled task)
2. Delegate to comms:
   ```
   agent_comms: Reply to seamus@corvideon.ie
   Subject: Re: Weekly research update
   Body: Done — I've added inflation data (CSO CPI + Eurostat HICP) to
   the research template for next week's report. It'll appear in the
   macro indicators section.
   ```
