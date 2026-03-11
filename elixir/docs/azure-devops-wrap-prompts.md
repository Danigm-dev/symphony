# Azure DevOps Wrap Copy/Paste Prompts

Usa este archivo para lanzar una CLI distinta por user story.

## Reglas de uso

- Ejecuta las historias en este orden: `US-01 -> US-02 -> US-03 -> US-04 -> US-05 -> US-06 -> US-07 -> US-08 -> US-09`.
- Rama de integración para este esfuerzo: `devops-wrapper`.
- No pegues el prompt de la siguiente historia hasta que la anterior esté mergeada en
  `devops-wrapper`.
- Cada historia debe arrancar desde una rama nueva creada sobre `devops-wrapper`.
- Está prohibido implementar una historia directamente sobre la rama `devops-wrapper`.
- El destino de merge/PR de cada historia es `devops-wrapper`, no `main`.
- Si `openai/symphony` no es escribible o no tiene `devops-wrapper`, usa el fork ya aterrizado para
  esta cadena de historias:
  - repo: `Danigm-dev/symphony`
  - branch de integración: `devops-wrapper`
  - `US-01` quedó mergeada ahí en `f38b29a3f2c0625f7641a63da0209b1704403c69`
- Hasta que exista un `openai/symphony:devops-wrapper` escribible, cada historia nueva debe salir
  de `Danigm-dev/symphony:devops-wrapper` y mergear de vuelta a esa misma rama.
- Convención de ramas recomendada:
  - `dw-us-01-neutral-issue-contract`
  - `dw-us-02-config-routing`
  - `dw-us-03-provider-aware-runtime`
  - `dw-us-04-azure-read-adapter`
  - `dw-us-05-azure-write-path`
  - `dw-us-06-azure-dynamic-tool`
  - `dw-us-07-azure-skills-cleanup`
  - `dw-us-08-azure-docs-spec`
  - `dw-us-09-azure-hardening`
- No uses ramas tipo `devops-wrapper/us-01-...`; colisionan con la rama `devops-wrapper`.
- Cada CLI debe respetar el `Owns files`, `Scope`, `Acceptance criteria` y `Do not include` de
  `docs/azure-devops-wrap-plan.md`.
- Si una CLI detecta que necesita trabajo de una historia posterior, debe parar, documentarlo y no
  ampliar el scope.

## Excepción de baseline agrupado aceptada

Para esta cadena existe una excepción operativa aceptada por el operador:

- `US-01` sí quedó integrada en `Danigm-dev/symphony:devops-wrapper` en
  `f38b29a3f2c0625f7641a63da0209b1704403c69`.
- `US-02`, `US-03`, `US-04` y `US-05` se aceptan como baseline agrupado en el commit local
  `158998b` (`Stack local Azure base through US-05`), aunque no hayan quedado cerradas una por una
  con PR/merge individual.
- Solo para arrancar `US-06`, una CLI puede tratar `US-02`..`US-05` como dependencias satisfechas
  si trabaja sobre un checkout o rama que contenga `158998b` o un descendiente suyo.
- Esta excepción no reescribe el criterio general de “historia cerrada”: las historias agrupadas no
  pasan a considerarse cerradas retroactivamente; solo se acepta ese baseline para desbloquear la
  implementación de `US-06` y posteriores.
- Si una CLI no encuentra `158998b` en su grafo local, debe declarar bloqueo o pedir al operador el
  baseline correcto antes de continuar.

## Preflight obligatorio antes de tocar código

Cada CLI debe ejecutar y registrar estas comprobaciones antes de editar nada:

1. Confirmar que no está en la rama de integración:
   - `git branch --show-current` debe devolver la rama de la historia, nunca `devops-wrapper`.
2. Confirmar que el checkout/worktree de la historia está limpio:
   - `git status --short` debe estar vacío antes de empezar.
