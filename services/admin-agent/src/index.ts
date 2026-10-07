import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from "aws-lambda";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient } from "@aws-sdk/lib-dynamodb";
import { CloudWatchLogsClient } from "@aws-sdk/client-cloudwatch-logs";
import { InvokeCommand, LambdaClient } from "@aws-sdk/client-lambda";
import { randomUUID } from "node:crypto";
import { getAdminConfig } from "./config";
import { listConversations } from "./list-conversations";
import { getConversationTrace } from "./get-trace";
import { findSimulationProfile } from "./simulation/profiles";
import { findSimulationObjective } from "./simulation/objectives";
import { getSimulationRun, listSimulationRuns, putSimulationRun, type SimulationRunItem } from "./simulation/store";
import { runSimulation } from "./simulation/run-simulation";
import { getSimulationBedrockConfig } from "./simulation/bedrock-config";
import { SSMClient } from "@aws-sdk/client-ssm";
import { getOtpInbox, isValidOtpInboxEmail, setOtpInbox } from "./otp-inbox";

/**
 * Handler de Lambda para las rutas del dashboard de admin, despachadas por
 * `rawPath` (mismo patrón que `services/auth-agent/src/index.ts` -- un solo
 * Lambda para rutas chicas y relacionadas, nunca uno por ruta):
 *   - `GET /admin/conversations`: lista de casos reales (Scan sobre
 *     `banking-agent-dev-case-store`).
 *   - `GET /admin/conversations/{caseId}/trace`: traza completa de un caso
 *     (leída de los logs de CloudWatch del Step Function -- ver
 *     `get-trace.ts`).
 *   - `POST /admin/simulations`: dispara una simulación de conversación
 *     nueva (perfil + objetivo del catálogo fijo, ver `simulation/
 *     profiles.ts`/`objectives.ts`) -- crea el item `pending` y se
 *     AUTOINVOCA async (`lambda:InvokeFunction`, `InvocationType: Event`)
 *     para correr el worker (`simulation/run-simulation.ts`) fuera del
 *     límite sincrónico de 29s de API Gateway, respondiendo de inmediato
 *     con el `runId`.
 *   - `GET /admin/simulations`: lista de corridas (Query sobre el GSI
 *     `by-customer` con `gsi1pk = "SIMULATIONS"`, ver `simulation/
 *     store.ts`).
 *   - `GET /admin/simulations/{runId}`: detalle de una corrida.
 *
 * La MISMA invocación Lambda también atiende el worker asíncrono de arriba
 * -- se distingue de una invocación real de API Gateway por la presencia
 * de un campo `action` en el evento (nunca presente en un
 * `APIGatewayProxyEventV2`), chequeado ANTES que cualquier dispatch por
 * `rawPath`.
 *
 * Auth: header `x-admin-key` contra un SSM SecureString (`getAdminConfig`)
 * -- superficie SEPARADA del `sessionToken` de clientes bancarios (no hay
 * ni debe haber un rol "admin" en `UserRole`). Sin key o key incorrecta ->
 * 401, siempre con body (nunca un 5xx sin body, mismo criterio de
 * Reliability que el resto del pipeline). La invocación async interna NO
 * pasa por esta validación -- nunca llega por API Gateway, la dispara
 * directamente la propia ruta POST ya autenticada.
 */

interface SimulationWorkerEvent {
  action: "run_simulation";
  runId: string;
}

function isSimulationWorkerEvent(event: unknown): event is SimulationWorkerEvent {
  return (
    typeof event === "object" &&
    event !== null &&
    (event as Record<string, unknown>).action === "run_simulation" &&
    typeof (event as Record<string, unknown>).runId === "string"
  );
}

let docClient: DynamoDBDocumentClient | undefined;
function getDocClient(): DynamoDBDocumentClient {
  if (!docClient) {
    docClient = DynamoDBDocumentClient.from(new DynamoDBClient({}));
  }
  return docClient;
}

