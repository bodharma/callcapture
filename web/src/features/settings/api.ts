import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiGet, apiSend } from "../../api/client";
import { useSystem } from "../sessions/api";
import type { CatalogDTO, KeyTestResult, SecretKey, SettingsDTO, SettingsPatch } from "./types";

const PROGRESS_POLL_MS = 2_000;

export const settingsKeys = {
  settings: ["settings"] as const,
  catalog: ["catalog"] as const,
};

/** Recording, network and version from the app; `connectivity` events keep `online` current. */
export const useSystemStatus = useSystem;

/**
 * Whether the app reports a network; undefined until it has said. Controls are turned
 * off only on a definite `false`: the app refuses network work itself when offline.
 */
export function useOnline(): boolean | undefined {
  return useSystemStatus().data?.online;
}

const isDownloading = (settings: SettingsDTO | undefined): boolean =>
  !!settings &&
  (settings.transcription.models.diarization.downloading || settings.transcription.models.emotion.downloading);

/** Every setting; polled every 2 s while a model download runs, to show its outcome. */
export function useSettings() {
  return useQuery({
    queryKey: settingsKeys.settings,
    queryFn: () => apiGet<SettingsDTO>("/api/settings"),
    refetchInterval: (query) => (isDownloading(query.state.data) ? PROGRESS_POLL_MS : false),
  });
}

/** Saves one change; each control owns one, so a refusal shows under that control. */
export function useSaveSetting() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: (patch: SettingsPatch) => apiSend<SettingsDTO>("PATCH", "/api/settings", patch),
    onSuccess: (settings) => client.setQueryData(settingsKeys.settings, settings),
  });
}

export function useResetCosts() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: () => apiSend<SettingsDTO>("POST", "/api/settings/costs/reset"),
    onSuccess: (settings) => client.setQueryData(settingsKeys.settings, settings),
  });
}

const secretPath = (key: SecretKey): string => `/api/settings/secrets/${key}`;

/**
 * The key is the mutation's variables. `gcTime: 0` drops the finished mutation from the
 * cache as soon as nothing observes it (the field calls `reset()` after a save), so no
 * copy of the key stays in memory for the default five minutes.
 */
export function useSaveSecret(key: SecretKey) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: (value: string) => apiSend<void>("PUT", secretPath(key), { value }),
    gcTime: 0,
    onSuccess: () => client.invalidateQueries({ queryKey: settingsKeys.settings }),
  });
}

export function useRemoveSecret(key: SecretKey) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: () => apiSend<void>("DELETE", secretPath(key)),
    onSuccess: () => client.invalidateQueries({ queryKey: settingsKeys.settings }),
  });
}

export function useTestKey() {
  return useMutation({
    mutationFn: () => apiSend<KeyTestResult>("POST", `${secretPath("openrouter")}/test`),
  });
}

/** The catalog as the app holds it; polled while the app is still refreshing it. */
export function useCatalog() {
  return useQuery({
    queryKey: settingsKeys.catalog,
    queryFn: () => apiGet<CatalogDTO>("/api/catalog"),
    refetchInterval: (query) => (query.state.data?.refreshing ? PROGRESS_POLL_MS : false),
  });
}

/** `force: false` keeps the app's 24 h cache, as opening the app's settings does. */
export function useRefreshCatalog() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: (force: boolean) => apiSend<CatalogDTO>("POST", "/api/catalog/refresh", { force }),
    onSuccess: (catalog) => {
      client.setQueryData(settingsKeys.catalog, catalog);
      // The model warnings depend on the list.
      void client.invalidateQueries({ queryKey: settingsKeys.settings });
    },
  });
}

export type FolderSettingName = "outputDirectory" | "obsidianVault";

export function usePickFolder() {
  return useMutation({
    mutationFn: (setting: FolderSettingName) =>
      apiSend<{ path: string | null }>("POST", "/api/system/pick-folder", { setting }),
  });
}

export function useDownloadModels(kind: "diarization" | "emotion") {
  const client = useQueryClient();
  return useMutation({
    mutationFn: () => apiSend<{ started: boolean }>("POST", `/api/settings/models/${kind}/download`),
    onSuccess: () => client.invalidateQueries({ queryKey: settingsKeys.settings }),
  });
}