3. Confirmar que la dependencia anterior está de verdad integrada en `devops-wrapper`:
   - no vale un handoff local, ni una rama local, ni un commit suelto fuera de la integración;
   - debe existir evidencia con `git log`, `git branch --contains <sha>`, `gh pr view`, o equivalente;
   - excepción documentada: para arrancar `US-06`, también vale como evidencia el baseline agrupado
     aceptado en `158998b` si la CLI está trabajando explícitamente sobre ese baseline o un
     descendiente suyo;
   - si la historia anterior no está mergeada, la CLI debe parar ahí y declarar bloqueo, sin implementar la historia actual.
4. Confirmar remoto y base correctos:
   - repo de trabajo: `openai/symphony` si `devops-wrapper` es escribible;
   - si no, `Danigm-dev/symphony`;
   - base del PR: siempre `devops-wrapper`.
5. Guardar evidencia de contexto git antes de editar:
   - `git status --short`
   - `git branch --show-current`
   - `git log --oneline -n 5`
   - esta evidencia debe copiarse luego al handoff final o al PR body.

Si alguna de estas comprobaciones falla, la historia no puede arrancar.

## Ejecución end-to-end obligatoria

Cada CLI debe completar el ciclo entero de su user story. No vale parar tras editar código y dejar
la rama, el PR o el merge para otra sesión humana o para otra CLI.

Flujo obligatorio por historia:

1. Verificar que todas las dependencias listadas en el plan ya están mergeadas en
   `devops-wrapper`.
2. Crear un worktree o checkout limpio desde el último `devops-wrapper` válido para esta cadena
   (`origin` si existe y es escribible; si no, el fork documentado en el handoff anterior),
   usando la rama recomendada para esa historia.
3. Implementar solo el scope de la historia y solo en sus archivos propios.
4. Ejecutar la validación mínima de la historia y cualquier validación adicional necesaria para
   dejar verde la ruta actual Linear + GitHub.
5. Commitar los cambios de la historia.
6. Hacer push de la rama y abrir o actualizar el PR con base `devops-wrapper`.
7. Resolver conflictos, feedback y checks hasta que el PR quede mergeado en `devops-wrapper`, o
   declarar un bloqueo explícito si no puede cerrarse.
8. Terminar solo cuando la historia esté mergeada o claramente bloqueada, y entonces emitir el
   handoff obligatorio.

Reglas adicionales:

- No compartas un checkout sucio entre dos historias activas; usa un worktree o clone separado por
  historia.
- Si el worktree de la historia acaba conteniendo cambios fuera de `Owns files`, la CLI debe parar,
  limpiar el aislamiento creando un worktree nuevo o declarar bloqueo. No puede seguir y luego dar la
  historia por cerrada.
- Si una skill genérica (`pull`, `push`, `land`) asume `main`, la CLI debe corregir ese supuesto o
  hacer esos pasos manualmente. En este esfuerzo, la base correcta es siempre `devops-wrapper`.
- No abras ni aterrices PRs contra `main`.
- Un estado `local-only`, `implemented locally`, `done in current worktree`, o equivalente, nunca
  cuenta como historia cerrada. Como mucho cuenta como bloqueo o como trabajo intermedio.

## Criterio de cierre operativo

Una historia solo se considera cerrada si se cumplen las cuatro condiciones:

1. Existe un commit de la historia en su rama dedicada.
2. Existe un PR con base `devops-wrapper`.
3. Ese PR está mergeado en `devops-wrapper`.
4. El handoff final incluye evidencia concreta de rama, commit, PR y merge.

Si falta cualquiera de esas cuatro cosas, la historia no está cerrada.

## Formato de handoff obligatorio

Cada CLI debe terminar su trabajo con este formato:

