export const API_BASE_URL = "https://kr49s6ij26.execute-api.us-east-1.amazonaws.com";

export const OTP_DELIVERY_NOTE =
  "Los códigos de login se envían al inbox del equipo de la hackathon. Pedí tu código al equipo y te lo pasamos.";

export interface TestUser {
  name: string;
  documentType: string;
  documentNumber: string;
  segment: string;
  origin: "Demo" | "Dataset real";
  tryIt: string;
}

export const TEST_USERS: readonly TestUser[] = [
  {
    name: "María Fernanda López Torres",
    documentType: "CURP",
    documentNumber: "LOTM900101MDFPRR09",
    segment: "Premium (cliente estrella)",
    origin: "Demo",
    tryIt: "Consultar productos y elegibilidad",
  },
  {
    name: "Carlos Andrés Restrepo Gómez",
    documentType: "CC",
    documentNumber: "1020304050",
    segment: "Plus",
    origin: "Demo",
    tryIt: "Consultar productos y elegibilidad",
  },
  {
    name: "Julieta Fernández Acosta",
    documentType: "DNI",
    documentNumber: "34567890",
    segment: "Basic",
    origin: "Demo",
    tryIt: "Consultar productos y elegibilidad",
  },
  {
    name: "Roberto Gómez Sánchez",
    documentType: "CURP",
    documentNumber: "GORS980512HDFMNB03",
    segment: "Student",
    origin: "Demo",
    tryIt: "Consultar productos y elegibilidad",
  },
  {
    name: "Ana Angélica Romero López",
    documentType: "DNI",
    documentNumber: "39168655",
    segment: "Plus",
    origin: "Dataset real",
    tryIt: "Disputar: \"No reconozco un cargo de $173.01 en Cine Premium\"",
  },
  {
    name: "Eduardo Giménez Vega",
    documentType: "DNI",
    documentNumber: "55181511",
    segment: "Basic",
    origin: "Dataset real",
    tryIt: "Disputar: \"No reconozco un cargo de $139278.93 en Restaurante El Buen Sabor\"",
  },
];

export type HttpMethod = "GET" | "POST" | "PUT";

export interface ApiEndpoint {
  method: HttpMethod;
  path: string;
  description: string;
  body?: string;
  auth: string;
}

export const PUBLIC_ENDPOINTS: readonly ApiEndpoint[] = [
  {
    method: "POST",
    path: "/chat",
    description: "Un turno del agente: entiende la consulta, decide y responde.",
    body: "{ caseId, turnId, message, sessionToken?, selectedTransactionId? }",
    auth: "Público (las disputas y elegibilidad piden sessionToken)",
  },
  {
    method: "POST",
    path: "/auth/login",
    description: "Paso 1 del login: valida documento, nombre y apellido y envía el código por email.",
    body: "{ document_id, first_name, last_name, language }",
    auth: "Público",
  },
  {
    method: "POST",
    path: "/auth/otp/request",
    description: "Igual que /auth/login: reenvía el código de un solo uso.",
    body: "{ document_id, first_name, last_name, language }",
    auth: "Público",
  },
  {
    method: "POST",
    path: "/auth/otp/verify",
    description: "Paso 2 del login: valida el código y devuelve el sessionToken (expira en 30 min).",
    body: "{ document_id, code }",
    auth: "Público",
  },
];

export const ADMIN_ENDPOINTS: readonly ApiEndpoint[] = [
  {
    method: "GET",
    path: "/admin/otp-inbox",
    description: "Lee a qué email llegan hoy los códigos OTP (null = cada cliente recibe el suyo).",
    auth: "Clave de admin (x-admin-key)",
  },
  {
    method: "PUT",
    path: "/admin/otp-inbox",
    description: "Fija a qué email llegan los códigos OTP. Efecto en ~30 segundos, sin redeploy.",
    body: "{ email }",
    auth: "Clave de admin (x-admin-key)",
  },
  {
    method: "GET",
    path: "/admin/conversations",
    description: "Lista las conversaciones registradas.",
    auth: "Clave de admin (x-admin-key)",
  },
  {
    method: "GET",
    path: "/admin/conversations/{caseId}/trace",
    description: "Traza completa de un caso, paso a paso.",
    auth: "Clave de admin (x-admin-key)",
  },
  {
    method: "POST",
    path: "/admin/simulations",
    description: "Dispara una simulación de conversación (perfil + objetivo).",
    body: "{ profileId, objectiveId }",
    auth: "Clave de admin (x-admin-key)",
  },
  {
    method: "GET",
    path: "/admin/simulations",
    description: "Lista las corridas de simulación.",
    auth: "Clave de admin (x-admin-key)",
  },
  {
    method: "GET",
    path: "/admin/simulations/{runId}",
    description: "Detalle de una corrida de simulación.",
    auth: "Clave de admin (x-admin-key)",
  },
];
