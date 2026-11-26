import type { SettingsDTO } from "../types";

export interface PaneProps {
  settings: SettingsDTO;
  /** From the app; undefined until the first status arrives. */
  online: boolean | undefined;
}