```text
Handoff US-XX

Branch:
- Name: ...
- Base: devops-wrapper
- Head commit: <sha>

PR / merge:
- PR: <url> | none
- Merge: merged into devops-wrapper at <sha> | blocked (explicar)

Preflight evidence:
- Previous dependency merged: yes/no + evidencia concreta
- Clean start: yes/no
- Correct base branch: yes/no
- Git context before edits:
  - `git status --short`: ...
  - `git branch --show-current`: ...
  - `git log --oneline -n 5`: ...

Changed files:
- ...

Tests run:
- ...

Acceptance criteria:
- [x] ...
- [x] ...
- [ ] ... (si quedó bloqueado, explicar)

Follow-ups / blockers:
- None
```

Reglas del handoff:

- No se permite `PR: none` si la historia fue implementada. Si hay código hecho pero no existe PR,
  el estado correcto es `blocked` y debe explicarse por qué no se abrió.
- No se permite `Branch: devops-wrapper` para una historia individual.
- `Head commit` es obligatorio. Si no existe commit, la historia no está cerrada.
- `Previous dependency merged` debe citar la evidencia mínima: merge SHA, PR URL o ambas.
- `Git context before edits` debe reflejar la salida real de los tres comandos de preflight, no un
  resumen inventado.
- Si la historia queda bloqueada antes de editar código, el handoff debe decirlo explícitamente en
  `Preflight evidence` y `Changed files` debe ser `- None`.

## Handoffs históricos de este worktree

Los siguientes handoffs son solo forensics del estado local encontrado en este checkout. No son un
ejemplo válido de cierre y no deben reutilizarse como plantilla de “historia cerrada”.

Los siguientes handoffs reflejan el estado real del checkout actual en la rama `devops-wrapper` a
fecha `2026-03-11`. Ninguno de ellos tiene todavía commit, PR o merge; por eso el campo `Merge`
figura como bloqueado/local-only.

```text
Handoff US-01

Branch:
- devops-wrapper

PR / merge:
- PR: none
- Merge: blocked (implemented locally in current worktree; no commit/PR/merge yet)

Changed files:
- elixir/lib/symphony_elixir/issue.ex
- elixir/lib/symphony_elixir/orchestrator.ex
- elixir/lib/symphony_elixir/agent_runner.ex
- elixir/lib/symphony_elixir/prompt_builder.ex
- elixir/lib/symphony_elixir/tracker/memory.ex
- elixir/lib/symphony_elixir/linear/issue.ex
- elixir/test/symphony_elixir/extensions_test.exs
- elixir/test/symphony_elixir/workspace_and_config_test.exs

Tests run:
- mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/workspace_and_config_test.exs
- mise exec -- mix test test/symphony_elixir/azure_devops_adapter_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/orchestrator_status_test.exs

Acceptance criteria:
- [x] The runtime compiles and runs against SymphonyElixir.Issue.
- [x] Existing Linear behavior stays unchanged in the current targeted test coverage.
- [x] Existing memory tracker behavior stays unchanged in the current targeted test coverage.
- [x] Current tests for the Linear path remain green after the refactor.

Follow-ups / blockers:
- Blocked on commit/PR/merge workflow not yet executed for this story.
```

```text
Handoff US-02

Branch:
- devops-wrapper

PR / merge:
- PR: none
- Merge: blocked (implemented locally in current worktree; no commit/PR/merge yet)

Changed files:
- elixir/lib/symphony_elixir/config.ex
- elixir/lib/symphony_elixir/tracker.ex
- elixir/test/support/test_support.exs
- elixir/test/symphony_elixir/core_test.exs
- elixir/test/symphony_elixir/extensions_test.exs

Tests run:
- mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/workspace_and_config_test.exs
- mise exec -- mix test test/symphony_elixir/azure_devops_adapter_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/orchestrator_status_test.exs

Acceptance criteria:
- [x] Linear config remains valid and behaviorally identical in current targeted coverage.
- [x] Azure config validates required fields and env fallbacks correctly.
- [x] Generic accessors exist for endpoint, token, assignee, active states, terminal states, and project reference.
- [x] Unsupported tracker kinds still fail with explicit errors.

Follow-ups / blockers:
- Blocked on commit/PR/merge workflow not yet executed for this story.
```

