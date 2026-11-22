"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import {
  ArrowRight,
  ShieldCheck,
  Boxes,
  Warehouse,
  CheckCircle2,
  UserPlus,
  LogIn,
} from "lucide-react";

export default function Login() {
  const router = useRouter();
  const [mode, setMode] = useState("signin"); // "signin" | "signup"
  const [fullName, setFullName] = useState("");
  const [email, setEmail] = useState("asha@smartvault.example");
  const [password, setPassword] = useState("");
  const [role, setRole] = useState("ADMIN");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");

  async function submit(e) {
    e.preventDefault();
    setPending(true);
    setError("");
    try {
      if (mode === "signin") {
        const r = await fetch("/api/auth/login", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ email, password }),
        });
        const d = await r.json();
        if (!r.ok) throw Error(d.error || "Login failed");
        router.push("/dashboard");
        router.refresh();
      } else {
        const r = await fetch("/api/auth/register", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ full_name: fullName, email, password, role }),
        });
        const d = await r.json();
        if (!r.ok) throw Error(d.error || "Registration failed");
        router.push("/dashboard");
        router.refresh();
      }
    } catch (e) {
      setError(e.message);
    } finally {
      setPending(false);
    }
  }

  function switchMode(newMode) {
    setMode(newMode);
    setError("");
    if (newMode === "signup") {
      setEmail("");
      setPassword("");
    } else {
      setEmail("asha@smartvault.example");
      setPassword("");
    }
  }

  return (
    <main className="login-shell">
      <section className="login-story">
        <a className="brand" href="/">
          <span className="brand-mark">
            <Boxes size={25} />
          </span>
          SmartVault<span className="brand-dot">.</span>
        </a>
        <div className="story-body">
          <span className="eyebrow">INVENTORY INTELLIGENCE</span>
          <h1>
            Every unit.
            <br />
            Accounted for.
          </h1>
          <p>
            A clearer view of your warehouses.
            <br />A smarter way to keep stock moving.
          </p>
          <div className="warehouse-illustration">
            <div className="illustration-line" />
            {["Central", "North", "West"].map((n, i) => (
              <div className={"illustration-node node-" + i} key={n}>
                <Warehouse size={28} />
                <strong>{n}</strong>
                <span>
                  <i /> Connected
                </span>
              </div>
            ))}
            <div className="illustration-hub">
              <Boxes size={31} />
            </div>
          </div>
          <div className="story-foot">
            <ShieldCheck size={18} />
            <span>Connected stock. Controlled access. Clear decisions.</span>
          </div>
        </div>
        <small>SMARTVAULT / DBMS PROJECT</small>
      </section>
      <section className="login-form-panel">
        <div className="login-form-wrap">
          <div style={{ display: "flex", gap: "8px", marginBottom: "16px" }}>
            <button
              type="button"
              onClick={() => switchMode("signin")}
              style={{
                flex: 1,
                padding: "8px 12px",
                borderRadius: "20px",
                border:
                  "1px solid " + (mode === "signin" ? "#3e5437" : "#e5eddc"),
                background: mode === "signin" ? "#3e5437" : "#f0f5ec",
                color: mode === "signin" ? "#fff" : "#8a9f78",
                fontWeight: 600,
                fontSize: "12px",
                cursor: "pointer",
                display: "inline-flex",
                alignItems: "center",
                justifyContent: "center",
                gap: "6px",
              }}
            >
              <LogIn size={14} /> Sign in
            </button>
            <button
              type="button"
              onClick={() => switchMode("signup")}
              style={{
                flex: 1,
                padding: "8px 12px",
                borderRadius: "20px",
                border:
                  "1px solid " + (mode === "signup" ? "#3e5437" : "#e5eddc"),
                background: mode === "signup" ? "#3e5437" : "#f0f5ec",
                color: mode === "signup" ? "#fff" : "#8a9f78",
                fontWeight: 600,
                fontSize: "12px",
                cursor: "pointer",
                display: "inline-flex",
                alignItems: "center",
                justifyContent: "center",
                gap: "6px",
              }}
            >
              <UserPlus size={14} /> Create account
            </button>
          </div>

          <h2>{mode === "signin" ? "Welcome back" : "Create account"}</h2>
          <p className="muted">
            {mode === "signin"
              ? "Sign in to see what’s in stock, and what’s next."
              : "Register your user details to access SmartVault."}
          </p>

          <form onSubmit={submit}>
            {mode === "signup" && (
              <label>
                Full name
                <input
                  type="text"
                  name="fullName"
                  required
                  value={fullName}
                  onChange={(e) => setFullName(e.target.value)}
                  placeholder="e.g. Haris"
                />
              </label>
            )}

            <label>
              Email address
              <input
                type="email"
                name="email"
                autoComplete="username"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder={mode === "signup" ? "name@example.com" : ""}
              />
            </label>

            {mode === "signup" && (
              <label>
                Workspace role
                <select
                  value={role}
                  onChange={(e) => setRole(e.target.value)}
                  style={{
                    padding: "11px",
                    borderRadius: "6px",
                    border: "1px solid #d4ded3",
                    background: "#fff",
                    color: "#263b35",
                    fontSize: "12px",
                  }}
                >
                  <option value="ADMIN">
                    Admin (Full inventory &amp; order control)
                  </option>
                  <option value="STAFF">
                    Staff (Movements &amp; read-only analytics)
                  </option>
                </select>
              </label>
            )}

            <label>
              Password
              <input
                type="password"
                name="password"
                autoComplete={
                  mode === "signin" ? "current-password" : "new-password"
                }
                required
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder={
                  mode === "signup"
                    ? "Min. 8 characters"
                    : "Enter your password"
                }
              />
            </label>

            {error && (
              <p className="form-error" role="alert">
                {error}
              </p>
            )}

            <button className="button primary wide" disabled={pending}>
              {pending
                ? mode === "signin"
                  ? "Signing in…"
                  : "Creating account…"
                : mode === "signin"
                  ? "Sign in"
                  : "Create account"}
              <ArrowRight size={17} />
            </button>
          </form>

          {mode === "signin" ? (
            <div className="login-roles">
              <span>Demo account</span>
              <button
                type="button"
                onClick={() => {
                  setEmail("asha@smartvault.example");
                  setPassword("VaultAdmin!2026");
                }}
              >
                Admin
              </button>
              <button
                type="button"
                onClick={() => {
                  setEmail("ravi@smartvault.example");
                  setPassword("VaultStaff!2026");
                }}
              >
                Staff
              </button>
            </div>
          ) : (
            <p className="login-help" style={{ textAlign: "center" }}>
              Already have an account?{" "}
              <a
                href="#signin"
                onClick={(e) => {
                  e.preventDefault();
                  switchMode("signin");
                }}
                style={{
                  color: "#175a48",
                  fontWeight: 600,
                  textDecoration: "underline",
                }}
              >
                Sign in
              </a>
            </p>
          )}

          {mode === "signin" && (
            <p className="login-help">
              Don't have an account?{" "}
              <a
                href="#signup"
                onClick={(e) => {
                  e.preventDefault();
                  switchMode("signup");
                }}
                style={{
                  color: "#175a48",
                  fontWeight: 600,
                  textDecoration: "underline",
                }}
              >
                Create one now
              </a>
            </p>
          )}
        </div>
        <small className="login-bottom">
          Multi-warehouse inventory &amp; anomaly detection
        </small>
      </section>
    </main>
  );
}
