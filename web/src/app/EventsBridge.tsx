import { useQueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import { apiGet, SignInRequired } from "../api/client";
import { subscribe, type ProbeResult } from "../api/events";
import type { SystemStatus } from "../api/types";
import { keys } from "../features/sessions/api";
import { applyEvent } from "./eventsToCache";

/**
 * Keeps the query cache in step with the app's events stream. The check after a
 * drop goes through the query cache, so a 401 reaches the sign-in gate in
 * `AppProviders` (which replaces the UI with SignInAgain and so closes the stream).
 */
export function EventsBridge() {
  const client = useQueryClient();
  useEffect(() => {
    let hellos = 0;
    const probe = async (): Promise<ProbeResult> => {
      try {
        await client.fetchQuery({
          queryKey: keys.system,
          queryFn: () => apiGet<SystemStatus>("/api/system"),
          staleTime: 0,
          retry: false,
        });
        return "ok";
      } catch (error) {
        return error instanceof SignInRequired ? "signedOut" : "ok";
      }
    };
    return subscribe(
      (event) => {
        const resync = event.type === "hello" && hellos++ > 0;
        applyEvent(client, event, resync);
      },
      { probe },
    );
  }, [client]);
  return null;
}