```text
Handoff US-03

Branch:
- devops-wrapper

PR / merge:
- PR: none
- Merge: blocked (implemented locally in current worktree; no commit/PR/merge yet)

Changed files:
- elixir/lib/symphony_elixir/orchestrator.ex
- elixir/lib/symphony_elixir/agent_runner.ex
- elixir/lib/symphony_elixir/prompt_builder.ex
- elixir/lib/symphony_elixir/status_dashboard.ex
- elixir/test/symphony_elixir/core_test.exs
- elixir/test/symphony_elixir/orchestrator_status_test.exs

Tests run:
- mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/orchestrator_status_test.exs
- mise exec -- mix test test/symphony_elixir/azure_devops_adapter_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/orchestrator_status_test.exs

Acceptance criteria:
- [x] Active and terminal state checks use generic config accessors.
- [x] Runtime log and error text no longer claim every provider is Linear.
- [x] Dashboard still renders correctly for the existing Linear path in current targeted coverage.
- [x] No behavior regression observed in reconciliation, retry, or continuation logic in current targeted coverage.

Follow-ups / blockers:
- Blocked on commit/PR/merge workflow not yet executed for this story.
```

```text
Handoff US-04

Branch:
- devops-wrapper

PR / merge:
- PR: none
- Merge: blocked (implemented locally in current worktree; no commit/PR/merge yet)

Changed files:
- elixir/lib/symphony_elixir/azure_devops/client.ex
- elixir/lib/symphony_elixir/azure_devops/adapter.ex
- elixir/test/symphony_elixir/azure_devops_adapter_test.exs
- elixir/test/symphony_elixir/core_test.exs
- elixir/test/symphony_elixir/extensions_test.exs

Tests run:
- mise exec -- mix test test/symphony_elixir/azure_devops_adapter_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/extensions_test.exs
- mise exec -- mix test test/symphony_elixir/azure_devops_adapter_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/orchestrator_status_test.exs

Acceptance criteria:
- [x] Candidate polling returns normalized issues from Azure.
- [x] State refresh works for running issue reconciliation.
- [x] URLs, timestamps, labels, priority, branch name, and blockers are mapped consistently.
- [x] Missing optional Azure fields do not break polling.

Follow-ups / blockers:
- US-05 still pending for Azure state mutation and comment mutation.
- Blocked on commit/PR/merge workflow not yet executed for this story.
```

## Regla general para todos los prompts

En todos los casos, el documento fuente y criterio de verdad es:

- `/home/danielgm/dev/symphony/symphony/elixir/docs/azure-devops-wrap-plan.md`

Si un prompt parece menos específico que el plan, manda el plan. Si hay duda sobre scope, archivos,
dependencias o criterios de aceptación, la CLI debe releer la historia correspondiente en el plan y
seguir esa definición.

## US-01

```text
Implementa US-01 del plan `/home/danielgm/dev/symphony/symphony/elixir/docs/azure-devops-wrap-plan.md`.

Antes de tocar código:
- Lee en el plan la sección `US-01: Introduce a provider-neutral issue contract`.
- Usa el plan como source of truth para `Depends on`, `Owns files`, `Scope`, `Acceptance criteria`
  y `Do not include`.
- Si este prompt y el plan difieren, manda el plan.

Objetivo:
Introducir un issue model neutral (`SymphonyElixir.Issue`) para que el runtime deje de depender
directamente de `SymphonyElixir.Linear.Issue`, sin cambiar el comportamiento actual de Linear ni del
memory tracker.

Dependencias:
- Ninguna. Esta historia arranca desde `devops-wrapper` actual.

Límites obligatorios:
- Modifica solo los archivos de US-01 y tests directamente relacionados.
- No añadas config Azure.
- No implementes cliente/adaptador Azure.
- No toques dynamic tools.

Archivos permitidos:
- `elixir/lib/symphony_elixir/issue.ex` (nuevo)
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/agent_runner.ex`
- `elixir/lib/symphony_elixir/prompt_builder.ex`
- `elixir/lib/symphony_elixir/tracker/memory.ex`
- `elixir/lib/symphony_elixir/linear/issue.ex`
- tests de runtime que hoy asumen `SymphonyElixir.Linear.Issue`

