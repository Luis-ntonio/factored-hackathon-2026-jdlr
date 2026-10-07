import { useState } from "react";
import "./InfoModal.css";
import {
  ADMIN_ENDPOINTS,
  API_BASE_URL,
  OTP_DELIVERY_NOTE,
  PUBLIC_ENDPOINTS,
  TEST_USERS,
  type ApiEndpoint,
} from "../data/hackathon-info";

type Tab = "users" | "endpoints";

/** Panel de información para quien evalúa el producto. Se abre solo al
 * entrar (ver `App.tsx`) y se puede reabrir desde el header. */
export function InfoModal({ onClose }: { onClose: () => void }) {
  const [tab, setTab] = useState<Tab>("users");

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div
        className="modal-card info-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="info-modal-title"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 id="info-modal-title">Información para evaluación</h2>
        <p className="modal-subtitle">{OTP_DELIVERY_NOTE}</p>

        <div className="info-tabs" role="tablist">
          <button
            type="button"
            role="tab"
            aria-selected={tab === "users"}
            className={`info-tab ${tab === "users" ? "info-tab-active" : ""}`}
            onClick={() => setTab("users")}
          >
            Usuarios de prueba
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={tab === "endpoints"}
            className={`info-tab ${tab === "endpoints" ? "info-tab-active" : ""}`}
            onClick={() => setTab("endpoints")}
          >
            Endpoints
          </button>
        </div>

        {tab === "users" && (
          <div className="info-panel">
            <p className="info-hint">
              Para entrar: elegí un usuario, cargá documento, nombre y apellido exactamente como figuran aquí, y
              después el código de 6 dígitos que pedís al equipo.
            </p>
            <div className="info-table-wrap">
              <table className="info-table">
                <thead>
                  <tr>
                    <th>Nombre</th>
                    <th>Documento</th>
                    <th>Segmento</th>
                    <th>Origen</th>
                    <th>Qué probar</th>
                  </tr>
                </thead>
                <tbody>
                  {TEST_USERS.map((user) => (
                    <tr key={user.documentNumber}>
                      <td>{user.name}</td>
                      <td>
                        <span className="info-doc-type">{user.documentType}</span> <code>{user.documentNumber}</code>
                      </td>
                      <td>{user.segment}</td>
                      <td>{user.origin}</td>
                      <td>{user.tryIt}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}

        {tab === "endpoints" && (
          <div className="info-panel">
            <p className="info-hint">
              Base URL: <code>{API_BASE_URL}</code>. Todos los endpoints aceptan y devuelven JSON.
            </p>
            <EndpointGroup title="Públicos" endpoints={PUBLIC_ENDPOINTS} />
            <EndpointGroup title="Admin" endpoints={ADMIN_ENDPOINTS} />
          </div>
        )}

        <div className="modal-actions">
          <button type="button" onClick={onClose}>
            Entendido
          </button>
        </div>
      </div>
    </div>
  );
}

function EndpointGroup({ title, endpoints }: { title: string; endpoints: readonly ApiEndpoint[] }) {
  return (
    <section className="info-endpoint-group">
      <h3>{title}</h3>
      <ul className="info-endpoint-list">
        {endpoints.map((endpoint) => (
          <li key={`${endpoint.method} ${endpoint.path}`} className="info-endpoint">
            <div className="info-endpoint-head">
              <span className={`info-method info-method-${endpoint.method.toLowerCase()}`}>{endpoint.method}</span>
              <code>{endpoint.path}</code>
            </div>
            <p>{endpoint.description}</p>
            {endpoint.body && (
              <p className="info-endpoint-meta">
                Body: <code>{endpoint.body}</code>
              </p>
            )}
            <p className="info-endpoint-meta">Acceso: {endpoint.auth}</p>
          </li>
        ))}
      </ul>
    </section>
  );
}
