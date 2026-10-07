# Pitch: 3-minute script

Accompanies `PITCH-DECK.pptx` (6 slides, same text as the speaker notes).
Target time: ~3:00. Each block names its slide.

## Slide 1: Transaction disputes, resolved without escalating everything

Hi, we are the team. We are going to show a banking agent that resolves transaction disputes end to end, in Spanish and Portuguese. The demo is real: it runs on AWS, not on a local mock.

## Slide 2: Escalating everything is not customer service

The problem: a bot that escalates everything helps no one. A customer who spots a strange charge wants an answer, not a queue. Our bet is to verify against their real transactions and decide with auditable rules. We chose one flow and built it well: disputes, with eligibility as a second use case on the same pipeline.

## Slide 3: Model proposes, code disposes

Here is how it is built. A chat message reaches Step Functions and goes through five stages: understand, decide, act, verify, and escalate. The model does not make the decisions: they come from policies.yaml, which anyone can audit. The model only proposes; the code disposes. Everything runs on AWS, deployed with Terraform.

## Slide 4: Decide with evidence, not guesswork

To decide which charge is being disputed, we combine merchant, amount, category and date. If there is no clear candidate, the bot asks instead of guessing. There is also an explicit escalation rule for high amounts and repeat complainants. We tested with real data from the dataset: two customers, and charges the dataset itself marks as fraud.

## Slide 5: No login without an email code

Security. Every login requires a single-use code by email, with no exceptions, to prevent impersonation. The response never reveals whether a customer exists. And although we use real data from the dataset, the emails are routed to our inbox: no real person receives a code they did not ask for.

## Slide 6: Tested, and honest about what is missing

We close with evidence. We have tests in every service, a matcher evaluated on boundary cases, and a simulator that plays conversations against the real pipeline. The fraud classifier did not beat the baseline, and we document that as is. The agent handles Spanish and Portuguese: the language is detected per message, and replies are written natively, not machine-translated. We are also clear about the limits: the demo core is a mock, and in Portuguese an 8-digit ID is classified differently than in Spanish. You can try the demo now, and you can ask the team for the login code.