let logsClient: CloudWatchLogsClient | undefined;
function getLogsClient(): CloudWatchLogsClient {
  if (!logsClient) {
    logsClient = new CloudWatchLogsClient({});
  }
  return logsClient;
}

let lambdaClient: LambdaClient | undefined;
function getLambdaClient(): LambdaClient {
  if (!lambdaClient) {
    lambdaClient = new LambdaClient({});
  }
  return lambdaClient;
}

function jsonResponse(statusCode: number, body: unknown): APIGatewayProxyResultV2 {
  return { statusCode, headers: { "content-type": "application/json" }, body: JSON.stringify(body) };
}

let ssmClient: SSMClient | undefined;

function getSsmClient(): SSMClient {
  if (!ssmClient) {
    ssmClient = new SSMClient({});
  }
  return ssmClient;
}

function parseEmailFromBody(event: APIGatewayProxyEventV2): unknown {
  if (!event.body) return undefined;
  try {
    const raw = event.isBase64Encoded ? Buffer.from(event.body, "base64").toString("utf-8") : event.body;
    return (JSON.parse(raw) as { email?: unknown }).email;
  } catch {
    return undefined;
  }
}

async function isAuthorized(event: APIGatewayProxyEventV2): Promise<boolean> {
  const providedKey = event.headers?.["x-admin-key"] ?? event.headers?.["X-Admin-Key"];
  if (!providedKey) return false;
  const { adminApiKey } = await getAdminConfig();
  return providedKey === adminApiKey;
}

async function handleRunSimulationWorker(runId: string): Promise<void> {
  const tableName = process.env.CASE_STORE_TABLE_NAME;
  const chatApiUrl = process.env.CHAT_API_URL;
  const authLoginUrl = process.env.AUTH_LOGIN_URL;
  if (!tableName || !chatApiUrl || !authLoginUrl) {
    // eslint-disable-next-line no-console
    console.error("admin-agent run_simulation worker: config_missing", { runId });
    return;
  }

  const bedrockConfig = await getSimulationBedrockConfig();
  if (!bedrockConfig) {
    // eslint-disable-next-line no-console
    console.error("admin-agent run_simulation worker: bedrock no disponible", { runId });
    return;
  }

  await runSimulation(runId, {
    docClient: getDocClient(),
    caseStoreTableName: tableName,
    bedrockClient: bedrockConfig.bedrockClient,
    bedrockModelId: bedrockConfig.modelId,
    chatApiUrl,
    authLoginUrl,
  });
}

