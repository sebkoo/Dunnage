# One definition of a KNOWN AUTOMATED ATTRIBUTION LINE FORM.
#
#   awk -f attribution.awk -v mode=strip  FILE   # FILE without those lines
#   awk -f attribution.awk -v mode=detect FILE   # only those lines; exit 1 if any
#
# Scope, stated exactly, because the name invites a broader reading:
#
#   Catches   the specific line forms the tooling in use emits — anchored at
#             line start, trailer-shaped or the generated-with line.
#   Does not  catch every automated trailer. "Co-authored-by: GitHub Copilot"
#             and "Assisted-by: SomeOtherAgent <bot@example.com>" pass. Widening
#             it to all Co-authored-by: lines would delete human co-authors,
#             which the policy explicitly preserves.
#   Does not  match prose. A commit body may name a vendor, a domain, or a tool:
#             "Validated against Claude Code docs" is a sentence, not a claim of
#             authorship.
#
# So this file enforces a subset of the written policy. The policy is the rule a
# person keeps; this is a device that catches the forms it knows.
#
# And it is a policy implementation, not a cryptographically independent verifier
# of that policy. It lives in the repository it audits: a later commit can edit
# this file, and every audit after that commit judges by the edited rules. At
# bootstrap time the copy is the one written from bootstrap.sh a second earlier,
# so the loop only opens afterwards. Treat a change to this file as a reviewed
# change, the same as a change to production code.

function prohibited(line,   probe) {
  probe = tolower(line)
  sub(/^[ \t]+/, "", probe)
  if (probe ~ /^co-authored-by:[ \t]*.*(anthropic\.com|<claude)/)          return 1
  if (probe ~ /^(claude-session|claude-code-session):[ \t]*http/)          return 1
  if (probe ~ /^(assisted-by|generated-by|ai-assisted-by):[ \t]*.*claude/) return 1
  if (probe ~ /^.?.?.?.?[ \t]*generated with .*claude code/)               return 1
  return 0
}

{
  if (prohibited($0)) { found = 1; if (mode == "detect") print label $0 }
  else if (mode != "detect")      print
}

END { if (found && mode == "detect") exit 1 }
