# Provider terms check (open decision 5, M9-05)

What each provider says about running its coding CLI under a personal or consumer plan from another program, as Relay does. Checked 2026-10-11 from the providers' own pages where possible.

**This is research notes, not legal advice.** The terms have changed several times in 2026. Re-check before a public release, and ask the provider when a case is unclear.

## What Relay does

- **Runs the providers' own CLIs, unmodified**, on the person's machine (`claude`, `codex`, `gemini`, `opencode`, `aider`).
- **The person signs in through the provider's own flow**, for example `claude /login`. Relay never sees, stores or forwards their tokens.
- **Several agents can run at once and overnight.** Slots, queues and schedules start CLI processes without someone typing in each.
- **Share my agents (M6)**, off by default: a teammate can queue work that runs on *my* Mac with *my* CLI login.

## By provider

### Anthropic — Claude Code

Source: [Claude Code · Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance).

- **Consumer Terms apply to Free/Pro/Max** and Commercial Terms to Team, Enterprise and API.
- **Allowed:** an end user signing in to the unmodified Claude Code binary with their own subscription. Relay matches this.
- **Not allowed:** third-party apps offering Claude.ai login, routing requests through Free/Pro/Max credentials *on behalf of their users*, or collecting session tokens. Relay does none of these.
- **Ordinary use:** Pro/Max limits assume "ordinary, individual usage".
- **Risks for Relay:**
  - Heavy parallel or overnight queues may exceed ordinary individual use.
  - **Shared agents run teammates' work on one person's Pro/Max login.** That is close to using a personal plan on others' behalf.
- **Safer setup:** API key (Console), Bedrock or Vertex for shared or automated use, or Team/Enterprise seats.

Third-party reports, unverified, describe Anthropic tightening and then loosening third-party harness use in April 2026 ([morphllm](https://www.morphllm.com/claude-code-subscription)).

### OpenAI — Codex CLI

Sources: [Using Codex with your ChatGPT plan](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan) and [Codex authentication](https://developers.openai.com/codex/auth).

- Signing in with ChatGPT puts use under the ChatGPT Terms and that plan's limits.
- OpenAI **recommends an API key for programmatic Codex workflows** such as CI.
- I found nothing that explicitly forbids launching the CLI from a local orchestrator. The ChatGPT Terms text itself wasn't checked here.
- **Risk:** the same as Claude for shared agents and heavy unattended use.

### Google — Gemini CLI

Source: [Gemini CLI · Terms and privacy](https://geminicli.com/docs/resources/tos-privacy).

- The terms depend on the login:
  - personal Google account (Code Assist for individuals): Google ToS;
  - Gemini API key: Gemini API Terms;
  - Vertex AI: Google Cloud terms.
- **Explicit:** directly accessing the services behind Gemini CLI with third-party software "is a violation", and it may lead to suspension. The example given is reusing Gemini CLI OAuth in another tool.
- Relay launches the official binary and doesn't touch its OAuth. The page doesn't say whether that counts.
- **Highest risk of the five on personal logins.** With a Gemini API key or Vertex the question goes away.

### DeepSeek via OpenCode, and Aider

Both use **the person's own API key**, billed per use under the provider's API terms. Automation is the normal case, so there is no consumer-plan question.

## What this means for Relay

Decided 2026-10-11: **warn only** (point 2's first option). Settings → Team carries the warning; nothing is blocked.

Proposed:

1. **Keep** running the unmodified CLIs with the person's own sign-in. Never touch tokens. This is what Anthropic explicitly allows.
2. **Shared agents:** recommend, or require, API-key or Team/Enterprise logins for agents a person shares. The app now warns about this in Settings → Team. A stricter option: share per agent, and refuse to share an agent signed in with a consumer plan.
3. **Gemini:** suggest API-key or Vertex login in onboarding when Gemini CLI is found. Treat personal-login Gemini as "use at your own risk".
4. **Defaults:** keep slots modest for subscription logins (e.g. 2). Say plainly in onboarding that heavy unattended use is what API keys are for.
5. **Wording:** describe Relay as running "the CLIs you already use", never as offering access to Claude, ChatGPT or Gemini. Don't use provider names or logos in Relay's name or icon (Anthropic's trademark note on the same page).