export async function handler(
  event: APIGatewayProxyEventV2 | SimulationWorkerEvent
): Promise<APIGatewayProxyResultV2 | undefined> {
  if (isSimulationWorkerEvent(event)) {
    await handleRunSimulationWorker(event.runId);
    return undefined;
  }

  const path = event.rawPath ?? "";
  const method = event.requestContext?.http?.method ?? "GET";

  try {
    if (!(await isAuthorized(event))) {
      return jsonResponse(401, { ok: false, reason: "unauthorized" });
    }

    if (path === "/admin/conversations") {
      const tableName = process.env.CASE_STORE_TABLE_NAME;
      if (!tableName) return jsonResponse(500, { ok: false, reason: "config_missing" });

      const result = await listConversations(getDocClient(), tableName);
      if (!result.ok) return jsonResponse(503, { ok: false, reason: "dynamodb_unavailable" });
      return jsonResponse(200, { ok: true, conversations: result.value });
    }

    const traceMatch = path.match(/^\/admin\/conversations\/([^/]+)\/trace$/);
    if (traceMatch) {
      const caseId = decodeURIComponent(traceMatch[1]);
      const logGroupName = process.env.STATE_MACHINE_LOG_GROUP_NAME;
      if (!logGroupName) return jsonResponse(500, { ok: false, reason: "config_missing" });

      const result = await getConversationTrace(getLogsClient(), logGroupName, caseId);
      if (!result.ok) return jsonResponse(503, { ok: false, reason: "logs_unavailable_or_invalid_case_id" });
      return jsonResponse(200, { ok: true, turns: result.value });
    }

    if (path === "/admin/otp-inbox" && method === "GET") {
      const paramName = process.env.OTP_INBOX_PARAM_NAME;
      if (!paramName) return jsonResponse(500, { ok: false, reason: "config_missing" });

      const inbox = await getOtpInbox({ paramName, ssmClient: getSsmClient() });
      return jsonResponse(200, { ok: true, inbox });
    }

    if (path === "/admin/otp-inbox" && method === "PUT") {
      const paramName = process.env.OTP_INBOX_PARAM_NAME;
      if (!paramName) return jsonResponse(500, { ok: false, reason: "config_missing" });

      const email = parseEmailFromBody(event);
      if (!isValidOtpInboxEmail(email)) return jsonResponse(400, { ok: false, reason: "invalid_email" });

      await setOtpInbox(email, { paramName, ssmClient: getSsmClient() });
      return jsonResponse(200, { ok: true, inbox: email });
    }

    if (path === "/admin/simulations" && method === "POST") {
      const tableName = process.env.CASE_STORE_TABLE_NAME;
      const functionName = process.env.ADMIN_AGENT_FUNCTION_NAME;
      if (!tableName || !functionName) return jsonResponse(500, { ok: false, reason: "config_missing" });

      let body: { profileId?: unknown; objectiveId?: unknown };
      try {
        body = JSON.parse(event.body ?? "{}");
      } catch {
        return jsonResponse(400, { ok: false, reason: "invalid_json" });
      }

      const profileId = typeof body.profileId === "string" ? body.profileId : "";
      const objectiveId = typeof body.objectiveId === "string" ? body.objectiveId : "";
      const profile = findSimulationProfile(profileId);
      const objective = findSimulationObjective(objectiveId);
      if (!profile || !objective) {
        return jsonResponse(400, { ok: false, reason: "unknown_profile_or_objective" });
      }

      const runId = randomUUID();
      const now = new Date().toISOString();
      const run: SimulationRunItem = {
        runId,
        profileId,
        objectiveId,
        status: "pending",
        turns: [],
        expectedStatus: objective.expectedStatus,
        createdAt: now,
        updatedAt: now,
      };

      const putResult = await putSimulationRun(getDocClient(), tableName, run);
      if (!putResult.ok) return jsonResponse(503, { ok: false, reason: "dynamodb_unavailable" });

      await getLambdaClient().send(
        new InvokeCommand({
          FunctionName: functionName,
          InvocationType: "Event",
          Payload: Buffer.from(JSON.stringify({ action: "run_simulation", runId } satisfies SimulationWorkerEvent)),
        })
      );

      return jsonResponse(200, { ok: true, runId });
    }

    if (path === "/admin/simulations" && method === "GET") {
      const tableName = process.env.CASE_STORE_TABLE_NAME;
      if (!tableName) return jsonResponse(500, { ok: false, reason: "config_missing" });

      const result = await listSimulationRuns(getDocClient(), tableName);
      if (!result.ok) return jsonResponse(503, { ok: false, reason: "dynamodb_unavailable" });
      return jsonResponse(200, { ok: true, runs: result.value });
    }

    const simulationDetailMatch = path.match(/^\/admin\/simulations\/([^/]+)$/);
    if (simulationDetailMatch && method === "GET") {
      const tableName = process.env.CASE_STORE_TABLE_NAME;
      if (!tableName) return jsonResponse(500, { ok: false, reason: "config_missing" });

      const runId = decodeURIComponent(simulationDetailMatch[1]);
      const result = await getSimulationRun(getDocClient(), tableName, runId);
      if (!result.ok) return jsonResponse(503, { ok: false, reason: "dynamodb_unavailable" });
      if (!result.value) return jsonResponse(404, { ok: false, reason: "not_found" });
      return jsonResponse(200, { ok: true, run: result.value });
    }

    return jsonResponse(404, { ok: false, reason: "not_found" });
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error("admin-agent handler error", { path, error });
    return jsonResponse(500, { ok: false, reason: "internal_error" });
  }
}