Entrega esperada:
- `SymphonyElixir.Issue` con los campos normalizados del plan.
- Runtime refactorizado a usar el issue neutral.
- `SymphonyElixir.Linear.Issue` conservado como wrapper/capa de compatibilidad.
- Tests relevantes actualizados sin cambiar la semántica existente.

Validación mínima:
- Ejecuta los tests dirigidos de runtime/config afectados por el refactor.
- Si puedes, incluye el comando exacto ejecutado en el handoff.

Criterio de cierre:
- El runtime compila y se comporta igual para Linear.
- El memory tracker sigue funcionando igual.
- No hay trabajo de historias posteriores mezclado.

Termina con el formato `Handoff US-01`.
```

## US-02

```text
Implementa US-02 del plan `/home/danielgm/dev/symphony/symphony/elixir/docs/azure-devops-wrap-plan.md`.

Antes de tocar código:
- Lee en el plan la sección `US-02: Extend config and tracker routing for provider awareness`.
- Usa el plan como source of truth para `Depends on`, `Owns files`, `Scope`, `Acceptance criteria`
  y `Do not include`.
- Si este prompt y el plan difieren, manda el plan.

Precondición:
- US-01 ya está mergeada en `devops-wrapper`.
- Esta rama debe salir de `devops-wrapper` actualizado.

Objetivo:
Extender `WORKFLOW.md`/config para soportar `tracker.kind: azure_devops` y enrutar el tracker por
provider, manteniendo compatibilidad completa con Linear.

Límites obligatorios:
- Modifica solo config/routing y tests relacionados.
- No implementes el adapter Azure todavía.
- No cambies mensajes/runtime fuera de lo estrictamente necesario para enrutar config.

Archivos permitidos:
- `elixir/lib/symphony_elixir/config.ex`
- `elixir/lib/symphony_elixir/tracker.ex`
- tests de config/workflow validation

Entrega esperada:
- Soporte para `tracker.kind: azure_devops`.
- Nuevos campos Azure del plan, con env fallbacks.
- Accessors genéricos para endpoint, token, assignee, active states, terminal states y project
  reference.
- Wrappers de compatibilidad para Linear si ayudan a migración segura.
- `Tracker.adapter/0` enruta por provider kind.

Validación mínima:
- Tests de config y workflow validation.
- Verifica explícitamente env fallbacks `AZURE_DEVOPS_TOKEN` y `AZURE_DEVOPS_ASSIGNEE`.

Criterio de cierre:
- Linear sigue siendo válido y comportándose igual.
- Azure config falla o valida de forma explícita según corresponda.
- No se introduce todavía ninguna lógica de API Azure.

Termina con el formato `Handoff US-02`.
```

## US-03

```text
Implementa US-03 del plan `/home/danielgm/dev/symphony/symphony/elixir/docs/azure-devops-wrap-plan.md`.

Antes de tocar código:
- Lee en el plan la sección `US-03: Make the runtime provider-aware without changing behavior`.
- Usa el plan como source of truth para `Depends on`, `Owns files`, `Scope`, `Acceptance criteria`
  y `Do not include`.
- Si este prompt y el plan difieren, manda el plan.

Precondición:
- US-02 ya está mergeada en `devops-wrapper`.
- Esta rama debe salir de `devops-wrapper` actualizado.

Objetivo:
Hacer el runtime provider-aware pero no provider-specific: usar accessors genéricos y eliminar texto
o supuestos innecesariamente ligados a Linear, sin cambiar el comportamiento operativo.

Límites obligatorios:
- No implementes llamadas Azure.
- No toques skills.
- No metas refactors adicionales fuera del runtime y dashboard.

