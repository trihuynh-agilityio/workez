#!/usr/bin/env bash
# Structure rules: the route-import check from the README, the warning and the fields the skills
# and agents carry, and the fixtures with and without structure docs.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FX="$SRC/tests/fixtures/structure-rules"
has() { grep -qF -- "$2" "$1"; }

# 1. The route-import check fails on the violating fixture and passes once the route uses a service.
out="$(cd "$FX/with-rules" && bash "$FX/check-route-imports.sh" 2>&1)"; rc=$?
[[ $rc == 1 && "$out" == *"src/routes/orders.ts"* ]] \
  && ok "route-import check fails on with-rules and names src/routes/orders.ts" || ko "route check (rc=$rc): $out"
cp -R "$FX/with-rules" "$T/fixed"
sed -i.bak 's#"../db/client"#"../services/orders"#' "$T/fixed/src/routes/orders.ts"; rm "$T/fixed/src/routes/orders.ts.bak"
(cd "$T/fixed" && bash "$FX/check-route-imports.sh" >/dev/null 2>&1) \
  && ok "route-import check passes once the route imports a service" || ko "fixed route still fails"

# 2. The warning text is in the three skills that print it.
w='No structure rules found for <area>; placement cannot be checked'
for s in project-context write-plan build-task; do
  has "$SRC/skills/$s/SKILL.md" "$w" && ok "$s carries the structure warning" || ko "$s lacks the warning"
done

# 3. Placement and Standards.
has "$SRC/skills/write-plan/SKILL.md" '- **Placement**:' && ok "write-plan lists Placement as a task field" || ko "write-plan Placement"
has "$SRC/skills/write-plan/SKILL.md" '## Standards' && ok "write-plan layout has ## Standards" || ko "write-plan Standards"
has "$SRC/skills/build-task/SKILL.md" '## Standards' && ok "build-task layout has ## Standards" || ko "build-task Standards"
has "$SRC/skills/build-task/SKILL.md" 'Placement' && ok "build-task requires Placement" || ko "build-task Placement"
has "$SRC/skills/create-task-issues/SKILL.md" 'Placement' && ok "create-task-issues shows Placement" || ko "create-task-issues Placement"
has "$SRC/agents/implementer.md" 'Placement' && ok "implementer follows Placement" || ko "implementer Placement"

# 4. The reviewer checklist.
r="$SRC/agents/code-reviewer.md"
has "$r" 'existing helper' && has "$r" 'Layer boundaries' && has "$r" '`as` casts' && has "$r" '`any`' \
  && has "$r" '3 or more places' && ok "code-reviewer has the four checklist items" || ko "reviewer checklist"
has "$r" 'Rule: <file> (section <heading>)' && ok "code-reviewer requires a Rule: citation" || ko "reviewer Rule citation"

# 4b. Both skills invoke project-context, so they need the Skill tool.
for s in write-plan build-task; do
  grep -E '^allowed-tools:.*\bSkill\b' "$SRC/skills/$s/SKILL.md" >/dev/null && ok "$s allows the Skill tool" || ko "$s allowed-tools lacks Skill"
done

# 5. The "no structure docs" heuristic project-context describes.
has_structure() {
  local d="$1"
  grep -qiE '^#+ .*(structure|layer)' "$d/CLAUDE.md" 2>/dev/null && return 0
  [[ -n "$(find "$d" -name 'AGENTS.md' -o -iname 'ARCHITECTURE*' 2>/dev/null | head -1)" ]]
}
has_structure "$FX/with-rules" && ok "with-rules has structure docs" || ko "with-rules should have structure docs"
has_structure "$FX/no-rules" && ko "no-rules should have none" || ok "no-rules has no structure docs"

done_tests
