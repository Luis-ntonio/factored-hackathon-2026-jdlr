import { useState } from "react";
import { AuthProvider } from "./auth/AuthContext";
import { ChatLaunchProvider } from "./chat/ChatLaunchContext";
import { AuthPanel } from "./components/AuthPanel";
import { InfoModal } from "./components/InfoModal";
import { LoginModal } from "./components/LoginModal";
import { ChatWidget } from "./components/ChatWidget";
import { ProductShowcase } from "./components/ProductShowcase";

/** Shell de nivel superior: login de PLATAFORMA (header, siempre visible,
 * independiente del chat) + vidriera de productos + widget de chat
 * minimizado. Ver `ChatWidget.tsx`/`ChatPanel.tsx` para el chat en sí,
 * `auth/AuthContext.tsx` para la sesión de identidad, `chat/
 * ChatLaunchContext.tsx` para cómo un botón "Lo quiero" de
 * `ProductShowcase.tsx` (hermano de `ChatWidget` en este árbol) abre el
 * chat con un mensaje ya definido.
 *
 * El idioma de este nivel (modal de login, vidriera) queda "es" fijo (no
 * hay conversación todavía acá para saber el idioma real) -- mismo default
 * que el resto del sistema antes del primer turno. */
function AppShell() {
  const [infoOpen, setInfoOpen] = useState(true);

  return (
    <div className="app-shell">
      {/* <header> real (landmark "banner") -- antes era un <div>, gap
          encontrado en /impeccable audit. ProductShowcase.tsx también
          tiene su propio <header> (el hero) -- por eso va DENTRO de
          <main> acá abajo: un <header> anidado en <main> ya no toma el
          rol "banner" por defecto, así que los dos <header> conviven sin
          landmarks duplicados. */}
      <header className="app-shell-topbar">
        <button type="button" className="app-shell-info-button" onClick={() => setInfoOpen(true)}>
          Info
        </button>
        <AuthPanel language="es" />
      </header>
      <main>
        <ProductShowcase />
      </main>
      {infoOpen && <InfoModal onClose={() => setInfoOpen(false)} />}
      <LoginModal language="es" />
      <ChatWidget />
    </div>
  );
}

export default function App() {
  return (
    <AuthProvider>
      <ChatLaunchProvider>
        <AppShell />
      </ChatLaunchProvider>
    </AuthProvider>
  );
}
