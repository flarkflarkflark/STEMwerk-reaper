# Prompt-safety conventies voor gegenereerde shell-opdrachten

Destructieve operaties (rm -rf, resets) in gegenereerde prompts vereisen
drie lagen:

1. Preventie: find-gebaseerde cleanup altijd met -mindepth 1, zodat het
   startpunt zelf nooit in de deletelijst komt.
2. Guard: ancestor-safe KEEP-check, geen exact-match:
   case "$KEEP" in "$d"|"$d"/*) echo "REFUSE_TO_REMOVE_KEEP_OR_PARENT: $d"; exit 2;; esac
3. Menselijke poort: dry-run tonen, STOPPEN, expliciet akkoord vragen
   vóór executie. Nooit auto-delete direct na een dry-run.

Aanvullend: destructieve of overschrijvende acties krijgen een positieve
verificatie vooraf (existence/KEEP-checks) en een mechanische controle
achteraf (bv. git diff --name-only HEAD~1..HEAD na een commit).

Achtergrond: cleanup-incident juli 2026, zie
MAC_LINUX_ROFORMER_ASEP_0443_RND.md.