Archivos permitidos:
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/agent_runner.ex`
- `elixir/lib/symphony_elixir/prompt_builder.ex`
- `elixir/lib/symphony_elixir/status_dashboard.ex`
- tests de runtime/dashboard

Entrega esperada:
- Sustituir lecturas `Config.linear_*` por accessors genéricos donde toque.
- Generalizar logs, errores, textos de continuación y docs internas del runtime.
- Mantener intacta la semántica de retry/reconcile/continuation.

Validación mínima:
- Tests de runtime.
- Tests/snapshots del dashboard si se ven afectados.

Criterio de cierre:
- El runtime deja de asumir que todo provider es Linear.
- La ruta actual Linear + GitHub sigue verde.
- No hay código Azure API ni skills en esta historia.

Termina con el formato `Handoff US-03`.
```

## US-04

```text
Implementa US-04 del plan `/home/danielgm/dev/symphony/symphony/elixir/docs/azure-devops-wrap-plan.md`.

Antes de tocar código:
- Lee en el plan la sección `US-04: Add the Azure Boards read adapter`.
- Usa el plan como source of truth para `Depends on`, `Owns files`, `Scope`, `Acceptance criteria`
  y `Do not include`.
- Si este prompt y el plan difieren, manda el plan.

Precondición:
- US-02 ya está mergeada en `devops-wrapper`.
- Esta rama debe salir de `devops-wrapper` actualizado.

Objetivo:
Crear el read adapter de Azure Boards para descubrir work items candidatos e hidratarlos como
`SymphonyElixir.Issue`.

Límites obligatorios:
- No implementes state mutation.
- No implementes comment mutation.
- No toques dynamic tools.
- No toques skills.

Archivos permitidos:
- `elixir/lib/symphony_elixir/azure_devops/client.ex` (nuevo)
- `elixir/lib/symphony_elixir/azure_devops/adapter.ex` (nuevo)
- tests del read path Azure

Entrega esperada:
- WIQL candidate discovery.
- Batch hydration a `SymphonyElixir.Issue`.
- `fetch_candidate_issues/0`
- `fetch_issues_by_states/1`
- `fetch_issue_states_by_ids/1`
- Resolución de `tracker.assignee: me`
- Mapping de relaciones/dependencias a `blocked_by`

Validación mínima:
- Tests del adapter Azure read-path.
- Casos para optional fields ausentes, prioridad, labels, assignee, timestamps, url y branch name.

Criterio de cierre:
- Polling y state refresh Azure funcionan en términos del tracker contract.
- Nada de write path Azure todavía.

Termina con el formato `Handoff US-04`.
```

## US-05

```text
Implementa US-05 del plan `/home/danielgm/dev/symphony/symphony/elixir/docs/azure-devops-wrap-plan.md`.

Antes de tocar código:
- Lee en el plan la sección `US-05: Add the Azure Boards write path`.
- Usa el plan como source of truth para `Depends on`, `Owns files`, `Scope`, `Acceptance criteria`
  y `Do not include`.
- Si este prompt y el plan difieren, manda el plan.

Precondición:
- US-04 ya está mergeada en `devops-wrapper`.
- Esta rama debe salir de `devops-wrapper` actualizado.

Objetivo:
Completar el write path Azure Boards para cambios de estado y primitivas de comentarios, manteniendo
estable el boundary público del tracker salvo que haya una razón estricta para un follow-up aparte.

Límites obligatorios:
- No toques push/land/cleanup.
- No hagas docs de workflow.
- No metas dynamic tool work aquí.

Archivos permitidos:
- `elixir/lib/symphony_elixir/azure_devops/client.ex`
- `elixir/lib/symphony_elixir/azure_devops/adapter.ex`
- tests del write path Azure

Entrega esperada:
- State updates vía JSON Patch.
- Helpers de comment create/list/update.
- `update_issue_state/2` cableado por el Azure adapter.
- Errores estructurados y sin silent no-ops.

Validación mínima:
- Tests del adapter Azure write-path.
- Casos de éxito y error para state update y comments.

Criterio de cierre:
- Azure ya tiene primitivas suficientes para que historias posteriores resuelvan workpad y state.
- Linear permanece intacto.

Termina con el formato `Handoff US-05`.
```

