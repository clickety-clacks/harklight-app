# Harklight product guidance

Scope: Harklight server, clients and hosted SaaS work. Historical Attention names
in these components do not exclude them. This file does not govern unrelated
products.

## Tests and gates

Controlling product instruction, 2026-10-13:

> any test or gate that does not directly test the business logic or specification of the product must be deleted and even better not written or installed in the first place

Apply this criterion to existing and proposed Harklight tests and gates now.
Delete those that do not qualify; retain those that directly establish specified
product behavior. Do not substitute a blanket category exemption or another
process gate for this criterion. Review and implementation methods remain with
the accountable existing owners.

Use this instruction in current delivery and reviewer work. Preserve historical
evidence as history when removing an active test or gate; do not rewrite prior
results. Report actual adoption and removals through existing custody, identifying
the affected source or guidance and concrete result. Do not claim removal from a
queued instruction. Where an externally enforced tool prevents a change, report the exact refusal;
this instruction does not authorize changing that tool or exempt Harklight-owned
gates from the criterion.
