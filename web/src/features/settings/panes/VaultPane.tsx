import { PaneHeader, SelectSetting, TextSetting } from "../controls";
import { FolderSetting } from "../FolderSetting";
import type { PaneProps } from "./paneProps";

const PROFILES = [
  { value: "meeting_notes", label: "Meeting notes" },
  { value: "full_transcript", label: "Full transcript" },
  { value: "obsidian", label: "Obsidian" },
] as const;

export function VaultPane({ settings }: PaneProps) {
  const { vault } = settings;
  return (
    <>
      <PaneHeader title="Vault and exports" lead="Where Save to vault puts notes, and how notes are written." />
      <FolderSetting
        label="Obsidian vault"
        setting="obsidianVault"
        value={vault.obsidianVault}
        chooseLabel="Choose vault folder"
        hint={
          vault.obsidianVault
            ? "Save to vault writes notes into this vault."
            : "Not set. Until you choose one, Save to vault writes into the exports folder inside the output folder."
        }
        patch={(obsidianVault) => ({ vault: { obsidianVault } })}
      />
      <TextSetting
        label="Folder pattern"
        value={vault.folderPattern}
        mono
        hint="A folder inside the vault. {YYYY-MM}, {YYYY}, {MM} and {DD} become the meeting's date."
        patch={(folderPattern) => ({ vault: { folderPattern } })}
      />
      <SelectSetting
        label="Note format"
        value={vault.markdownProfile}
        options={PROFILES}
        hint="The layout of the Markdown note written after each recording."
        patch={(markdownProfile) => ({ vault: { markdownProfile } })}
      />
    </>
  );
}
