import React from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import App from "./App";
import { AuthProvider } from "./auth";
import { SimProvider } from "./sim";
import { ToastProvider } from "./components/ui";
import "./styles.css";

createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <BrowserRouter>
      <AuthProvider>
        <SimProvider>
          <ToastProvider>
            <App />
          </ToastProvider>
        </SimProvider>
      </AuthProvider>
    </BrowserRouter>
  </React.StrictMode>
);
