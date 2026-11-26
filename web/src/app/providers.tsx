import { MutationCache, QueryCache, QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";
import { ApiError, SignInRequired } from "../api/client";
import { SignInAgain } from "../components/SignInAgain";

/** Retry only what can recover: never a sign-in problem or a 4xx answer. */
function shouldRetry(failureCount: number, error: unknown): boolean {
  if (error instanceof SignInRequired) return false;
  if (error instanceof ApiError && error.status < 500) return false;
  return failureCount < 2;
}

export function makeQueryClient(onSignedOut: () => void, retry: boolean): QueryClient {
  const onError = (error: unknown) => {
    if (error instanceof SignInRequired) onSignedOut();
  };
  return new QueryClient({
    queryCache: new QueryCache({ onError }),
    mutationCache: new MutationCache({ onError }),
    defaultOptions: {
      queries: { retry: retry ? shouldRetry : false, staleTime: 5_000 },
      mutations: { retry: false },
    },
  });
}

interface AppProvidersProps {
  children: ReactNode;
  /** Tests turn retries off so failures surface at once. */
  retry?: boolean;
}

/**
 * Server-data cache plus the sign-in gate: a 401 from any query or action
 * replaces the whole UI with SignInAgain.
 */
export function AppProviders({ children, retry = true }: AppProvidersProps) {
  const [signedOut, setSignedOut] = useState(false);
  const [client] = useState(() => makeQueryClient(() => setSignedOut(true), retry));
  if (signedOut) return <SignInAgain />;
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}
