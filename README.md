# AI-First Banking Agent — disputas de cargo resueltas automáticamente, sin escalar todo a un humano

Un agente que decide si un cargo no reconocido puede resolverse solo o
necesita un humano — usando matching real de transacciones (embeddings,
no un substring), en vez de la respuesta por defecto de la mayoría de
bots bancarios: escalar cualquier cosa ambigua. Verificado no solo con
tests unitarios sino con un simulador de conversaciones que juega el rol
de distintos clientes reales y expone fallas que un test aislado no
encuentra (ver `docs/STATUS.md`, fase "Simulador de conversaciones").

Construido sobre el pipeline **Understand → Decide → Act → Verify →
Escalate**, con **información de productos de crédito y elegibilidad**
(`eligibility_check`) como segundo flujo de soporte sobre la misma
infraestructura. Español/portugués. Infraestructura AWS real desplegada
vía Terraform — no un mock desechable.

**🔗 Demo en vivo: https://d1vi5rhqqyd97a.cloudfront.net** (chat real, sin
login requerido para `product_info`/`faq`; `eligibility_check`/
`dispute_unrecognized_charge` piden iniciar sesión). Infraestructura real
desplegada en AWS (CloudFront + API Gateway + Step Functions + Lambda +
DynamoDB + Bedrock), no un mock local.

**Login SIEMPRE de 2 pasos, con código de un solo uso por email**
(decisión de seguridad explícita -- ver `docs/STATUS.md`, "Login con
código por email obligatorio": documento+nombre solo ya no alcanza,
menos todavía con 2 clientes reales publicados abajo). Paso 1: documento
+ nombre + apellido. Paso 2: el código de 6 dígitos que llega por email
-- **si estás evaluando esto en vivo y no tenés acceso a ese email,
pedinos el código directamente** (contacto del equipo/hackathon), no hay
forma de auto-servicio por diseño (nunca se devuelve el código por la
API, para no debilitar el mecanismo real de OTP).

Clientes de prueba, documento + nombre + apellido para el paso 1:

| Documento | Nombre | Apellido | Real/mock |
| --- | --- | --- | --- |
| `LOTM900101MDFPRR09` | `María Fernanda` | `López Torres` | Mock (demo), Premium |

Ver los otros 3 clientes mock en `services/transaction-agent/src/data/
mock-core-banking.ts`.

**Clientes REALES del dataset del hackathon** (no inventados, ver
`services/transaction-agent/src/data/real-customers.ts` para la
procedencia exacta) -- para probar una disputa contra una transacción que
el propio dataset real ya marca como fraude (`is_fraud: true`), no una
simulada:

| Documento | Nombre | Apellido | Probá disputar |
| --- | --- | --- | --- |
| `39168655` | `Ana Angélica` | `Romero López` | "No reconozco un cargo de $173.01 en Cine Premium" |
| `55181511` | `Eduardo` | `Giménez Vega` | "No reconozco un cargo de $139278.93 en Restaurante El Buen Sabor" |

Único dato sobrescrito respecto al dataset real: el email -- igual que
los 4 clientes mock de arriba, TODOS comparten el mismo inbox real del
equipo ahora que el código es obligatorio para cualquier login (nunca se
le manda un código real a una persona real ajena al equipo, aunque el
resto de sus datos sí esté autorizado para este ejercicio -- ver
docstring de `real-customers.ts`).

> Este proyecto se construyó en 10 días como respuesta al
> "Factored AI & Data Hackathon 2026" (`hacka-info/Factored AI & Data
> Hackathon 2026.pdf`, contexto local no versionado). El pivot de
> `credit-product info & eligibility` a `transaction-dispute intake` como
> foco principal se decidió el día 1 del dataset real, con evidencia
> cuantitativa del propio EDA del equipo — ver `docs/STATUS.md`, "Fase 3".
> Ver `docs/EVALUATION-CRITERIA.md` para cómo este repo responde a cada uno
> de los 6 puntos que el PDF pide demostrar explícitamente.

## Para evaluadores: usuarios de prueba y endpoints

Al entrar a la demo se abre un panel **Info** (también se reabre desde el
botón "Info" del header) con dos pestañas: los usuarios de prueba y todos
los endpoints. Lo mismo queda documentado acá.

