import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";

const rootElement = document.getElementById("root")!;

function render() {
  const app = (
    <StrictMode>
      <App />
    </StrictMode>
  );

  if (import.meta.hot) {
    // Reuse the root across hot reloads
    const reactRoot = (import.meta.hot.data.root ??= createRoot(rootElement));
    reactRoot.render(app);
  } else {
    createRoot(rootElement).render(app);
  }
}

render();

if (import.meta.hot) {
  // Accept updates from this module and all dependencies
  import.meta.hot.accept(() => {
    render();
  });
}