## US-06

```text
Implementa US-06 del plan `/home/danielgm/dev/symphony/symphony/elixir/docs/azure-devops-wrap-plan.md`.

Antes de tocar código:
- Lee en el plan la sección `US-06: Add the Azure dynamic tool`.
- Usa el plan como source of truth para `Depends on`, `Owns files`, `Scope`, `Acceptance criteria`
  y `Do not include`.
- Si este prompt y el plan difieren, manda el plan.

Precondición:
- US-05 ya está mergeada en `devops-wrapper`.
- Esta rama debe salir de `devops-wrapper` actualizado.

Objetivo:
Añadir el dynamic tool `azure_devops_request` como escape hatch raw para Azure Boards y Azure Repos,
sin romper `linear_graphql`.

Límites obligatorios:
- No implementes lógica de push/land.
- No toques cleanup task.
- Reutiliza helpers Azure existentes si hace falta, pero no expandas scope fuera del tool.

Archivos permitidos:
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
- tests de dynamic tool
- helpers Azure compartidos solo si son estrictamente necesarios para este tool

Entrega esperada:
- Nuevo tool `azure_devops_request`.
- Validación de `method`, `path`, `query?`, `body?`.
- Restricción a mismo host configurado.
- Reuso de auth Azure configurada en Symphony.
- Respuestas JSON en el mismo estilo de `linear_graphql`.

Validación mínima:
- `test/symphony_elixir/dynamic_tool_test.exs`
- Casos de invalid input, missing auth, non-2xx, cross-host y happy path.

Criterio de cierre:
- `linear_graphql` queda intacto.
- El tool Azure está listo para ser consumido por skills.

Termina con el formato `Handoff US-06`.
```

## US-07

```text
Implementa US-07 del plan `/home/danielgm/dev/symphony/symphony/elixir/docs/azure-devops-wrap-plan.md`.

Antes de tocar código:
- Lee en el plan la sección `US-07: Add Azure Repos operational skills and cleanup`.
- Usa el plan como source of truth para `Depends on`, `Owns files`, `Scope`, `Acceptance criteria`
  y `Do not include`.
- Si este prompt y el plan difieren, manda el plan.

Precondición:
- US-06 ya está mergeada en `devops-wrapper`.
- Esta rama debe salir de `devops-wrapper` actualizado.

Objetivo:
Hacer provider-aware los flujos operativos de repo para Azure Repos: push, land, cleanup, workpad y
PR linkage, manteniendo intacta la ruta actual GitHub.

Límites obligatorios:
- No cambies tracker polling/runtime core salvo ajustes mínimos inevitables y justificados.
- No metas documentación de usuario final más allá de notas mínimas requeridas por el código.
- Si los skills viven fuera de este repo, localiza su ruta real y limita los cambios a esa
  superficie; no inventes una estructura alternativa.

Archivos permitidos:
- `.codex/skills/azure_devops/SKILL.md` o ruta equivalente real
- `.codex/skills/push/SKILL.md` o ruta equivalente real
- `.codex/skills/land/SKILL.md` o ruta equivalente real
- `elixir/lib/mix/tasks/workspace.before_remove.ex`
- tests de cleanup/workflow task y los necesarios para estos flujos

Entrega esperada:
- Skill Azure específico.
- `push` provider-aware para create/update/recreate PR.
- `land` provider-aware para reviewers, threads, policies y squash complete.
- Cleanup provider-aware para abandonar/cerrar PRs Azure.
- Flujo de workpad Azure: find/create/reuse/update usando Azure Boards comments.
- PR linkage con prioridad: direct work-item link, `AB#<id>` como safety net, fallback en workpad.
- Aplicación de metadata Symphony mediante label/tag si existe, o equivalente en title/body/linking.