**Login:** siempre de 2 pasos. Elegí un usuario de la tabla, cargá documento,
nombre y apellido tal como figuran, y pedí el código de 6 dígitos al equipo
(los códigos se envían al inbox del equipo de la hackathon, no a su email
personal). El código es de un solo uso y vence.

| Nombre | Documento | Segmento | Qué probar |
| --- | --- | --- | --- |
| María Fernanda López Torres | CURP `LOTM900101MDFPRR09` | Premium (cliente estrella) | Productos y elegibilidad |
| Carlos Andrés Restrepo Gómez | CC `1020304050` | Plus | Productos y elegibilidad |
| Julieta Fernández Acosta | DNI `34567890` | Basic | Productos y elegibilidad |
| Roberto Gómez Sánchez | CURP `GORS980512HDFMNB03` | Student | Productos y elegibilidad |
| Ana Angélica Romero López | DNI `39168655` | Plus (dataset real) | Disputar "No reconozco un cargo de $173.01 en Cine Premium" |
| Eduardo Giménez Vega | DNI `55181511` | Basic (dataset real) | Disputar "No reconozco un cargo de $139278.93 en Restaurante El Buen Sabor" |

Base URL: `https://kr49s6ij26.execute-api.us-east-1.amazonaws.com`

| Método | Ruta | Para qué | Body | Acceso |
| --- | --- | --- | --- | --- |
| POST | `/chat` | Un turno del agente | `{ caseId, turnId, message, sessionToken?, selectedTransactionId? }` | Público (disputas y elegibilidad piden `sessionToken`) |
| POST | `/auth/login` | Paso 1: envía el código por email | `{ document_id, first_name, last_name, language }` | Público |
| POST | `/auth/otp/request` | Reenvía el código (igual que `/auth/login`) | `{ document_id, first_name, last_name, language }` | Público |
| POST | `/auth/otp/verify` | Paso 2: valida el código y devuelve `sessionToken` (30 min) | `{ document_id, code }` | Público |
| GET | `/admin/otp-inbox` | Lee a qué email llegan hoy los códigos OTP | — | Clave de admin (`x-admin-key`) |
| PUT | `/admin/otp-inbox` | Fija a qué email llegan los códigos OTP (efecto en ~30 s, sin redeploy) | `{ email }` | Clave de admin (`x-admin-key`) |
| GET | `/admin/conversations` | Lista de conversaciones | — | Clave de admin (`x-admin-key`) |
| GET | `/admin/conversations/{caseId}/trace` | Traza completa de un caso | — | Clave de admin |
| POST | `/admin/simulations` | Dispara una simulación | `{ profileId, objectiveId }` | Clave de admin |
| GET | `/admin/simulations` | Lista corridas de simulación | — | Clave de admin |
| GET | `/admin/simulations/{runId}` | Detalle de una corrida | — | Clave de admin |

**Para recibir los códigos en tu propio email:** pedí al equipo la clave de
admin y fijá el destino una sola vez:

```bash
curl -X PUT https://kr49s6ij26.execute-api.us-east-1.amazonaws.com/admin/otp-inbox \
  -H "content-type: application/json" -H "x-admin-key: <CLAVE>" \
  -d '{"email":"tu@email.com"}'
```

Desde ese momento, todos los códigos de login llegan a ese email. Para volver
al comportamiento normal (cada cliente recibe el suyo) no hay endpoint
público: pedinos que lo restauremos. Los demás `/admin/*` (conversaciones,
trazas, simulaciones) también requieren la clave.

## Por dónde empezar

| Si querés... | Mirá... |
|---|---|
| Entender qué se construyó y su estado actual, fase por fase | `docs/STATUS.md` |
| Entender el historial de decisiones y por qué se tomaron | `docs/PLAN.md` |
| Los contratos de datos entre piezas (`UnderstandOutput`, `EligibilityResult`, `DisputeVerificationResult`, etc.) | `docs/CONTRACTS.md` |
| Cómo este repo responde a cada punto del rubric oficial del hackathon | `docs/EVALUATION-CRITERIA.md` |
| Evaluación del guardrail de Bedrock (baseline vs. sistema, held-out real) | `docs/EVALUATION-DECIDE-STAGE.md` |
| Entrenamiento/evaluación del clasificador de fraude sobre el dataset real (resultado negativo honesto) | `ml/README.md`, `ml/REPORT.md` |
| Desplegar/inspeccionar la infraestructura AWS | `terraform/README.md` |
| Correr la chat UI | ver "Quickstart" abajo |
| El blueprint de arquitectura de referencia (no literal, adaptado) | `E2E-documentacion-tecnica/` |

