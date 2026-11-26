import { useEffect, useState } from "react";
import { SignInRequired, apiGet } from "./api/client";
import { SignInAgain } from "./components/SignInAgain";

export function App() {
  const [signedOut, setSignedOut] = useState(false);

  useEffect(() => {
    apiGet("/api/health").catch((error: unknown) => {
      if (error instanceof SignInRequired) setSignedOut(true);
    });
  }, []);

  if (signedOut) return <SignInAgain />;

  return (
    <>
      <header
        style={{ padding: "12px 20px", borderBottom: "1px solid var(--line)" }}
      >
        <span
          style={{
            fontFamily: "var(--display)",
            fontWeight: 800,
            fontSize: 22,
            letterSpacing: "0.02em",
            textTransform: "uppercase",
          }}
        >
          CallCapture
        </span>
      </header>
      <main />
    </>
  );
}