Validación mínima:
- Tests de `workspace.before_remove`.
- Tests o evidencia automatizada suficiente para branching de push/land si existen.
- Si alguna parte de skills no es testeable localmente, deja evidencia clara y concreta en el
  handoff de qué se validó y qué quedó manual.

Criterio de cierre:
- GitHub sigue igual.
- Azure puede completar el lifecycle operativo hasta handoff/land/cleanup.
- Se mantiene un único `## Codex Workpad` persistente salvo reset explícito en `Rework`.

Termina con el formato `Handoff US-07`.
```

## US-08

```text
Implementa US-08 del plan `/home/danielgm/dev/symphony/symphony/elixir/docs/azure-devops-wrap-plan.md`.

Antes de tocar código:
- Lee en el plan la sección `US-08: Document the Azure workflow and operator contract`.
- Usa el plan como source of truth para `Depends on`, `Owns files`, `Scope`, `Acceptance criteria`
  y `Do not include`.
- Si este prompt y el plan difieren, manda el plan.

Precondición:
- US-07 ya está mergeada en `devops-wrapper`.
- Esta rama debe salir de `devops-wrapper` actualizado.

Objetivo:
Documentar el contrato operativo Azure sin tocar el ejemplo Linear existente, incluyendo workflow
example, README y `SPEC.md`.

Límites obligatorios:
- No metas nueva lógica de producción.
- Cambios solo documentales, salvo nits mínimos para mantener exactitud.

Archivos permitidos:
- `elixir/WORKFLOW.azure_devops.md` (nuevo)
- `elixir/README.md`
- `SPEC.md`
- links/doc cross-references estrictamente necesarios

Entrega esperada:
- Workflow example Azure completo.
- Documentación de env vars, config keys y expectativas de skills Azure.
- Política de workpad y PR linkage documentada.
- `SPEC.md` actualizado de forma aditiva para reflejar el tracker contract genérico y secciones
  provider-specific para Linear y Azure.

Validación mínima:
- Revisión de coherencia documental con el código ya mergeado.
- No hace falta ampliar código productivo.

Criterio de cierre:
- La documentación ya no implica que solo existe Linear.
- Un operador puede bootstrapear un workflow Azure real con lo escrito.

Termina con el formato `Handoff US-08`.
```

## US-09

```text
Implementa US-09 del plan `/home/danielgm/dev/symphony/symphony/elixir/docs/azure-devops-wrap-plan.md`.

Antes de tocar código:
- Lee en el plan la sección `US-09: Close the parity gap with integration and regression coverage`.
- Usa el plan como source of truth para `Depends on`, `Owns files`, `Scope`, `Acceptance criteria`
  y `Do not include`.
- Si este prompt y el plan difieren, manda el plan.

Precondición:
- US-08 ya está mergeada en `devops-wrapper`.
- Esta rama debe salir de `devops-wrapper` actualizado.

Objetivo:
Cerrar la brecha de paridad con cobertura de regresión e integración, sin introducir nuevo scope de
feature.

Límites obligatorios:
- No añadas nuevas features de producción.
- Si encuentras un agujero funcional real, documenta el follow-up; no lo metas aquí salvo que sea
  un fix mínimo indispensable para que la cobertura tenga sentido.

Archivos permitidos:
- tests cross-cutting
- notas/checklist de validación si hacen falta

Entrega esperada:
- Cobertura adicional para config, runtime reconciliation, dynamic tooling, Azure adapter behavior y
  cleanup flow.
- Ejecución del quality gate completo al final.

Validación mínima:
- Targeted tests nuevos/ajustados.
- Full gate (`mise exec -- make all`) o explicación concreta si algo del entorno lo impide.

Criterio de cierre:
- La suite Linear sigue verde.
- La ruta Azure queda cubierta en los puntos críticos del plan.
- No se cuela trabajo de producto nuevo bajo la excusa de hardening.

Termina con el formato `Handoff US-09`.
```
