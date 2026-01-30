import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";

const root = document.getElementById("root")!;
const app = (
  <StrictMode>
    <App />
  </StrictMode>
);

if (import.meta.hot) {
  import.meta.hot.accept();
  const reactRoot = (import.meta.hot.data.root ??= createRoot(root));
  reactRoot.render(app);
} else {
  createRoot(root).render(app);
}
