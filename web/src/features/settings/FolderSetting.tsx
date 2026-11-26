import type { ReactNode } from "react";
import { errorText } from "../../api/client";
import { usePickFolder, type FolderSettingName } from "./api";
import { TextSetting } from "./controls";
import type { SettingsPatch } from "./types";

interface FolderProps {
  label: string;
  setting: FolderSettingName;
  value: string;
  chooseLabel: string;
  hint?: ReactNode;
  patch: (path: string) => SettingsPatch;
}

/**
 * A folder path: typed, or chosen in the app's folder panel (which the app shows
 * even when this page is open in the browser). Either way it is saved through the
 * same check, so a chosen folder can be refused like a typed one.
 */
export function FolderSetting({ label, setting, value, chooseLabel, hint, patch }: FolderProps) {
  const pick = usePickFolder();
  const pickError = pick.isError
    ? `No folder came back from the folder panel. ${errorText(pick.error)} You can type the folder's full path instead.`
    : null;
  return (
    <TextSetting
      label={label}
      hint={hint}
      value={value}
      placeholder="/Users/you/Folder"
      mono
      patch={patch}
      extraError={pickError}
      after={(commit, busy) => (
        <button
          type="button"
          className="btn btn--small"
          aria-label={chooseLabel}
          disabled={busy || pick.isPending}
          onClick={() =>
            pick.mutate(setting, {
              onSuccess: ({ path }) => {
                if (path) commit(path);
              },
            })
          }
        >
          {pick.isPending ? "Choosing…" : "Choose…"}
        </button>
      )}
    />
  );
}