## Arquitectura (resumen — ver `terraform/README.md` para el diagrama completo)

```
Chat UI (apps/web) → API Gateway → Step Function (Express)
  → conversation-agent (Understand: intent + entities, eligibility O disputa)
  → policy-agent (Decide: policies.yaml + guardrail de Bedrock, pre_action)
  → retrieval-agent (Act, product_info/faq) / transaction-agent (Act,
    eligibility_check O dispute_unrecognized_charge -- mismo Lambda,
    discriminado por intent) → verification-agent (Verify)
  → policy-agent (Decide, post_action -- solo eligibility/disputa)
  → escalation-agent (Escalate, cuando corresponde)
```

Un solo pipeline compartido por ambos flujos (decisión de arquitectura
deliberada, ver `docs/STATUS.md` "Fase 3" — extender el pipeline existente
en vez de duplicar infraestructura por challenge). Cada agente es un Lambda
real desplegado en AWS (no simulado), invocado por una Step Function real,
con IAM de mínimo privilegio e invocación restringida entre pasos. Los
datos bancarios/de crédito para el DEMO en vivo son simulados (mock chico
que respeta el schema real); el pipeline de evaluación de `ml/` sí entrena
contra el dataset real completo del hackathon (offline, no en el demo).

## Estructura del monorepo (npm workspaces + un pipeline Python aparte)

```
packages/shared/       Contratos TypeScript compartidos (fuente de verdad de tipos)
services/
  conversation-agent/  Understand: router de intención, idioma ES/PT, contexto
  policy-agent/        Decide: policies.yaml + guardrail de Bedrock (pre_action y post_action)
  retrieval-agent/      Act: catálogo de productos + FAQs
  transaction-agent/    Act: elegibilidad O disputa (computeEligibility/computeDisputeVerification)
  verification-agent/  Verify: segunda verificación independiente
  escalation-agent/    Escalate: resumen estructurado, nunca PII cruda
apps/web/              Chat UI real (React + Vite + TypeScript)
terraform/              Infraestructura AWS (Terraform)
policies.yaml           Reglas de negocio AUTO/CLARIFY/ESCALATE (auditables), ambos flujos
ml/                     Pipeline offline (Python) de evaluación del "learned component" —
                        entrenamiento/evaluación del clasificador de fraude sobre el dataset real
docs/                    STATUS.md, PLAN.md, CONTRACTS.md, EVALUATION-CRITERIA.md, EVALUATION-DECIDE-STAGE.md
```

## Quickstart

```bash
# 1. Instalar dependencias y correr toda la suite de tests
npm install
npm run build
npm test          # 333 tests en verde, ver docs/STATUS.md para el detalle

# 2. Desplegar/verificar infraestructura AWS (requiere credenciales propias,
#    ver terraform/README.md "Credenciales AWS")
cd terraform/envs/dev
terraform init
terraform plan
terraform apply

# 3. Levantar el frontend, ya apuntando al endpoint desplegado
cd ../../..
npm run dev --workspace=@banking-agent/web
# abrir http://localhost:5173
```

No hace falta correr Terraform para ejecutar los tests — todos los servicios
tienen tests unitarios/integración que no dependen de AWS real (usan clientes
mockeados). Terraform solo hace falta para probar el pipeline end-to-end
contra infraestructura real. `ml/` es un pipeline Python separado (venv
propio, ver `ml/README.md`) — no forma parte de `npm test`.

## Estado del proyecto

Pipeline completo funcionando de punta a punta sobre AWS real para AMBOS
flujos (eligibility y disputa), verificado con casos reales en español y
portugués, incluyendo evaluación formal del "learned component" (guardrail
de Bedrock evaluado contra baseline con held-out set real, y un
clasificador de fraude entrenado sobre el dataset completo del hackathon —
ver `docs/STATUS.md`, "Fase ML", para la evidencia completa de cada pieza).
Limitaciones conocidas, honestas y no ocultadas: `docs/EVALUATION-CRITERIA.md`
y la sección de cierre de `docs/STATUS.md`.
